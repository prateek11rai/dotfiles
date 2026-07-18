#!/usr/bin/env bash
# Claude Code statusLine command — responsive.
# Wide panes: one line (user@host dir branch model effort meter ⚠>200K cache cost limits+resets).
# Narrow panes (e.g. tmux splits): wraps to two rows — identity, then metrics —
# and progressively slims segments that still don't fit.
# Claude Code sets $COLUMNS to the pane width before each render (v2.1.153+)
# and renders each stdout line as its own status row.

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
input=$(cat)

user=$(whoami)
# macOS keeps three machine names; `hostname -s` often lags a System Settings
# rename — prefer the user-facing ComputerName (e.g. "smoker")
host=$(scutil --get ComputerName 2>/dev/null || hostname -s)
cols=${COLUMNS:-200}

# Single jq pass over the statusline JSON. Fields are joined with a unit-separator
# (0x1F), NOT tab: tab is IFS-whitespace so `read` would collapse empty fields
# and shift everything (rate_limits/current_usage are absent early in a session).
IFS=$'\037' read -r dir model used_pct used_tok win_size cost rl_5h rl_7d \
                  rl_5h_reset rl_7d_reset cur_in cache_cr cache_rd over200k effort <<< "$(echo "$input" | jq -r '[
  (.workspace.current_dir // .cwd // ""),
  (.model.display_name // ""),
  (.context_window.used_percentage // "" | tostring),
  (.context_window.total_input_tokens // "" | tostring),
  (.context_window.context_window_size // "" | tostring),
  (.cost.total_cost_usd // "" | tostring),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.resets_at // "" | tostring),
  (.context_window.current_usage.input_tokens // "" | tostring),
  (.context_window.current_usage.cache_creation_input_tokens // "" | tostring),
  (.context_window.current_usage.cache_read_input_tokens // "" | tostring),
  (.exceeds_200k_tokens // false | tostring),
  (.effort.level // "" | tostring)
] | join("\u001f")')"

now=$(date +%s)

# Truncate decimals for display
used_pct="${used_pct%%.*}"
rl_5h="${rl_5h%%.*}"
rl_7d="${rl_7d%%.*}"

# Show ~ for the home-directory prefix. Literal ~ (no tilde-expansion), and
# non-home paths pass through unchanged. The old `${dir/#$home/\~}` left a
# stray backslash — bash keeps it in the replacement string.
home_dir="$HOME"
case "$dir" in
  "$home_dir")   display_dir="~" ;;
  "$home_dir"/*) display_dir="~/${dir#"$home_dir"/}" ;;
  *)             display_dir="$dir" ;;
esac

human() { # 291830 -> 292k, 1000000 -> 1M
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) { m = n / 1000000; if (m == int(m)) printf "%dM", m; else printf "%.1fM", m }
    else if (n >= 1000) printf "%dk", int(n / 1000 + 0.5)
    else printf "%d", n }'
}

# Countdown to a rate-limit reset: epoch seconds -> "45m" / "2h10m" / "1d3h" / ""
fmt_reset() {
  local ep=${1%%.*}
  [ -z "$ep" ] && { printf ''; return; }
  local d=$(( ep - now )); [ "$d" -lt 0 ] && d=0
  local days=$(( d / 86400 )) h=$(( (d % 86400) / 3600 )) m=$(( (d % 3600) / 60 ))
  if   [ "$days" -gt 0 ]; then printf '%dd%dh' "$days" "$h"
  elif [ "$h" -gt 0 ];    then printf '%dh%02dm' "$h" "$m"
  else                         printf '%dm' "$m"; fi
}

# Git branch (skip optional locks to avoid blocking)
git_branch=""
if [ -n "$dir" ] && { [ -d "$dir/.git" ] || git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; }; then
  git_branch=$(git -C "$dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# ── Build segments as (plain, colored) pairs so widths can be measured ──────
esc=$'\033'

# Token usage meter: 5-slot bar, green <50%, yellow 50-79%, red >=80%
meter_plain="" meter_col="" toks=""
if [ -n "$used_pct" ]; then
  filled=$(( (used_pct + 10) / 20 ))
  [ "$filled" -gt 5 ] && filled=5
  bar=""
  for ((i = 1; i <= 5; i++)); do
    if [ "$i" -le "$filled" ]; then bar+="▓"; else bar+="░"; fi
  done
  if   [ "$used_pct" -ge 80 ]; then mcolor="31"
  elif [ "$used_pct" -ge 50 ]; then mcolor="33"
  else                              mcolor="32"; fi
  [ -n "$used_tok" ] && [ -n "$win_size" ] && toks=" $(human "$used_tok")/$(human "$win_size")"
  meter_plain="$bar ${used_pct}%${toks}"
  meter_col="${esc}[${mcolor}m${meter_plain}${esc}[0m"
fi

cost_plain="" cost_col=""
[ -n "$cost" ] && cost_plain="$(printf '$%.2f' "$cost")" && cost_col="${esc}[35m${cost_plain}${esc}[0m"

rl_plain="" rl_col=""
if [ -n "$rl_5h" ] && [ -n "$rl_7d" ]; then
  r5=$(fmt_reset "$rl_5h_reset"); r7=$(fmt_reset "$rl_7d_reset")
  rl_plain="5h:${rl_5h}%${r5:+↻$r5} 7d:${rl_7d}%${r7:+↻$r7}"
  rl_col="${esc}[2m${rl_plain}${esc}[0m"
fi

# Cache-hit indicator: share of input tokens served from (cheap) cache reads.
# Green = mostly cached, red = little cached (paying full input price).
cache_plain="" cache_col=""
if [ -n "$cache_rd" ] && [ -n "$cur_in" ] && [ -n "$cache_cr" ]; then
  denom=$(( cur_in + cache_cr + cache_rd ))
  if [ "$denom" -gt 0 ]; then
    hit=$(( 100 * cache_rd / denom ))
    cache_plain="⚡${hit}%"
    if   [ "$hit" -ge 70 ]; then ccolor="32"
    elif [ "$hit" -ge 40 ]; then ccolor="33"
    else                         ccolor="31"; fi
    cache_col="${esc}[${ccolor}m${cache_plain}${esc}[0m"
  fi
fi

# Long-context premium warning: past 200k input tokens, requests bill at a
# higher tier — most relevant on the 1M-context model. Never dropped when slimming.
over_plain="" over_col=""
if [ "$over200k" = "true" ]; then
  over_plain="⚠>200K"
  over_col="${esc}[1;31m${over_plain}${esc}[0m"
fi

model_col=""
[ -n "$model" ] && model_col="${esc}[36m${model}${esc}[0m"

# Reasoning-effort indicator (yellow when heavy — xhigh/max burn the most output).
effort_plain="" effort_col=""
if [ -n "$effort" ]; then
  effort_plain="$effort"
  case "$effort" in
    xhigh|max) ecolor="33" ;;
    high)      ecolor="36" ;;
    *)         ecolor="2"  ;;
  esac
  effort_col="${esc}[${ecolor}m${effort_plain}${esc}[0m"
fi

branch_plain="" branch_col=""
[ -n "$git_branch" ] && branch_plain=" ${git_branch}" && branch_col="${esc}[33m${branch_plain}${esc}[0m"

join_plain() { local IFS=; local out="" s; for s in "$@"; do [ -n "$s" ] && out+="${out:+  }$s"; done; printf '%s' "$out"; }

id_plain="${user}@${host} ${display_dir}$(join_plain "" "$branch_plain")"
id_col="${esc}[32m${user}@${host}${esc}[0m ${esc}[34m${display_dir}${esc}[0m"
[ -n "$branch_col" ] && id_col+="  $branch_col"

metrics_plain="$(join_plain "$model" "$effort_plain" "$meter_plain" "$over_plain" "$cache_plain" "$cost_plain" "$rl_plain")"
metrics_col="$(join_plain "$model_col" "$effort_col" "$meter_col" "$over_col" "$cache_col" "$cost_col" "$rl_col")"

# ── Layout: one line if it fits, otherwise wrap to two rows and slim ────────
if [ $(( ${#id_plain} + 2 + ${#metrics_plain} )) -le "$cols" ]; then
  printf '%s  %s\n' "$id_col" "$metrics_col"
else
  # Row 1: identity — shorten dir to basename if the row alone overflows
  if [ "${#id_plain}" -gt "$cols" ] && [ -n "$display_dir" ]; then
    short_dir="…/${display_dir##*/}"
    id_col="${esc}[32m${user}@${host}${esc}[0m ${esc}[34m${short_dir}${esc}[0m"
    [ -n "$branch_col" ] && id_col+="  $branch_col"
  fi
  # Row 2: metrics — drop extras (effort → limits → cache → token fraction → cost)
  # until it fits. The ⚠>200K premium warning is never dropped.
  if [ "${#metrics_plain}" -gt "$cols" ] && [ -n "$effort_plain" ]; then
    effort_plain="" effort_col=""
    metrics_plain="$(join_plain "$model" "$meter_plain" "$over_plain" "$cache_plain" "$cost_plain" "$rl_plain")"
  fi
  if [ "${#metrics_plain}" -gt "$cols" ] && [ -n "$rl_plain" ]; then
    rl_plain="" rl_col=""
    metrics_plain="$(join_plain "$model" "$effort_plain" "$meter_plain" "$over_plain" "$cache_plain" "$cost_plain")"
  fi
  if [ "${#metrics_plain}" -gt "$cols" ] && [ -n "$cache_plain" ]; then
    cache_plain="" cache_col=""
    metrics_plain="$(join_plain "$model" "$effort_plain" "$meter_plain" "$over_plain" "$cost_plain")"
  fi
  if [ "${#metrics_plain}" -gt "$cols" ] && [ -n "$toks" ]; then
    meter_plain="${meter_plain%"$toks"}"
    meter_col="${esc}[${mcolor}m${meter_plain}${esc}[0m"
    metrics_plain="$(join_plain "$model" "$effort_plain" "$meter_plain" "$over_plain" "$cost_plain")"
  fi
  if [ "${#metrics_plain}" -gt "$cols" ] && [ -n "$cost_plain" ]; then
    cost_plain="" cost_col=""
  fi
  metrics_col="$(join_plain "$model_col" "$effort_col" "$meter_col" "$over_col" "$cache_col" "$cost_col" "$rl_col")"
  printf '%s\n' "$id_col"
  [ -n "$metrics_col" ] && printf '%s\n' "$metrics_col"
fi
