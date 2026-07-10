#!/bin/sh
# claude-fable-5 — `claude-openrouter --model anthropic/claude-fable-5 --no-proxy --enable-mcp`.
#
# A native Anthropic model served through OpenRouter's Anthropic skin behaves
# exactly like the first-party API: properly signed thinking blocks and tool
# schemas Claude Code's clients accept. So it needs neither workaround — the
# thinking-block proxy is bypassed and MCP servers stay enabled.
#
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model anthropic/claude-fable-5 --no-proxy --enable-mcp "$@"
