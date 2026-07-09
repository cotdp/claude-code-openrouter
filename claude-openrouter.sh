#!/bin/sh
# claude-openrouter — launch Claude Code against OpenRouter's Anthropic-compatible
# endpoint ("Anthropic skin"), defaulting to x-ai/grok-4.5.
#
# Two OpenRouter/Claude-Code incompatibilities are handled automatically:
#   1. Always-on reasoning models (grok-4.5, ...) return `thinking` blocks that
#      OpenRouter emits with empty signatures; Claude Code discards them and shows
#      no output. A tiny local proxy (claude-openrouter-proxy.py) strips those
#      blocks so the real text/tool_use survives.
#   2. Several MCP tool schemas (open-ended maps) fail xAI's strict function-calling
#      validator and 400 the whole request, so MCP is disabled by default.
#
# The OpenRouter API key is read from ~/.claude/.env.local (OPENROUTER_API_KEY=...)
# unless already present in the environment.
#
# Usage:
#   claude-openrouter [--model <openrouter-model-id>] [claude args...]
#
# Env overrides:
#   OPENROUTER_API_KEY        key (else sourced from the env file below)
#   OPENROUTER_ENV_FILE       env file          (default ~/.claude/.env.local)
#   OPENROUTER_MODEL          default model     (default x-ai/grok-4.5)
#   OPENROUTER_BASE_URL       upstream endpoint (default https://openrouter.ai/api)
#   OPENROUTER_API_TIMEOUT_MS request cap       (default 1200000 = 20 min)
#   OPENROUTER_NO_PROXY=1     bypass the thinking-block proxy (talk to OpenRouter direct)
#   OPENROUTER_ENABLE_MCP=1   keep MCP servers enabled (may 400 on incompatible tools)
set -eu

BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api}"
ENV_FILE="${OPENROUTER_ENV_FILE:-$HOME/.claude/.env.local}"
API_TIMEOUT="${OPENROUTER_API_TIMEOUT_MS:-1200000}"

# --- parse our own --model flag, forward everything else to claude -----------
# Rotation trick: pop each original arg once; consumed flags drop out, the rest
# are pushed to the end preserving spaces/quoting. argc tracks only originals.
MODEL="${OPENROUTER_MODEL:-x-ai/grok-4.5}"
argc=$#
while [ "$argc" -gt 0 ]; do
  arg="$1"; shift; argc=$((argc - 1))
  case "$arg" in
    --model=*)
      MODEL="${arg#--model=}"
      continue ;;
    --model)
      if [ "$argc" -gt 0 ]; then
        MODEL="$1"; shift; argc=$((argc - 1))
      else
        echo "claude-openrouter: --model requires a value" >&2
        exit 2
      fi
      continue ;;
  esac
  set -- "$@" "$arg"
done

# --- resolve the OpenRouter API key ------------------------------------------
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  if [ -r "$ENV_FILE" ]; then
    # Extract just OPENROUTER_API_KEY — don't source the whole file (avoids
    # executing arbitrary lines and tripping `set -u`).
    line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$ENV_FILE" 2>/dev/null | tail -n1 || true)"
    val="${line#*=}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    OPENROUTER_API_KEY="$val"
  fi
fi

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "claude-openrouter: no OPENROUTER_API_KEY found." >&2
  echo "                   Set it in $ENV_FILE (OPENROUTER_API_KEY=...) or the environment." >&2
  exit 1
fi

# --- resolve the real claude binary (avoid recursing into this wrapper) ------
resolve_claude() {
  self="$(command -v -- "$0" 2>/dev/null || echo "$0")"
  # newline-safe iteration: claude path may contain spaces
  found="$(command -v -a claude 2>/dev/null | while IFS= read -r c; do
    [ "$c" = "$self" ] && continue
    printf '%s\n' "$c"
    break
  done)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  for c in "$HOME/.local/bin/claude" /usr/local/bin/claude; do
    [ -x "$c" ] && [ "$c" != "$self" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

CLAUDE_BIN="$(resolve_claude)" || {
  echo "claude-openrouter: could not find the 'claude' binary on PATH" >&2
  exit 127
}

# --- start the thinking-block-stripping proxy (unless disabled) --------------
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "$HOME/.local/bin")"
PROXY=""
for p in "$SELF_DIR/claude-openrouter-proxy.py" "$HOME/.local/bin/claude-openrouter-proxy.py"; do
  [ -f "$p" ] && { PROXY="$p"; break; }
