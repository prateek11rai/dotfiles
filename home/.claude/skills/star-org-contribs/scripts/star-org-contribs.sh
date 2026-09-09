#!/usr/bin/env bash
# Star every repo in an org that you have commits in, and file them under a
# GitHub star list.
#
# "Have commits in" is the union of three cheap signals, checked on every repo:
#   default  your commits on the default branch (GitHub's profile-contribution basis)
#   tip      a live branch whose tip commit is yours
#   pr       a pull request you authored (open, merged, or closed). A PR pins
#            refs/pull/N/head, so this is the only handle that survives branch
#            deletion.
# plus one expensive, opt-in signal (--deep):
#   deep     your commits buried under other people's on a live branch, found
#            by a date-bounded history walk. Runs only on repos the cheap signals
#            missed, only on branches whose tip is newer than --since, deduped by
#            tip commit, and stops per repo at the first hit.
#
# Why not walk every branch's history? Orgs have tens of thousands of branches;
# ~1000 unbounded history walks in one query makes GitHub time out. Tip reads and
# PR search are ~1 rate-limit point per hundred, so the fast path scales.
#
# Stars and star lists are bookmarks. They do NOT preserve contribution-graph
# history: public-repo commits count forever regardless, private-repo commits
# stop counting once you lose access. This builds an index, not an archive.
#
# Uses the GraphQL API (createUserList / addStar / updateUserListsForItem).
# There is no REST equivalent for star lists.

set -uo pipefail

ORG=""
LIST_NAME=""
LIST_DESC=""
PRIVATE_LIST=false
DRY_RUN=false
ONLY_PUBLIC=false
SKIP_ARCHIVED=false
SKIP_FORKS=false
NO_STAR=false
NO_LIST=false
DEEP=false
SINCE=""
OUT=""
BATCH=20        # repos per GraphQL query in the tip/default scan
DEEP_BATCH=250  # bounded history walks per GraphQL query (600 times out)
PAR=6           # concurrent GraphQL queries; each costs ~1-3 points, so the
                # 5000/hour budget is not the constraint, wall time is

usage() {
  cat <<'USAGE'
star-org-contribs.sh --org ORG [options]

  --org ORG            organization to scan (required)
  --list NAME          star list to file matches under; created if absent
  --desc TEXT          description to use when creating the list
  --private-list       create the list private (default: public)
  --only-public        only consider public repos
  --skip-archived      skip archived repos
  --skip-forks         skip forks
  --deep               also walk branch history on repos the cheap signals
                       missed (slow; prints an estimate before starting)
  --since DATE         lower bound for --deep, ISO date. Default: your oldest PR
                       in the org minus 90 days
  --parallel N         concurrent GraphQL queries during scanning (default 6)
  --no-star            don't star, only report (and file already-starred repos)
  --no-list            star only, don't touch lists
  --dry-run            report what would change, make no writes
  --json PATH          write the full scan result as JSON
  -h, --help           this

Requires: gh (authenticated, `repo` scope), jq, curl.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="${2:-}"; shift 2;;
    --list) LIST_NAME="${2:-}"; shift 2;;
    --desc) LIST_DESC="${2:-}"; shift 2;;
    --private-list) PRIVATE_LIST=true; shift;;
    --only-public) ONLY_PUBLIC=true; shift;;
    --skip-archived) SKIP_ARCHIVED=true; shift;;
    --skip-forks) SKIP_FORKS=true; shift;;
    --deep) DEEP=true; shift;;
    --since) SINCE="${2:-}"; shift 2;;
    --parallel) PAR="${2:-}"; shift 2;;
    --no-star) NO_STAR=true; shift;;
    --no-list) NO_LIST=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --json) OUT="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

[ -n "$ORG" ] || { echo "error: --org is required" >&2; usage >&2; exit 2; }
for bin in gh jq curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: $bin not found" >&2; exit 127; }
done
if [ -n "$SINCE" ]; then
  case "$SINCE" in
    ????-??-??) SINCE="${SINCE}T00:00:00Z";;
    ????-??-??T??:??:??Z) ;;
    *) echo "error: --since must be YYYY-MM-DD" >&2; exit 2;;
  esac
fi

TOKEN=$(gh auth token 2>/dev/null)
[ -n "$TOKEN" ] || { echo "error: not authenticated; run 'gh auth login'" >&2; exit 1; }
API=https://api.github.com/graphql

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
T0=$(date +%s)
since_start() { echo "$(( $(date +%s) - $1 ))s"; }

