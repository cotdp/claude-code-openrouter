# HANDOFF — claude-code-openrouter

Working handoff for continuing this project. Read this top to bottom; it captures the
non-obvious context that isn't in the code.

## What this is

Shell wrappers that run Anthropic's **Claude Code** CLI against **OpenRouter** models
(grok, GLM, Kimi, Qwen, gpt-5.6-sol, …). Claude Code speaks the Anthropic Messages API;
OpenRouter exposes an Anthropic-compatible endpoint ("Anthropic skin") at
`https://openrouter.ai/api`, so `ANTHROPIC_BASE_URL` alone *almost* works. This project
fixes the two things that break with non-Anthropic models, and adds per-model launchers
plus a cost/usage statusline.

- **Repo:** https://github.com/cotdp/claude-code-openrouter (public, MIT)
- **Local checkout:** `~/workspaces/github/claude-code-openrouter`
- **GitHub account:** `cotdp` (personal). Run `gh auth switch --user cotdp` before any gh op.
- **Branch:** `main`. Working tree is clean as of handoff.
- **Installed to:** `~/.local/bin/` (on this Mac, mini.local, and hwi.local — see Deployment).

## The two problems (this is the crux — understand these first)

### Problem 1: empty-signature thinking blocks → blank replies
Always-on reasoning models (grok-4.5, glm, kimi, sol, …) return `thinking` /
`redacted_thinking` content blocks. Via OpenRouter's Anthropic skin those blocks come back
with **empty `signature` fields**. Claude Code can't validate them and **silently discards
the entire assistant message** — you get a blank reply even though the model generated real
text. No request parameter stops this (`reasoning:{exclude:true}` does NOT). The only fix is
rewriting the **response**.

**Our fix:** a local proxy (`claude-openrouter-proxy.py`) sits between Claude Code and
OpenRouter, **strips** `thinking`/`redacted_thinking` blocks from the response, and
**re-indexes** the surviving content blocks so the SSE stream stays well-formed (Claude Code
requires contiguous block indices starting at 0). This is the project's core novelty — other
tools inject fake signatures, preserve/repair them, or disable reasoning; none strip-and-reindex.

### Problem 2: MCP tool schemas → 400 on strict providers
Claude Code sends every MCP tool's JSON schema with each request. Some MCP tools (Notion's
`notion-create-pages` is the canonical offender) use **open-ended-map schemas**:
`propertyNames` + a schema-valued `additionalProperties` (e.g. `{"anyOf":[...]}`). Anthropic
accepts these; **xAI's strict function-calling validator rejects them**, and one bad tool
**400s the entire request** (`API Error: 400 Provider returned error`). Sanitizing on the way
in doesn't help — OpenRouter re-derives the schema during provider conversion.

**Our fix:** disable MCP (`--strict-mcp-config`) for models whose provider rejects these
schemas. As of handoff, **grok is the only such model** — every other bundled model was
tested to accept them (see Model matrix).

## Architecture

```
claude-<model>  (thin alias)
   └─ exec claude-openrouter --model <slug> [--enable-mcp] [--no-proxy]
        ├─ sources OPENROUTER_API_KEY from ~/.claude/.env.local
        ├─ spawns claude-openrouter-proxy.py on an ephemeral 127.0.0.1 port (unless --no-proxy)
        │     └─ strips thinking blocks, forwards to https://openrouter.ai/api
        ├─ sets ANTHROPIC_BASE_URL=http://127.0.0.1:<port>, ANTHROPIC_AUTH_TOKEN=<key>, ANTHROPIC_API_KEY=""
        ├─ points every model tier (opus/sonnet/haiku/fable + subagents) at <slug>
        ├─ adds --strict-mcp-config unless --enable-mcp
        └─ runs claude (NOT exec) so a cleanup trap can kill the proxy on exit
```

Auth note: the key flows through Claude Code's own `Authorization: Bearer` header to the
proxy and on to OpenRouter. **The proxy never reads the key file.**

## Files

| File | Role |
|---|---|
| `claude-openrouter.sh` | Main wrapper. Arg parsing (`--model`/`--enable-mcp`/`--no-proxy`), key sourcing, proxy lifecycle, env setup, MCP toggle. Installed as `claude-openrouter`. |
| `claude-openrouter-proxy.py` | stdlib-only Python 3 proxy. `StreamFilter` class does the SSE rewrite. Threaded, handles streaming + non-streaming, CRLF/LF, chunk boundaries anywhere, multi-line `data:`, mid-stream upstream errors, parent-death watchdog. |
| `claude-<model>.sh` | Thin aliases → `claude-openrouter --model <slug> [flags]`. |
| `install.sh` | POSIX installer (macOS+Linux). Works from clone or curl-piped (fetches from GitHub raw). `PREFIX=`, `--statusline`, `--uninstall`. |
| `statusline/statusline.sh` | Session-aware statusline (see below). |
| `statusline/statusline.ts` | OpenRouter cost tracker, vendored MIT from OpenRouterTeam/openrouter-examples (attribution header only change). |
| `tests/test_streamfilter.py` | 16 unit tests for `StreamFilter`. Run: `python3 tests/test_streamfilter.py`. |

