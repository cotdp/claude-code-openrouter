# claude-code-openrouter

Run [Claude Code](https://code.claude.com/docs/en/overview) against any model on
[OpenRouter](https://openrouter.ai) — grok, GLM, Kimi, Qwen, and friends — with the
compatibility problems fixed automatically.

```
claude-grok          # x-ai/grok-4.5
claude-glm           # z-ai/glm-5.2
claude-kimi          # moonshotai/kimi-k2.7-code
claude-qwen          # qwen/qwen3.7-plus
claude-fugu          # sakana/fugu-ultra
claude-fusion        # openrouter/fusion
claude-fable-5       # anthropic/claude-fable-5 (native: no proxy, MCP enabled)
claude-openrouter --model any/other-model
```

## The two problems this solves

OpenRouter exposes an [Anthropic-compatible endpoint](https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration)
(`https://openrouter.ai/api`), so pointing Claude Code at it *almost* works. Two things break
with non-Anthropic models:

1. **Empty replies from reasoning models.** Always-on reasoners (grok-4.5, etc.) return
   `thinking` / `redacted_thinking` content blocks whose `signature` fields OpenRouter leaves
   empty. Claude Code cannot validate them and silently discards the whole assistant message —
   the model's actual text and tool calls never reach you. There is no request parameter that
   stops the blocks (`reasoning: {exclude: true}` does not); only rewriting the *response* works.

2. **`400 Provider returned error` when MCP servers are loaded.** Claude Code sends every tool
   schema with each request. Many MCP tools use open-ended-map JSON schemas
   (`propertyNames` + schema-valued `additionalProperties`) that Anthropic accepts but stricter
   provider-side validators (e.g. xAI) reject — and one bad tool fails the entire request.
   Sanitizing schemas on the way in doesn't help because OpenRouter re-derives them during
   provider conversion.

## How it works

```
claude ──► 127.0.0.1:<ephemeral>  claude-openrouter-proxy.py
                │                   • strips thinking/redacted_thinking blocks
                │                   • re-indexes surviving content blocks
                │                   • SSE + non-streaming, CRLF-safe, multi-line-data-safe
                └─────────────────► https://openrouter.ai/api
```

`claude-openrouter` (the wrapper):

- reads `OPENROUTER_API_KEY` from `~/.claude/.env.local` (or the environment) — extracts the
  single key with `grep`, never sources the file
- spawns the proxy on an ephemeral port and points `ANTHROPIC_BASE_URL` at it; the key flows
  through Claude Code's own `Authorization` header, so the proxy never touches the key file
- points every model tier (Opus/Sonnet/Haiku/Fable + subagents) at the chosen model
- disables MCP by default (`--strict-mcp-config`) to avoid problem #2
- tears the proxy down on exit; a parent-watchdog inside the proxy also self-terminates if the
  wrapper is SIGKILLed, so no orphans

`claude-openrouter-proxy.py` (the proxy) is stdlib-only Python 3, threaded, and handles:
streaming SSE and non-streaming JSON, CRLF/LF framing, chunk boundaries anywhere, multi-line
`data:` events, comment keepalives (`: OPENROUTER PROCESSING`), upstream timeouts, and
mid-stream upstream failures (surfaced to Claude Code as a proper SSE `error` event rather than
a hang or a silent empty reply).

The alias scripts (`claude-grok`, `claude-glm`, …) are one-liners that call
`claude-openrouter --model <slug>`. `claude-fable-5` is the exception: a native Anthropic model
behaves exactly like the first-party API, so it sets `OPENROUTER_NO_PROXY=1` and
`OPENROUTER_ENABLE_MCP=1` for full-feature parity (signed thinking, MCP servers).

## Install

Works on macOS and Linux. Requires `python3` (the proxy is stdlib-only) and
[Claude Code](https://code.claude.com/docs/en/overview) itself.

```bash
# one-liner (no clone needed)
curl -fsSL https://raw.githubusercontent.com/cotdp/claude-code-openrouter/main/install.sh | sh

# or from a clone
git clone https://github.com/cotdp/claude-code-openrouter
cd claude-code-openrouter && ./install.sh
```

The installer puts everything in `~/.local/bin` (override with `PREFIX=~/bin ./install.sh`),
checks your dependencies and PATH, and tells you if the API key is missing. Add
`--statusline` to also install the [cost-tracking statusline](#cost-statusline-optional)
(one-liner form: `… | sh -s -- --statusline`). Uninstall with `./install.sh --uninstall`
(add `--statusline` to remove that too).

```bash
# add your key (https://openrouter.ai/settings/keys), then go
echo 'OPENROUTER_API_KEY="sk-or-..."' >> ~/.claude/.env.local
claude-grok
```

<details>
<summary>Manual install (no installer)</summary>

```bash
install -m 0755 claude-openrouter.sh        ~/.local/bin/claude-openrouter
install -m 0755 claude-openrouter-proxy.py  ~/.local/bin/claude-openrouter-proxy.py
for a in grok glm fugu fusion kimi qwen fable-5; do
  install -m 0755 "claude-$a.sh" ~/.local/bin/"claude-$a"
done
```
</details>

> **Note:** the wrapper launches Claude Code with `--dangerously-skip-permissions`
> (my personal preference for these sessions). Remove that flag from the last line of
> `claude-openrouter.sh` if you want normal permission prompts.

## Configuration

All via environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `OPENROUTER_API_KEY` | from `~/.claude/.env.local` | OpenRouter key |
| `OPENROUTER_ENV_FILE` | `~/.claude/.env.local` | where to look for the key |
| `OPENROUTER_MODEL` | `x-ai/grok-4.5` | default model (`--model` overrides) |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api` | upstream endpoint |
| `OPENROUTER_API_TIMEOUT_MS` | `1200000` | Claude Code request cap (20 min) |
| `OPENROUTER_PROXY_IDLE_TIMEOUT_MS` | `1200000` | proxy per-socket-op upstream timeout |
| `OPENROUTER_NO_PROXY=1` | – | bypass the proxy (direct to OpenRouter) |
| `OPENROUTER_ENABLE_MCP=1` | – | keep MCP servers on (may 400, see problem #2) |
| `CLOR_DEBUG=<dir>` | – | dump raw-in/filtered-out streams for debugging |

## Tests

```bash
python3 tests/test_streamfilter.py
```

16 cases covering the SSE rewrite engine: thinking-block drop + contiguous re-indexing (deltas
follow the remap), byte-by-byte feed equivalence, CRLF framing straddling chunk boundaries,
multi-line `data:` events, comment/ping/`[DONE]`/error passthrough, and unterminated-final-event
flush.

## Troubleshooting

- **`API Error: 400 Provider returned error`** — you re-enabled MCP
  (`OPENROUTER_ENABLE_MCP=1`) against a strict provider. Turn it back off, or use
  `claude-fable-5`.
- **Empty replies** — the proxy isn't in the path. Check you didn't set
  `OPENROUTER_NO_PROXY=1`, and that `claude-openrouter-proxy.py` sits next to the wrapper or in
  `~/.local/bin`.
- **Anything weird mid-stream** — run with `CLOR_DEBUG=/tmp/clor` and inspect
  `raw_in.sse` / `filtered_out.sse` / `requests.log`. Proxy crashes land in
  `$TMPDIR/clor-proxy.<pid>.log` (kept only if non-empty).
- **Model slug typo** — validate against the catalog:
  `curl -s https://openrouter.ai/api/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'`

## Cost statusline (optional)

OpenRouter usage is billed per token. `statusline/` adds live cost tracking to Claude Code's
statusline:

```
xAI: grok-4.5 - $0.0747 - cache discount: $0.04
```

- `statusline/statusline.ts` — OpenRouter's cost tracker (vendored from
  [openrouter-examples](https://github.com/OpenRouterTeam/openrouter-examples/tree/main/claude-code),
  MIT): reads the session transcript, resolves each `gen-*` message against OpenRouter's
  `/v1/generation` API, and accumulates provider / model / cost / cache discount.
- `statusline/statusline.sh` — my session-aware wrapper. A `statusLine` command in
  `settings.json` runs in **every** Claude Code session, but the cost tracker only makes sense
  where an OpenRouter token exists — elsewhere it just nags. The wrapper detects OpenRouter
  sessions (an `sk-or-` auth token or an openrouter base URL) and runs the tracker there;
  everything else gets a clean `model  dir   branch` line. It also prefers `bun` for
  instant native-TypeScript startup (statuslines render constantly), falling back to `npx tsx`.

Install:

```bash
./install.sh --statusline    # copies both files into ~/.claude/hooks/
```

or manually:

```bash
mkdir -p ~/.claude/hooks
install -m 0755 statusline/statusline.sh ~/.claude/hooks/statusline.sh
install -m 0644 statusline/statusline.ts ~/.claude/hooks/statusline.ts
```

Then add to `~/.claude/settings.json` (the installer prints this snippet; it never edits
your settings itself):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/hooks/statusline.sh"
  }
}
```

Requires `bun` or `npx`; the fallback line uses `jq` if available.

## License

[MIT](LICENSE)
