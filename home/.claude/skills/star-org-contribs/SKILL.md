---
name: star-org-contribs
description: Star every repo in a GitHub org you have commits in (default branch, any live branch tip, or a PR you authored) and file them under a star list. Use when the user asks to star, index, or bookmark the org repos they contributed to.
argument-hint: "[org] [list-name]"
allowed-tools: Bash(~/.claude/skills/star-org-contribs/scripts/star-org-contribs.sh:*), Bash(gh org list:*), Bash(gh auth status:*), Bash(gh auth refresh:*)
---

Run the contribution-starring script for one GitHub organization.

Arguments: `$ARGUMENTS` — first word is the org, second is the star list name
(default: same as the org). The org is required input, never assumed. If the user
did not name one, list the orgs their account belongs to and ask which to run for:

```
gh org list --limit 100
```

Do not guess from the working directory or from earlier runs; a wrong org means
a scan of the wrong company's repos and stars filed under the wrong list.

Script: `~/.claude/skills/star-org-contribs/scripts/star-org-contribs.sh`
Snapshots: `~/.local/state/star-org-contribs/<ORG>-contribs.json` (data, not config;
the script creates the directory).

## What to do

1. Dry-run first and show the user the report. Expect ~2.5 minutes for an org of
   ~800 repos; the script prints per-phase timings to stderr. Use a 10-minute
   Bash timeout, not the default.

   ```
   ~/.claude/skills/star-org-contribs/scripts/star-org-contribs.sh --org <ORG> --list <LIST> --dry-run
   ```

2. Show the table and call out the public/private split explicitly. Only public
   repos keep contributing to the profile graph after org access ends. Do not
   let the user believe starring preserves anything: stars are a bookmark index,
   not an archive.

3. Starring is outward-facing (visible on the user's public profile). Run for
   real only after the user confirms:

   ```
   ~/.claude/skills/star-org-contribs/scripts/star-org-contribs.sh --org <ORG> --list <LIST> \
     --desc "<ORG> repositories I contributed commits to." \
     --json ~/.local/state/star-org-contribs/<ORG>-contribs.json
   ```

4. Report what changed: newly starred, already starred, newly filed into the list.

## How a repo qualifies

The report's `via` column names the signals that matched. Any one is enough:

- `default` — your commits on the default branch (GitHub's own basis for profile
  contributions).
- `tip` — a live branch, on any base, whose newest commit is yours.
- `pr` — a pull request you authored: open, merged, or closed-unmerged. A PR pins
  `refs/pull/N/head`, so this is the only signal that survives branch deletion.
  Commits on a deleted branch that never had a PR are unrecoverable by any API;
  do not promise to find them.
- `deep` — only with `--deep`: your commits buried under other people's on a live
  branch (the shared team branch nobody PR'd). It walks history only on repos the
  cheap signals missed, only on branches newer than `--since` (default: your
  oldest PR in the org minus 90 days), once per distinct tip commit, stopping per
  repo at the first hit. On an ~800-repo org it takes ~50 minutes and adds at
  most a repo or two, so leave it out of routine runs. Offer it once as a
  backlog sweep, or when the user knows they pushed to a shared branch without a
  PR. GitHub times out on large history batches; the script shrinks its chunk
  size adaptively and reports any branches it had to skip.

## Notes

- Idempotent. Re-running only picks up repos that gained your commits since last
  time; existing stars and list entries are left alone. Periodic runs are the
  intended use.
- Star lists require the `user` OAuth scope. The script preflights this and asks
  for `gh auth refresh -h github.com -s user` if missing. That command is
  interactive, so suggest the user type `! gh auth refresh -h github.com -s user`
  in the prompt. Stars alone need only `repo`; `--no-list` works without it.
- Runtime is dominated by branch-tip reads (~1 GraphQL point per 100 branches),
  run `--parallel 6` at a time by default; the 5000 points/hour budget is not the
  constraint. Branch pages past the first 100 use synthesised offset cursors
  (base64 of the offset) so a 3500-branch repo costs one wave, not 35 round
  trips; the script verifies the cursor format per repo and falls back to
  chained pagination if it differs.
- The script merges list membership before writing. `updateUserListsForItem`
  replaces an item's whole list set, so never call it with a bare `[listId]`.
- Flags: `--deep`, `--since YYYY-MM-DD`, `--parallel N`, `--only-public`,
  `--skip-archived`, `--skip-forks`, `--no-star`, `--no-list`, `--dry-run`,
  `--json PATH`.