## Model capability matrix (tested 2026-07-10)

| Alias | Slug | Proxy | MCP | Why |
|---|---|---|---|---|
| claude-grok | x-ai/grok-4.5 | on | **off** | xAI rejects open-map schemas |
| claude-glm | z-ai/glm-5.2 | on | on | tested OK |
| claude-kimi | moonshotai/kimi-k3 | on | on | tested OK |
| claude-qwen | qwen/qwen3.7-plus | on | on | tested OK |
| claude-fugu | sakana/fugu-ultra | on | on | tested OK |
| claude-fusion | openrouter/fusion | on | on | tested OK |
| claude-sol | openai/gpt-5.6-sol | on | on | schemas OK, thinking still unsigned |
| claude-sol-pro | openai/gpt-5.6-sol-pro | on | on | same as sol |
| claude-fable-5 | anthropic/claude-fable-5 | **off** | on | native Anthropic: signed thinking, no workaround needed |

Only two models deviate from the default (proxy-on, MCP-on): **grok** (MCP off) and
**fable-5** (proxy off). Proxy-on is harmless for models that don't emit thinking blocks — it
strips nothing.

## How to add / classify a new model

Two independent axes. Test both before wiring an alias.

**Axis 1 — does the provider accept open-map MCP schemas?** (determines `--enable-mcp`)
Send this minimal repro; HTTP 200 = MCP can be on, 400 = keep MCP off:
```bash
KEY=<openrouter key>
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://openrouter.ai/api/v1/messages \
  -H "Authorization: Bearer $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"<slug>","max_tokens":64,"messages":[{"role":"user","content":"ping"}],
       "tools":[{"name":"t","description":"x","input_schema":{"type":"object",
       "properties":{"pages":{"type":"array","items":{"type":"object","properties":{
       "properties":{"type":"object","propertyNames":{"type":"string"},
       "additionalProperties":{"anyOf":[{"type":"string"},{"type":"number"},{"type":"null"}]}}}}}},
       "required":["pages"]}}]}'
```
Then **confirm with a real end-to-end run** (the repro is one schema; a session sends ~80):
`OPENROUTER_ENABLE_MCP=1 claude-openrouter --model <slug> -p "reply ok"` — a 400 means MCP off.

**Axis 2 — does it emit unsigned thinking blocks?** (determines whether the proxy is needed)
```bash
curl -s -X POST https://openrouter.ai/api/v1/messages -H "Authorization: Bearer $KEY" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"<slug>","max_tokens":200,"messages":[{"role":"user","content":"hi"}]}' \
  | jq '[.content[] | select(.type=="thinking") | .signature==""]'
```
`[true]` → needs the proxy (default). Native Anthropic models return signed sigs → can use
`--no-proxy`. When unsure, leave the proxy on (harmless).

Then create `claude-<name>.sh` (copy an existing alias), add it to the `FILES` list in
`install.sh`, add a README row, `./install.sh`, and test.

## Config / env vars

Wrapper (`claude-openrouter`):
- `OPENROUTER_API_KEY` — else sourced from `OPENROUTER_ENV_FILE` (default `~/.claude/.env.local`, line `OPENROUTER_API_KEY="sk-or-..."`)
- `OPENROUTER_MODEL` (default `x-ai/grok-4.5`), `OPENROUTER_BASE_URL`, `OPENROUTER_API_TIMEOUT_MS`
- `OPENROUTER_NO_PROXY=1` / flag `--no-proxy`; `OPENROUTER_ENABLE_MCP=1` / flag `--enable-mcp`
- Wrapper launches Claude Code with `--dangerously-skip-permissions` (owner preference — remove from the last line if not wanted)

Proxy:
- `OPENROUTER_PROXY_IDLE_TIMEOUT_MS` (default 1200000, per-socket-op)
- `CLOR_DEBUG=<dir>` — dumps `raw_in.sse` / `filtered_out.sse` / `requests.log` for debugging

Statusline: `CLAUDE_USAGE_TTL` (cache seconds, 0 disables usage), `CLAUDE_USAGE_STYLE` (`bars`|`compact`).