# GraphQL call with backoff. GitHub returns 502/503 and "couldn't respond in
# time" during incidents or on heavy queries; those are worth retrying.
# Scope/permission errors never resolve on retry, so bail out of those.
gql() {
  local body="$1" tries="${2:-10}" r try errtype
  for try in $(seq 1 "$tries"); do
    r=$(curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
             -d "$body" "$API" 2>/dev/null)
    if printf '%s' "$r" | jq -e '.data != null' >/dev/null 2>&1; then
      printf '%s' "$r"
      return 0
    fi
    errtype=$(printf '%s' "$r" | jq -r '[.errors[]?.type] | join(",")' 2>/dev/null)
    case "$errtype" in
      *INSUFFICIENT_SCOPES*|*FORBIDDEN*|*NOT_FOUND*|*UNAUTHORIZED*)
        printf '%s' "$r" | jq -r '.errors[]?.message' >&2
        return 1;;
    esac
    sleep $((try * 2))
  done
  echo "gql failed after $tries attempts: $(printf '%s' "$r" | head -c 300)" >&2
  return 1
}

# Star lists live behind the 'user' scope; stars themselves only need 'repo'.
# Check before doing the whole scan just to fail at the last step.
require_user_scope() {
  local scopes
  scopes=$(curl -sSI -H "Authorization: Bearer $TOKEN" https://api.github.com/user 2>/dev/null \
           | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')
  case ",$(printf '%s' "$scopes" | tr -d ' ')," in
    *,user,*|*,user:*) return 0;;
  esac
  cat >&2 <<EOF

error: star lists need the 'user' OAuth scope; your token has: ${scopes:-<none>}
       grant it with:  gh auth refresh -h github.com -s user
       (or re-run with --no-list to star only)
EOF
  return 1
}

say() { printf '%s\n' "$*" >&2; }
jstr() { printf '%s' "$1" | jq -Rr @json; }   # shell string -> GraphQL string literal

# Run the queries listed in file $1 (one JSON-encoded query string per line)
# concurrently, at most PAR at a time. Results land in $TMP/w.<n>.json in
# input order. Any failed query aborts the run.
# wave FILE [soft [tries]]: with soft=1, failures leave $TMP/w.<n>.fail behind
# and wave returns 1 instead of aborting, so the caller can shrink and retry.
wave() {
  local f="$1" soft="${2:-0}" tries="${3:-10}" k=0 q
  rm -f "$TMP"/w.*.json "$TMP"/w.*.fail
  while IFS= read -r q; do
    ( gql "$(jq -nc --argjson q "$q" '{query:$q}')" "$tries" > "$TMP/w.$k.json" 2>"$TMP/w.$k.err" \
        || { : > "$TMP/w.$k.fail"; rm -f "$TMP/w.$k.json"; } ) &
    k=$((k + 1))
  done < "$f"
  wait
  if ls "$TMP"/w.*.fail >/dev/null 2>&1; then
    [ "$soft" = 1 ] && return 1
    cat "$TMP"/w.*.err >&2; say "error: a GraphQL batch failed (see above)"; exit 1
  fi
  return 0
}
[ "$PAR" -ge 1 ] 2>/dev/null || { echo "error: --parallel must be a positive integer" >&2; exit 2; }

# ---------------------------------------------------------------- viewer ----
VIEWER=$(gql '{"query":"query{ viewer{ id login createdAt } }"}') || exit 1
VIEWER_ID=$(printf '%s' "$VIEWER" | jq -r '.data.viewer.id')
VIEWER_LOGIN=$(printf '%s' "$VIEWER" | jq -r '.data.viewer.login')
VIEWER_CREATED=$(printf '%s' "$VIEWER" | jq -r '.data.viewer.createdAt')
say "viewer: $VIEWER_LOGIN"

# Fail before the long scan, not after it.
if ! $NO_LIST && [ -n "$LIST_NAME" ] && ! $DRY_RUN; then
  require_user_scope || exit 1
fi

# Working files. Each is one JSON object per line.
: > "$TMP/repos.json"   # org repo listing
: > "$TMP/prs.json"     # {state, createdAt, repository{...}} per PR you authored
: > "$TMP/scan.json"    # per repo: metadata + default-branch count + refs cursor
: > "$TMP/tips.json"    # per branch: {repo, branch, oid, date, mine}
: > "$TMP/mine.json"    # the subset of tips.json with mine=true (small; read often)
: > "$TMP/deep.json"    # per deep hit: {repo, branch, commits}

