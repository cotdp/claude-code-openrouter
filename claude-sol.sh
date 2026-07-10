#!/bin/sh
# claude-sol — `claude-openrouter --model openai/gpt-5.6-sol --enable-mcp`.
#
# gpt-5.6-sol sits in the middle of the capability matrix (tested 2026-07-10):
#   - its provider ACCEPTS the open-ended-map MCP tool schemas that strict
#     validators (xAI) reject, so MCP servers stay enabled;
#   - but via OpenRouter it still returns thinking blocks with EMPTY signatures,
#     which Claude Code would silently discard — so the stripping proxy stays on.
#
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model openai/gpt-5.6-sol --enable-mcp "$@"
