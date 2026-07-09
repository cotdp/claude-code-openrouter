#!/bin/bash
# Claude Code statusline.
#
# In OpenRouter sessions (claude-openrouter sets an `sk-or-` ANTHROPIC_AUTH_TOKEN),
# show live OpenRouter cost tracking via statusline.ts — provider, model, cumulative
# cost and cache discount, fetched from the OpenRouter /v1/generation endpoint.
#
# In normal Anthropic-subscription sessions the OpenRouter token is absent, so the
# sample script would just nag "Set ANTHROPIC_AUTH_TOKEN...". A global statusLine
# runs in EVERY session, so we guard: non-OpenRouter sessions get a clean
# model / directory / git-branch line instead.
set -u

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

# --- fallback: minimal statusline for non-OpenRouter sessions ----------------
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
  printf '%s  %s  \xee\x82\xa0 %s' "$model" "$base" "$branch"   #  = branch glyph
else
  printf '%s  %s' "$model" "$base"
fi
