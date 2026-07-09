#!/bin/bash
# Claude Code statusline.
#
# In OpenRouter sessions (an `sk-or-` ANTHROPIC_AUTH_TOKEN or an openrouter base
# URL), show live OpenRouter cost tracking via statusline.ts — provider, model,
# cumulative cost and cache discount, fetched from the OpenRouter /v1/generation
# endpoint.
#
# In normal Anthropic-subscription sessions the OpenRouter token is absent, so
# show a clean `model  dir  branch` line, plus subscription usage — the 5-hour
# window, the 7-day window, and any scoped model quota (Fable, Opus, ...) — from
# the unofficial OAuth usage endpoint. Usage is cached (default 60s) and
# refreshed in a locked background job: a statusline renders constantly, so it
# must never block on the network.
#
# Usage styles (flag on the settings.json command, or CLAUDE_USAGE_STYLE env):
#   default        mini progress bars + reset countdowns:  5h █████░ 80% ↻31m
#   --compact      label + percent only:                   5h 80%
#
# Env:
#   CLAUDE_USAGE_TTL=60   usage cache lifetime in seconds; 0 disables the segment
#   CLAUDE_USAGE_STYLE    "bars" (default) or "compact"
set -u

STYLE="${CLAUDE_USAGE_STYLE:-bars}"
[ "${1:-}" = "--compact" ] && STYLE="compact"

input="$(cat)"
dir="$(cd -- "$(dirname -- "$0")" && pwd)"

is_openrouter=0
case "${ANTHROPIC_AUTH_TOKEN:-}" in sk-or-*) is_openrouter=1 ;; esac
case "${ANTHROPIC_BASE_URL:-}" in *openrouter*) is_openrouter=1 ;; esac

if [ "$is_openrouter" = 1 ]; then
  # bun runs TypeScript natively (fast, no per-call download); fall back to npx tsx.
  if command -v bun >/dev/null 2>&1; then
    printf '%s' "$input" | bun "$dir/statusline.ts"
  elif command -v npx >/dev/null 2>&1; then
    printf '%s' "$input" | npx -y tsx "$dir/statusline.ts"
  else
    printf 'OpenRouter (install bun or npx for cost tracking)'
  fi
  exit 0
fi

# --- subscription usage: 5h / 7d / scoped (Fable, ...) quotas ------------------
# Same endpoint + keychain flow as a SwiftBar/xbar usage widget, adapted for a
# statusline: render from cache instantly, refresh out-of-band.
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
TTL="${CLAUDE_USAGE_TTL:-60}"
CACHE="${TMPDIR:-/tmp}/claude-sub-usage.json"
LOCK="$CACHE.lock"

refresh_usage() {  # runs in a detached subshell; never blocks the render
  token=""
  if command -v security >/dev/null 2>&1; then           # macOS keychain
    token="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  fi
  if [ -z "$token" ] && [ -r "$HOME/.claude/.credentials.json" ]; then  # Linux
    token="$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)"
  fi
  [ -n "$token" ] || return 0
  out="$(curl -sS -m 8 "$USAGE_URL" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)" || return 0
  # only cache a response that actually looks like usage data
  printf '%s' "$out" | jq -e '(.limits? | arrays) // .five_hour? // empty' >/dev/null 2>&1 || return 0
  printf '%s' "$out" > "$CACHE.tmp.$$" && mv -f "$CACHE.tmp.$$" "$CACHE"
}

