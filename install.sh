#!/bin/sh
# install.sh — install claude-code-openrouter on macOS or Linux.
#
# From a clone:      ./install.sh
# One-liner:         curl -fsSL https://raw.githubusercontent.com/cotdp/claude-code-openrouter/main/install.sh | sh
# With statusline:   ./install.sh --statusline        (or: ... | sh -s -- --statusline)
# Custom location:   PREFIX=~/bin ./install.sh
# Remove:            ./install.sh --uninstall         (add --statusline to remove that too)
#
# The installer copies the launcher, the proxy, and the model aliases into
# $PREFIX (default ~/.local/bin). When run outside a clone (e.g. piped from
# curl) it downloads the scripts from GitHub instead. --statusline additionally
# copies the cost-tracking statusline into ~/.claude/hooks/ and prints the
# settings.json snippet to enable it (your settings.json is never edited).
set -eu

REPO_RAW="${CLOR_REPO_RAW:-https://raw.githubusercontent.com/cotdp/claude-code-openrouter/main}"
PREFIX="${PREFIX:-$HOME/.local/bin}"

# name-on-PATH : file-in-repo
FILES="
claude-openrouter:claude-openrouter.sh
claude-openrouter-proxy.py:claude-openrouter-proxy.py
claude-grok:claude-grok.sh
claude-glm:claude-glm.sh
claude-fugu:claude-fugu.sh
claude-fusion:claude-fusion.sh
claude-kimi:claude-kimi.sh
claude-qwen:claude-qwen.sh
claude-fable-5:claude-fable-5.sh
"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

HOOKS_DIR="$HOME/.claude/hooks"
SL_FILES="statusline.sh statusline.ts"

# --- options --------------------------------------------------------------------
UNINSTALL=0
STATUSLINE=0
for opt in "$@"; do
  case "$opt" in
    --uninstall)  UNINSTALL=1 ;;
    --statusline) STATUSLINE=1 ;;
    --install)    ;;
    *) die "unknown option '$opt' (supported: --statusline, --uninstall)" ;;
  esac
done

# --- uninstall ----------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  removed=0
  for pair in $FILES; do
    name="${pair%%:*}"
    if [ -e "$PREFIX/$name" ]; then
      rm -f "$PREFIX/$name"
      say "removed $PREFIX/$name"
      removed=$((removed + 1))
    fi
  done
  if [ "$STATUSLINE" = 1 ]; then
    for f in $SL_FILES; do
      if [ -e "$HOOKS_DIR/$f" ]; then
        rm -f "$HOOKS_DIR/$f"
        say "removed $HOOKS_DIR/$f"
        removed=$((removed + 1))
      fi
    done
    say "note: remove the statusLine block from ~/.claude/settings.json yourself."
  elif [ -e "$HOOKS_DIR/statusline.sh" ]; then
    say "note: statusline left in $HOOKS_DIR (add --statusline to remove it too)."
  fi
  [ "$removed" -gt 0 ] || say "nothing to remove"
  say "note: ~/.claude/.env.local (your API key) was left untouched."
  exit 0
fi

# --- dependency checks ----------------------------------------------------------
command -v python3 >/dev/null 2>&1 \
  || die "python3 is required (the local proxy runs on it). Install it and re-run."

if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  warn "the 'claude' binary was not found — install Claude Code first:"
  warn "  curl -fsSL https://claude.ai/install.sh | bash"
fi

# --- locate sources: local clone, or fetch from GitHub -------------------------
# $0 is "sh" when piped from curl, so also test that the file actually exists.
srcdir=""
case "$0" in
  */*) d="$(dirname -- "$0")"; [ -f "$d/claude-openrouter.sh" ] && srcdir="$d" ;;
esac
[ -z "$srcdir" ] && [ -f ./claude-openrouter.sh ] && srcdir=.

tmpdir=""
if [ -z "$srcdir" ]; then
  command -v curl >/dev/null 2>&1 || die "not in a clone and curl is unavailable — cannot fetch sources"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/clor-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT INT TERM
  say "fetching scripts from $REPO_RAW ..."
  for pair in $FILES; do
    file="${pair#*:}"
    curl -fsSL "$REPO_RAW/$file" -o "$tmpdir/$file" || die "download failed: $file"
  done
  if [ "$STATUSLINE" = 1 ]; then
    mkdir -p "$tmpdir/statusline"
    for f in $SL_FILES; do
      curl -fsSL "$REPO_RAW/statusline/$f" -o "$tmpdir/statusline/$f" || die "download failed: statusline/$f"
    done
  fi
  srcdir="$tmpdir"
fi

# --- install --------------------------------------------------------------------
mkdir -p "$PREFIX"
for pair in $FILES; do
  name="${pair%%:*}"; file="${pair#*:}"
  [ -f "$srcdir/$file" ] || die "missing source file: $srcdir/$file"
  install -m 0755 "$srcdir/$file" "$PREFIX/$name"
  say "installed $PREFIX/$name"
done

if [ "$STATUSLINE" = 1 ]; then
  mkdir -p "$HOOKS_DIR"
  for f in $SL_FILES; do
    [ -f "$srcdir/statusline/$f" ] || die "missing source file: $srcdir/statusline/$f"
    [ -e "$HOOKS_DIR/$f" ] && sl_updated=1 || sl_updated=0
    install -m 0755 "$srcdir/statusline/$f" "$HOOKS_DIR/$f"
    say "$([ "$sl_updated" = 1 ] && echo updated || echo installed) $HOOKS_DIR/$f"
  done
  if ! command -v bun >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
    warn "statusline needs bun or npx (Node) at runtime — install one of them."
  fi
fi

# --- post-install checks ---------------------------------------------------------
case ":$PATH:" in
  *:"$PREFIX":*) ;;
  *)
    warn "$PREFIX is not on your PATH. Add this to your shell profile:"
    warn "  export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

ENV_FILE="$HOME/.claude/.env.local"
if [ -r "$ENV_FILE" ] && grep -q '^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}OPENROUTER_API_KEY=' "$ENV_FILE" 2>/dev/null; then
  say "API key: found OPENROUTER_API_KEY in $ENV_FILE"
else
  say ""
  say "Next step — add your OpenRouter API key (https://openrouter.ai/settings/keys):"
  say "  mkdir -p ~/.claude && echo 'OPENROUTER_API_KEY=\"sk-or-...\"' >> ~/.claude/.env.local"
fi

if [ "$STATUSLINE" = 1 ]; then
  SETTINGS="$HOME/.claude/settings.json"
  say ""
  if [ -r "$SETTINGS" ] && grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    say "statusline: settings.json already has a statusLine entry — point it at:"
    say "  $HOOKS_DIR/statusline.sh"
  else
    say "statusline: add this to $SETTINGS to enable it:"
    say '  {'
    say '    "statusLine": {'
    say '      "type": "command",'
    say "      \"command\": \"$HOOKS_DIR/statusline.sh\""
    say '    }'
    say '  }'
  fi
fi

say ""
say "Done. Try:  claude-grok    (or claude-glm, claude-kimi, claude-qwen,"
say "            claude-fugu, claude-fusion, claude-fable-5, claude-openrouter --model <slug>)"