## Statusline (statusline/)

A single `statusLine` command runs in **every** Claude Code session, so the script branches:
- **OpenRouter session** (auth token starts `sk-or-` or base URL contains openrouter): runs
  `statusline.ts` → live cost via OpenRouter `/v1/generation` (`xAI: grok-4.5 - $0.07 …`).
  Prefers `bun` (native TS) over `npx tsx`.
- **Subscription session** (normal Claude Code): `model  dir  branch` + **plan usage** —
  5h / 7d / scoped (Fable) quotas as colored progress bars with reset countdowns. Data from
  the unofficial `api.anthropic.com/api/oauth/usage` endpoint; token from macOS Keychain
  (`security find-generic-password -s "Claude Code-credentials"`) or `~/.claude/.credentials.json`
  on Linux. **Cached 60s, refreshed by a detached locked background job** — the render path
  never blocks on the network.

Hardening already in place: scoped quotas (Fable) can vanish → parsing tolerates it; non-numeric
percent / bad reset drop that field only; cache >30 min is suppressed (never show stale numbers);
error bodies never overwrite the cache; `mtime_of()` handles GNU vs BSD `stat` (a real Linux bug
we already hit — GNU `stat -f %m` prints a "File:" block that poisoned arithmetic under `set -u`).

## Deployment

Installed to `~/.local/bin/` on three machines:
- **this Mac** (primary)
- **mini.local** (macOS — reports Darwin) — statusline + settings.json `statusLine` merged
- **hwi.local** (Linux) — statusline + settings.json `statusLine` merged

To redeploy statusline changes: `scp statusline/statusline.sh <host>:~/.claude/hooks/`.
`settings.json` on each already points `statusLine` at `~/.claude/hooks/statusline.sh`
(backups at `settings.json.bak-statusline`). The proxy/wrapper on the remotes are **not** yet
installed there — only the statusline is. If you deploy the launchers to the remotes, run
`./install.sh` there (both have python3/jq/curl; hwi has npx).

## Testing

- Unit: `python3 tests/test_streamfilter.py` (16 cases — thinking-drop + re-index, byte-by-byte
  feed equivalence, CRLF chunk-straddling, multi-line data, ping/comment/`[DONE]`/error passthrough,
  unterminated-final-event flush). Must stay green.
- Syntax: `sh -n *.sh && /bin/dash -n *.sh` (scripts must be dash-compatible — Debian/Ubuntu
  `/bin/sh` is dash; `command -v -a` was a bashism we already fixed).
- E2E: `claude-<model> -p "reply ok"` (headless). For MCP: `OPENROUTER_ENABLE_MCP=1 claude-openrouter --model <slug> -p ...`.
- `py_compile claude-openrouter-proxy.py` before installing.

## Gotchas / hard-won lessons

- **The `is_messages` path check must strip the query string.** OpenRouter requests come as
  `/v1/messages?beta=true`; an `endswith("/v1/messages")` check silently skips filtering and
  you get blank replies again. This bug cost the most time to find.
- **`claude` in a loop consumes stdin** — redirect `</dev/null` when scripting multiple
  headless runs, or later iterations misbehave.
- **`git add -A` swept a `.pyc` into the repo** once (tests compile the proxy). `.gitignore`
  now covers `__pycache__`.
- **Foreground `sleep` is blocked in this harness's Bash tool** — but fine inside the scripts
  themselves at runtime.
- Proxy runs Claude Code **without** `exec` so the cleanup trap fires; a parent-death watchdog
  in the proxy covers SIGKILL (where the trap can't run).

## Prior art / novelty (already in README)

Category (CC + OpenRouter) is crowded: claude-code-router (35k★), y-router (archived),
open-claude-router, LiteLLM, OpenRouter's official env-var integration. The differentiators
here — not found elsewhere as of the 2026-07 survey — are the **strip-and-reindex** thinking
proxy (others inject fake signatures / preserve / disable) and the **schema-aware per-model
MCP gating**. Full comparison table in README "Prior art / how this differs".

## Possible next steps (not started)

- Deploy the launchers (not just statusline) to mini.local / hwi.local via `./install.sh`.
- CI: run `tests/test_streamfilter.py` + `dash -n` on push (GitHub Actions).
- Auto-detect the two axes and pick flags automatically instead of hardcoding per alias.
- Re-test the model matrix periodically — OpenRouter provider routing changes; a model that
  400s today may accept schemas tomorrow (and vice versa).
- The MCP-off tradeoff for grok loses the whole tool set; a request-side schema transform that
  survives OpenRouter's re-normalization would be the real fix (attempted, didn't work — see
  git history around the initial proxy commits).