usage_segment() {
  [ "$TTL" -gt 0 ] 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0

  now="$(date +%s)"
  age=$((TTL + 1))
  if [ -f "$CACHE" ]; then
    mtime="$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)"
    age=$((now - mtime))
  fi

  if [ "$age" -gt "$TTL" ]; then
    if mkdir "$LOCK" 2>/dev/null; then
      ( trap 'rmdir "$LOCK" 2>/dev/null' EXIT; refresh_usage ) >/dev/null 2>&1 &
    else
      # break a stale lock (crashed refresher); next render retries
      lmtime="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now")"
      [ $((now - lmtime)) -gt 60 ] && rmdir "$LOCK" 2>/dev/null
    fi
  fi

  [ -r "$CACHE" ] || return 0
  # Never render data old enough to mislead: quotas move and scoped quotas
  # (Fable, ...) can be withdrawn entirely. If refreshes keep failing (expired
  # token, endpoint gone), the segment disappears instead of lying.
  [ "$age" -le 1800 ] || return 0
  # label<TAB>percent<TAB>reset per active quota; limits[] preferred, legacy
  # keys as fallback. Reset is a compact countdown (2h13m / 4d2h / now).
  # Scoped entries are whatever the API currently grants — none is normal.
  # Every field access is defensive: a malformed entry drops that entry (or
  # its reset), never the whole segment.
  jq -r '
    def fmt_reset:
      try (
        if . == null or . == "" then "" else
          ((sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) - now) as $s
          | if $s <= 0 then "now"
            elif $s >= 86400 then "\($s/86400|floor)d\(($s%86400)/3600|floor)h"
            elif $s >= 3600 then "\($s/3600|floor)h\(($s%3600)/60|floor)m"
            else "\($s/60|floor)m" end
        end
      ) catch "";
    (if (.limits | type) == "array" and (.limits | length) > 0 then
       [.limits[] | select((.percent | type) == "number") | {
          label: (if .kind == "session" then "5h"
                  elif .kind == "weekly_all" then "7d"
                  elif .kind == "weekly_scoped" then ((.scope.model.display_name // "scoped") | tostring)
                  else ((.kind // "?") | tostring) end),
          pct: .percent,
          reset: ((.resets_at // "") | fmt_reset)}]
     else
       [{label: "5h", pct: (.five_hour.utilization // null),
         reset: ((.five_hour.resets_at // "") | fmt_reset)},
        {label: "7d", pct: (.seven_day.utilization // null),
         reset: ((.seven_day.resets_at // "") | fmt_reset)}]
       | map(select((.pct | type) == "number"))
     end)
    | .[] | "\(.label)\t\(.pct)\t\(.reset)"
  ' "$CACHE" 2>/dev/null | while IFS="$(printf '\t')" read -r label pct reset; do
    p="${pct%%.*}"
    case "$p" in ''|*[!0-9]*) continue ;; esac         # non-numeric: skip entry
    if [ "$p" -ge 80 ] 2>/dev/null; then c="31"        # red
    elif [ "$p" -ge 50 ] 2>/dev/null; then c="33"      # yellow
    else c="32"; fi                                    # green
    if [ "$STYLE" = "compact" ]; then
      printf ' \033[2m%s\033[0m \033[%sm%s%%\033[0m' "$label" "$c" "$p"
      continue
    fi
    # mini progress bar, SwiftBar-style: █ filled / ░ empty, rounded
    w=6
    filled=$(( (p * w + 50) / 100 ))
    [ "$filled" -gt "$w" ] && filled=$w
    [ "$filled" -lt 0 ] && filled=0
    bar=""
    i=0
    while [ "$i" -lt "$w" ]; do
      if [ "$i" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
      i=$((i + 1))
    done
    printf ' \033[2m%s\033[0m \033[%sm%s %s%%\033[0m' "$label" "$c" "$bar" "$p"
    [ -n "$reset" ] && printf ' \033[2m↻%s\033[0m' "$reset"
  done
}

# --- fallback statusline for non-OpenRouter sessions ---------------------------
if command -v jq >/dev/null 2>&1; then
  model="$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "claude"')"
  cdir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // "."')"
else
  model="claude"
  cdir="$PWD"
fi
base="$(basename -- "$cdir")"
branch="$(git -C "$cdir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

if [ -n "$branch" ]; then
  printf '%s  %s  \xee\x82\xa0 %s' "$model" "$base" "$branch"   #  = branch glyph
else
  printf '%s  %s' "$model" "$base"
fi
usage_segment