# Repos already matched by any signal, as a JSON array of names.
hitset() {
  jq -n --slurpfile s "$TMP/scan.json" --slurpfile t "$TMP/mine.json" \
        --slurpfile p "$TMP/prs.json" --slurpfile d "$TMP/deep.json" '
    [ ($s[] | select(.commits > 0) | .name),
      ($t[] | .repo),
      ($p[] | .repository.name),
      ($d[] | .repo) ] | unique'
}

# Append branch-tip rows from a batched repository query result.
append_tips() {
  printf '%s' "$1" | jq -c --arg vid "$VIEWER_ID" '
    .data | to_entries[] | .value | select(. != null) | .name as $r
    | .refs.nodes[] | select(.target != null)
    | {repo: $r, branch: .name, oid: .target.oid, date: .target.committedDate,
       mine: (.target.author.user.id == $vid)}' > "$TMP/tips.part"
  cat "$TMP/tips.part" >> "$TMP/tips.json"
  jq -c 'select(.mine)' "$TMP/tips.part" >> "$TMP/mine.json"
}

TIP_FIELDS='nodes{ name target{ ... on Commit { oid committedDate author{ user{ id } } } } }'

# ----------------------------------------------------------------- repos ----
t=$(date +%s)
say "listing repos in $ORG ..."
cursor=null
while :; do
  body=$(jq -nc --arg org "$ORG" --arg c "$cursor" '
    {query:"query($org:String!,$c:String){ organization(login:$org){ repositories(first:100, after:$c, orderBy:{field:NAME,direction:ASC}){ pageInfo{hasNextPage endCursor} nodes{ id name isPrivate isFork isArchived defaultBranchRef{name} } } } }",
     variables:{org:$org, c:(if $c=="null" then null else $c end)}}')
  r=$(gql "$body") || exit 1
  printf '%s' "$r" | jq -c '.data.organization.repositories.nodes[]' >> "$TMP/repos.json"
  [ "$(printf '%s' "$r" | jq -r '.data.organization.repositories.pageInfo.hasNextPage')" = "true" ] || break
  cursor=$(printf '%s' "$r" | jq -r '.data.organization.repositories.pageInfo.endCursor')
done
say "  $(wc -l < "$TMP/repos.json" | tr -d ' ') repos visible to you ($(since_start $t))"

FILTER='select(.defaultBranchRef != null)'
$ONLY_PUBLIC   && FILTER="$FILTER | select(.isPrivate | not)"
$SKIP_ARCHIVED && FILTER="$FILTER | select(.isArchived | not)"
$SKIP_FORKS    && FILTER="$FILTER | select(.isFork | not)"

NAMES=()
while IFS= read -r ln; do NAMES+=("$ln"); done < <(jq -r "$FILTER | .name" "$TMP/repos.json")
total=${#NAMES[@]}
[ "$total" -gt 0 ] || { say "no repos to scan after filters"; exit 0; }

# ------------------------------------------------------------ PRs (signal) ---
# One org-wide search per state. Search caps at 1000 results per query, so the
# split by state triples the ceiling; warn if a bucket still overflows.
t=$(date +%s)
say "searching pull requests by $VIEWER_LOGIN in $ORG ..."
for st in "is:open" "is:merged" "is:closed is:unmerged"; do
  q="is:pr author:$VIEWER_LOGIN org:$ORG $st"
  cursor=null
  while :; do
    body=$(jq -nc --arg q "$q" --arg c "$cursor" '
      {query:"query($q:String!,$c:String){ search(type:ISSUE, query:$q, first:100, after:$c){ issueCount pageInfo{hasNextPage endCursor} nodes{ ... on PullRequest { state createdAt repository{ id name nameWithOwner url isPrivate isArchived isFork stargazerCount viewerHasStarred } } } } }",
       variables:{q:$q, c:(if $c=="null" then null else $c end)}}')
    r=$(gql "$body") || exit 1
    printf '%s' "$r" | jq -c '.data.search.nodes[] | select(.repository != null)' >> "$TMP/prs.json"
    cnt=$(printf '%s' "$r" | jq -r '.data.search.issueCount')
    [ "$cnt" -gt 1000 ] && say "  warning: '$st' has $cnt PRs; search only returns the first 1000"
    [ "$(printf '%s' "$r" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$r" | jq -r '.data.search.pageInfo.endCursor')
  done
done
say "  $(wc -l < "$TMP/prs.json" | tr -d ' ') PRs across $(jq -r '.repository.name' "$TMP/prs.json" | sort -u | wc -l | tr -d ' ') repos ($(since_start $t))"

# ---------------------------------------------- default branch + branch tips ---
# One batched query per BATCH repos: default-branch history(author) count, plus
# the first 100 branch tips (author + date). Tip reads cost ~1 point per query.
t=$(date +%s)
say "scanning $total repos: default-branch commits + branch tips ($PAR queries at a time) ..."
i=0
while [ $i -lt $total ]; do
  : > "$TMP/wave.q"; k=0
  while [ $k -lt "$PAR" ] && [ $i -lt $total ]; do
    parts=""; n=0
    while [ $n -lt $BATCH ] && [ $i -lt $total ]; do
      parts+="a${n}: repository(owner:$(jstr "$ORG"), name:$(jstr "${NAMES[$i]}")){ id name nameWithOwner url isPrivate isArchived isFork stargazerCount viewerHasStarred defaultBranchRef{ name target{ ... on Commit { history(author:{id:\"${VIEWER_ID}\"}, first:1){ totalCount nodes{ committedDate } } } } } refs(refPrefix:\"refs/heads/\", first:100){ totalCount pageInfo{hasNextPage endCursor} ${TIP_FIELDS} } } "
      n=$((n + 1)); i=$((i + 1))
    done
    jstr "query{ $parts }" >> "$TMP/wave.q"; k=$((k + 1))
  done
  wave "$TMP/wave.q"
  for f in "$TMP"/w.*.json; do
    r=$(cat "$f")
    printf '%s' "$r" | jq -c '.data | to_entries[] | .value | select(. != null)
      | {name, nameWithOwner, id, url, isPrivate, isArchived, isFork, stargazerCount, viewerHasStarred,
         branch: .defaultBranchRef.name,
         commits: (.defaultBranchRef.target.history.totalCount // 0),
         lastCommit: (.defaultBranchRef.target.history.nodes[0].committedDate // null),
         branchesTotal: .refs.totalCount,
         refsCursor: (if .refs.pageInfo.hasNextPage then .refs.pageInfo.endCursor else null end)}' >> "$TMP/scan.json"
    append_tips "$r"
  done
  printf '\r  %d/%d' "$i" "$total" >&2
done
printf '\r' >&2
say "  $(jq -s 'map(select(.commits > 0)) | length' "$TMP/scan.json") repos via default branch, $(jq -s 'map(select(.mine)) | length' "$TMP/tips.json") branch tips are yours ($(since_start $t))"

# ---------------------------------------- remaining branch pages, unmatched ---
# Only repos with >100 branches AND no hit yet need more tip pages. Ref cursors
# are base64 of the item offset ("MTAw" = "100"), so every remaining page of a
# repo can be requested in one wave instead of chaining cursors: 35 sequential
# round trips for a 3500-branch repo become one. Verified per repo: the cursor
# GitHub returned after page 1 must equal base64("100"); otherwise that repo
# falls back to chained pagination. A repo drops out the moment a page finds a
# tip of yours.
t=$(date +%s)
hitset > "$TMP/hitset.json"
: > "$TMP/pages.tsv"     # repo \t cursor  (synthesised offsets)
: > "$TMP/cursors.tsv"   # repo \t cursor  (chained fallback)
b64_100=$(printf '%s' 100 | base64 | tr -d '=')
jq -r --slurpfile h "$TMP/hitset.json" 'select(.refsCursor != null) | select(.name | IN($h[0][]) | not)
  | [.name, .refsCursor, .branchesTotal] | @tsv' "$TMP/scan.json" \
| while IFS=$'\t' read -r rname rcur rtotal; do
    if [ "${rcur%%=*}" = "$b64_100" ]; then
      off=100
      while [ "$off" -lt "$rtotal" ]; do
        printf '%s\t%s\n' "$rname" "$(printf '%s' "$off" | base64 | tr -d '=')" >> "$TMP/pages.tsv"
        off=$((off + 100))
      done
    else
      printf '%s\t%s\n' "$rname" "$rcur" >> "$TMP/cursors.tsv"
    fi
  done
pages=0
while [ -s "$TMP/pages.tsv" ]; do
  take=$((BATCH * PAR))
  head -n "$take" "$TMP/pages.tsv" > "$TMP/this.tsv"
  tail -n +$((take + 1)) "$TMP/pages.tsv" > "$TMP/rest.tsv"
  : > "$TMP/wave.q"; parts=""; n=0; got=0
  while IFS=$'\t' read -r rname rcur; do
    parts+="a${n}: repository(owner:$(jstr "$ORG"), name:$(jstr "$rname")){ name refs(refPrefix:\"refs/heads/\", first:100, after:$(jstr "$rcur")){ ${TIP_FIELDS} } } "
    n=$((n + 1)); got=$((got + 1))
    if [ $n -eq $BATCH ]; then jstr "query{ $parts }" >> "$TMP/wave.q"; parts=""; n=0; fi
  done < "$TMP/this.tsv"
  [ -n "$parts" ] && jstr "query{ $parts }" >> "$TMP/wave.q"
  wave "$TMP/wave.q"
  for f in "$TMP"/w.*.json; do append_tips "$(cat "$f")"; done
  pages=$((pages + got))
  hitset > "$TMP/hitset.json"
  jq -rn --slurpfile h "$TMP/hitset.json" --rawfile c "$TMP/rest.tsv" '
    $c | split("\n")[] | select(length > 0) | split("\t") | select(.[0] | IN($h[0][]) | not) | @tsv' > "$TMP/pages.tsv"
  printf '\r  %d branch pages fetched, %d pending' "$pages" "$(wc -l < "$TMP/pages.tsv" | tr -d ' ')" >&2
done
# Chained fallback, one page per repo per round.
while [ -s "$TMP/cursors.tsv" ]; do
  hitset > "$TMP/hitset.json"
  jq -rn --slurpfile h "$TMP/hitset.json" --rawfile c "$TMP/cursors.tsv" '
    $c | split("\n")[] | select(length > 0) | split("\t") | select(.[0] | IN($h[0][]) | not) | @tsv' > "$TMP/cursors.live"
  [ -s "$TMP/cursors.live" ] || break
  take=$((BATCH * PAR))
  head -n "$take" "$TMP/cursors.live" > "$TMP/this.tsv"
  tail -n +$((take + 1)) "$TMP/cursors.live" > "$TMP/cursors.tsv"
  : > "$TMP/wave.q"; parts=""; n=0; got=0
  while IFS=$'\t' read -r rname rcur; do
    parts+="a${n}: repository(owner:$(jstr "$ORG"), name:$(jstr "$rname")){ name refs(refPrefix:\"refs/heads/\", first:100, after:$(jstr "$rcur")){ pageInfo{hasNextPage endCursor} ${TIP_FIELDS} } } "
    n=$((n + 1)); got=$((got + 1))
    if [ $n -eq $BATCH ]; then jstr "query{ $parts }" >> "$TMP/wave.q"; parts=""; n=0; fi
  done < "$TMP/this.tsv"
  [ -n "$parts" ] && jstr "query{ $parts }" >> "$TMP/wave.q"
  wave "$TMP/wave.q"
  for f in "$TMP"/w.*.json; do
    r=$(cat "$f")
    append_tips "$r"
    printf '%s' "$r" | jq -r '.data | to_entries[] | .value | select(. != null) | select(.refs.pageInfo.hasNextPage) | [.name, .refs.pageInfo.endCursor] | @tsv' >> "$TMP/cursors.tsv"
  done
  pages=$((pages + got))
  printf '\r  %d branch pages fetched (chained), %d pending' "$pages" "$(wc -l < "$TMP/cursors.tsv" | tr -d ' ')" >&2
done
[ "$pages" -gt 0 ] && { printf '\r' >&2; say "  $pages extra branch pages on unmatched repos ($(since_start $t))"; }

# ---------------------------------------------------------- deep (optional) ---
if $DEEP; then
  if [ -z "$SINCE" ]; then
    oldest=$(jq -rs 'map(.createdAt) | min // empty' "$TMP/prs.json")
    if [ -n "$oldest" ]; then
      SINCE=$(jq -rn --arg d "$oldest" '$d | fromdateiso8601 - 90*86400 | todateiso8601')
    else
      SINCE=$VIEWER_CREATED
    fi
  fi
  t=$(date +%s)
  hitset > "$TMP/hitset.json"
  # Candidates: branches on unmatched repos, tip not yours, tip newer than SINCE
  # (a branch whose tip predates your first activity cannot contain your commits),
  # one per distinct tip commit, newest first within each repo.
  jq -c --arg since "$SINCE" --slurpfile h "$TMP/hitset.json" '
    select(.mine | not) | select(.date >= $since) | select(.repo | IN($h[0][]) | not)' "$TMP/tips.json" \
    | jq -rs 'unique_by([.repo, .oid]) | group_by(.repo) | map(sort_by(.date) | reverse) | add // [] | .[] | [.repo, .branch] | @tsv' > "$TMP/cands.tsv"
  nc=$(wc -l < "$TMP/cands.tsv" | tr -d ' ')
  nr=$(cut -f1 "$TMP/cands.tsv" | sort -u | wc -l | tr -d ' ')
  say "deep: walking history since ${SINCE%T*} on $nc branches across $nr unmatched repos (GitHub sustains ~700 walks/min, so expect ~$(( nc / 700 + 1 )) min) ..."
  done_n=0; skipped=0; per=$DEEP_BATCH
  : > "$TMP/skipped.tsv"
  while [ -s "$TMP/cands.tsv" ]; do
    take=$((per * PAR))
    head -n "$take" "$TMP/cands.tsv" > "$TMP/this.tsv"
    tail -n +$((take + 1)) "$TMP/cands.tsv" > "$TMP/rest.tsv"
    # chunk.<q>.tsv holds the candidates behind query q, so a failed query can be
    # re-queued; alias.tsv maps (query, alias) back to repo + branch.
    rm -f "$TMP"/chunk.*.tsv
    : > "$TMP/wave.q"; : > "$TMP/alias.tsv"; parts=""; n=0; q=0
    while IFS=$'\t' read -r rname br; do
      parts+="r${n}: repository(owner:$(jstr "$ORG"), name:$(jstr "$rname")){ ref(qualifiedName:$(jstr "refs/heads/$br")){ target{ ... on Commit { history(author:{id:\"${VIEWER_ID}\"}, since:\"${SINCE}\", first:1){ totalCount } } } } } "
      printf '%d\tr%d\t%s\t%s\n' "$q" "$n" "$rname" "$br" >> "$TMP/alias.tsv"
      printf '%s\t%s\n' "$rname" "$br" >> "$TMP/chunk.$q.tsv"
      n=$((n + 1))
      if [ $n -eq "$per" ]; then jstr "query{ $parts }" >> "$TMP/wave.q"; parts=""; n=0; q=$((q + 1)); fi
    done < "$TMP/this.tsv"
    [ -n "$parts" ] && jstr "query{ $parts }" >> "$TMP/wave.q"
    wave "$TMP/wave.q" 1 3 || true
    : > "$TMP/requeue.tsv"
    for c in "$TMP"/chunk.*.tsv; do
      qi=${c##*/chunk.}; qi=${qi%.tsv}
      if [ -e "$TMP/w.$qi.fail" ]; then
        if [ "$per" -le 25 ]; then
          cat "$c" >> "$TMP/skipped.tsv"; skipped=$((skipped + $(wc -l < "$c")))
        else
          cat "$c" >> "$TMP/requeue.tsv"
        fi
        continue
      fi
      jq -r '.data | to_entries[] | select(.value != null and .value.ref != null)
        | select(.value.ref.target.history.totalCount > 0) | [.key, .value.ref.target.history.totalCount] | @tsv' "$TMP/w.$qi.json" \
      | while IFS=$'\t' read -r a cnt; do
          awk -F'\t' -v q="$qi" -v a="$a" '$1==q && $2==a{print $3 "\t" $4}' "$TMP/alias.tsv" | while IFS=$'\t' read -r rname br; do
            jq -nc --arg repo "$rname" --arg br "$br" --argjson c "$cnt" '{repo:$repo, branch:$br, commits:$c}' >> "$TMP/deep.json"
          done
        done
      done_n=$((done_n + $(wc -l < "$c")))
    done
    if [ -s "$TMP/requeue.tsv" ]; then
      # GitHub timed out on this chunk size: halve it and put the work back first.
      per=$(( per / 2 )); [ "$per" -lt 25 ] && per=25
      cat "$TMP/requeue.tsv" "$TMP/rest.tsv" > "$TMP/rest.all"; mv "$TMP/rest.all" "$TMP/rest.tsv"
      printf '\r  timeouts; shrinking to %d walks per query                    \n' "$per" >&2
    fi
    # Short-circuit: drop the rest of any repo that just matched.
    hitset > "$TMP/hitset.json"
    jq -rn --slurpfile h "$TMP/hitset.json" --rawfile c "$TMP/rest.tsv" '
      $c | split("\n")[] | select(length > 0) | split("\t") | select(.[0] | IN($h[0][]) | not) | @tsv' > "$TMP/cands.tsv"
    printf '\r  %d walked, %d hits, %d remaining' "$done_n" "$(wc -l < "$TMP/deep.json" | tr -d ' ')" "$(wc -l < "$TMP/cands.tsv" | tr -d ' ')" >&2
  done
  printf '\r' >&2
  say "  deep found $(jq -r .repo "$TMP/deep.json" | sort -u | wc -l | tr -d ' ') more repos ($(since_start $t))"
  if [ "$skipped" -gt 0 ]; then
    say "  warning: $skipped branches skipped after repeated GitHub timeouts, across: $(cut -f1 "$TMP/skipped.tsv" | sort -u | tr '\n' ' ')"
  fi
fi

# ----------------------------------------------------------------- union ----
jq -n --argjson onlypub "$ONLY_PUBLIC" --argjson skiparch "$SKIP_ARCHIVED" --argjson skipforks "$SKIP_FORKS" \
   --slurpfile s "$TMP/scan.json" --slurpfile t "$TMP/tips.json" --slurpfile p "$TMP/prs.json" --slurpfile d "$TMP/deep.json" '
  ($t | map(select(.mine)) | group_by(.repo) | map({key: .[0].repo, value: (sort_by(.date) | reverse)}) | from_entries) as $tips
  | ($d | group_by(.repo) | map({key: .[0].repo, value: .}) | from_entries) as $deep
  | ($p | group_by(.repository.name) | map({key: .[0].repository.name, value: {
        repo: .[0].repository, created: (map(.createdAt) | max),
        open: (map(select(.state == "OPEN")) | length),
        merged: (map(select(.state == "MERGED")) | length),
        closed: (map(select(.state == "CLOSED")) | length),
        total: length}}) | from_entries) as $prs
  | ($s | map({key: .name, value: .}) | from_entries) as $scan
  # PR-only repos that were not in the scanned set still get metadata from the PR search
  | ($prs | to_entries | map(select($scan[.key] == null)
        | {key, value: (.value.repo + {commits: 0, lastCommit: null, branch: null, branchesTotal: null, refsCursor: null})}) | from_entries) as $extra
  | ($scan + $extra) | to_entries
  | map(.key as $n | .value as $r | $r + {
      tipBranches: (($tips[$n] // []) | map(.branch)),
      deepBranches: (($deep[$n] // []) | map(.branch)),
      prs: (($prs[$n] // {open: 0, merged: 0, closed: 0, total: 0}) | del(.repo, .created)),
      via: ([ (if $r.commits > 0 then "default" else empty end),
              (if $tips[$n] then "tip" else empty end),
              (if $deep[$n] then "deep" else empty end),
              (if $prs[$n] then "pr" else empty end) ]),
      last: ([ $r.lastCommit, (($tips[$n] // [])[0].date), $prs[$n].created ] | map(select(. != null)) | max) }
    | del(.refsCursor))
  | map(select((.via | length) > 0))
  | map(select(($onlypub | not) or (.isPrivate | not)))
  | map(select(($skiparch | not) or (.isArchived | not)))
  | map(select(($skipforks | not) or (.isFork | not)))
  | sort_by([-.commits, -(.tipBranches | length), -.prs.total])' > "$TMP/hits.json"
hits=$(jq 'length' "$TMP/hits.json")
say "  $hits repos with your commits (total $(since_start $T0))"
[ -n "$OUT" ] && { mkdir -p "$(dirname "$OUT")"; cp "$TMP/hits.json" "$OUT"; say "  wrote $OUT"; }

# ----------------------------------------------------------------- report ---
printf '\n%s\n' "Repos in $ORG with commits by $VIEWER_LOGIN:"
printf '%s\n' "   dflt  tips  deep   prs                          repo  (via)  (last activity)"
jq -r 'def lpad(n): tostring | (" " * (n - length)) + .;
  .[] | "  \(.commits|lpad(5)) \(.tipBranches|length|lpad(5)) \(.deepBranches|length|lpad(5)) \(.prs.total|lpad(5))  \(if .isPrivate then "private" else "public " end) \(if .isArchived then "arch" else "    " end) \(if .viewerHasStarred then "*" else " " end) \(.nameWithOwner)  (\(.via|join(",")))  (last \(.last[0:10]))"' "$TMP/hits.json"
pub=$(jq '[.[] | select(.isPrivate|not)] | length' "$TMP/hits.json")
priv=$(jq '[.[] | select(.isPrivate)] | length' "$TMP/hits.json")
printf '\n  %s public (contributions persist), %s private (contributions end with org access)\n' "$pub" "$priv"
printf '  via: %s\n\n' "$(jq -r '[.[].via[]] | group_by(.) | map("\(.[0])=\(length)") | join("  ")' "$TMP/hits.json")"
$DEEP || printf '  (--deep would also walk branch history on the %s repos no signal matched)\n\n' "$(jq -n --slurpfile s "$TMP/scan.json" --slurpfile h "$TMP/hits.json" '[$s[].name] - [$h[0][].name] | length')"

[ "$hits" -eq 0 ] && exit 0
if $DRY_RUN; then say "dry run: no changes made"; exit 0; fi

# ------------------------------------------------------------------ star ----
if ! $NO_STAR; then
  say "starring ..."
  while IFS=$'\t' read -r rid rname starred; do
    [ "$starred" = "true" ] && { say "  = $rname (already starred)"; continue; }
    body=$(jq -nc --arg id "$rid" '{query:"mutation($id:ID!){ addStar(input:{starrableId:$id}){ clientMutationId } }", variables:{id:$id}}')
    if gql "$body" >/dev/null; then say "  + $rname"; else say "  ! $rname (star failed)"; fi
  done < <(jq -r '.[] | [.id, .nameWithOwner, (.viewerHasStarred|tostring)] | @tsv' "$TMP/hits.json")
fi

# ------------------------------------------------------------------ list ----
$NO_LIST && exit 0
[ -n "$LIST_NAME" ] || { say "no --list given; done"; exit 0; }

# Pull every list and its items. updateUserListsForItem REPLACES an item's set
# of lists, so we must union with what's already there or we'd evict repos from
# other lists.
say "reading existing star lists ..."
LISTS=$(gql "$(jq -nc '{query:"query{ viewer{ lists(first:100){ nodes{ id name slug items(first:100){ nodes{ ... on Repository { id nameWithOwner } } } } } } }"}')") || exit 1
printf '%s' "$LISTS" | jq -r '.data.viewer.lists.nodes[] | "  \(.name) (\(.items.nodes|length) items)"' >&2

LIST_ID=$(printf '%s' "$LISTS" | jq -r --arg n "$LIST_NAME" '.data.viewer.lists.nodes[] | select(.name == $n) | .id' | head -1)
if [ -z "$LIST_ID" ]; then
  say "creating list \"$LIST_NAME\" ..."
  body=$(jq -nc --arg n "$LIST_NAME" --arg d "$LIST_DESC" --argjson p "$PRIVATE_LIST" \
    '{query:"mutation($n:String!,$d:String,$p:Boolean){ createUserList(input:{name:$n, description:$d, isPrivate:$p}){ list{ id name slug } } }",
      variables:{n:$n, d:(if $d=="" then null else $d end), p:$p}}')
  r=$(gql "$body") || exit 1
  LIST_ID=$(printf '%s' "$r" | jq -r '.data.createUserList.list.id')
  [ -n "$LIST_ID" ] && [ "$LIST_ID" != "null" ] || { say "error: could not create list"; exit 1; }
  say "  created: $(printf '%s' "$r" | jq -r '.data.createUserList.list.slug')"
else
  say "using existing list \"$LIST_NAME\""
fi

# repo id -> current list ids
printf '%s' "$LISTS" | jq -r '[.data.viewer.lists.nodes[] as $l | $l.items.nodes[] | select(.id != null) | {repo: .id, list: $l.id}]
  | group_by(.repo) | map({key: .[0].repo, value: [.[].list]}) | from_entries' > "$TMP/membership.json"

say "filing into \"$LIST_NAME\" ..."
while IFS=$'\t' read -r rid rname; do
  cur=$(jq -r --arg id "$rid" '(.[$id] // []) | @json' "$TMP/membership.json")
  if printf '%s' "$cur" | jq -e --arg l "$LIST_ID" 'index($l)' >/dev/null 2>&1; then
    say "  = $rname (already in list)"; continue
  fi
  merged=$(printf '%s' "$cur" | jq -c --arg l "$LIST_ID" '. + [$l] | unique')
  body=$(jq -nc --arg id "$rid" --argjson ids "$merged" \
    '{query:"mutation($id:ID!,$ids:[ID!]!){ updateUserListsForItem(input:{itemId:$id, listIds:$ids}){ item{ ... on Repository { nameWithOwner } } } }",
      variables:{id:$id, ids:$ids}}')
  if gql "$body" >/dev/null; then say "  + $rname"; else say "  ! $rname (list add failed)"; fi
done < <(jq -r '.[] | [.id, .nameWithOwner] | @tsv' "$TMP/hits.json")

say ""
say "done -> https://github.com/$VIEWER_LOGIN?tab=stars"