done

PROXY_PID=""
PORTFILE=""
PROXY_LOG=""
cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  [ -n "$PORTFILE" ] && rm -f "$PORTFILE" 2>/dev/null || true
  # keep the log only if it captured anything (tracebacks are worth reading)
  if [ -n "$PROXY_LOG" ] && [ ! -s "$PROXY_LOG" ]; then
    rm -f "$PROXY_LOG" 2>/dev/null || true
  fi
}

if [ "${OPENROUTER_NO_PROXY:-0}" != "1" ]; then
  if [ -n "$PROXY" ] && command -v python3 >/dev/null 2>&1; then
    PORTFILE="$(mktemp "${TMPDIR:-/tmp}/clor-port.XXXXXX")"
    PROXY_LOG="${TMPDIR:-/tmp}/clor-proxy.$$.log"
    # Redirect proxy output: a traceback on the inherited stderr would be
    # drawn straight into the Claude Code TUI.
    OPENROUTER_BASE_URL="$BASE_URL" python3 "$PROXY" "$PORTFILE" >"$PROXY_LOG" 2>&1 &
    PROXY_PID=$!
    trap cleanup EXIT INT TERM
    PORT=""; i=0
    while [ "$i" -lt 100 ]; do
      PORT="$(cat "$PORTFILE" 2>/dev/null || true)"
      [ -n "$PORT" ] && break
      kill -0 "$PROXY_PID" 2>/dev/null || {
        echo "claude-openrouter: proxy failed to start (log: $PROXY_LOG)" >&2
        exit 1
      }
      i=$((i + 1)); sleep 0.1
    done
    case "$PORT" in
      ''|*[!0-9]*)
        echo "claude-openrouter: proxy reported an invalid port '$PORT' (log: $PROXY_LOG)" >&2
        exit 1 ;;
    esac
    BASE_URL="http://127.0.0.1:$PORT"
  else
    echo "claude-openrouter: proxy unavailable (no script or python3); grok output may be empty. Set OPENROUTER_NO_PROXY=1 to silence." >&2
  fi
fi

# --- clear any inherited cloud-provider / real-key routing -------------------
unset CLAUDE_CODE_USE_BEDROCK
unset CLAUDE_CODE_USE_VERTEX
unset CLAUDE_CODE_USE_FOUNDRY

# --- endpoint + auth (OpenRouter "Anthropic skin", via proxy) ----------------
# Key goes in ANTHROPIC_AUTH_TOKEN (flows through the proxy as Authorization);
# ANTHROPIC_API_KEY must be empty so Claude Code doesn't hit Anthropic direct.
export ANTHROPIC_BASE_URL="$BASE_URL"
export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
export ANTHROPIC_API_KEY=""

# --- model: point every tier at the chosen OpenRouter model ------------------
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_FABLE_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"

export ANTHROPIC_CUSTOM_MODEL_OPTION="$MODEL"
export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="OpenRouter: $MODEL"
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="via openrouter.ai Anthropic skin"

# --- quieter, no autoupdate --------------------------------------------------
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_AUTOUPDATE=1
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1

# --- timeouts ----------------------------------------------------------------
export API_TIMEOUT_MS="$API_TIMEOUT"
export API_FORCE_IDLE_TIMEOUT="$API_TIMEOUT"

# --- MCP off by default (open-map tool schemas 400 on xAI strict validation) -
STRICT_MCP="--strict-mcp-config"
[ "${OPENROUTER_ENABLE_MCP:-0}" = "1" ] && STRICT_MCP=""

# Run (not exec) so the cleanup trap can stop the proxy when claude exits.
code=0
"$CLAUDE_BIN" --dangerously-skip-permissions $STRICT_MCP "$@" || code=$?
exit "$code"
