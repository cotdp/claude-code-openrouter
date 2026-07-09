#!/bin/sh
# claude-fable-5 — `claude-openrouter --model anthropic/claude-fable-5`.
#
# This is a native Anthropic model served through OpenRouter's Anthropic skin, so
# it behaves exactly like the first-party API: properly signed thinking blocks and
# tool schemas Claude Code's clients accept. That means it does NOT need the
# thinking-block-stripping proxy and it CAN use MCP servers — so we bypass the
# proxy and re-enable MCP for full-feature parity.
#
# Any extra args are forwarded to claude-openrouter (hence to claude).
OPENROUTER_NO_PROXY=1 \
OPENROUTER_ENABLE_MCP=1 \
exec claude-openrouter --model anthropic/claude-fable-5 "$@"
