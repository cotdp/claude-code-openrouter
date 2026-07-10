#!/bin/sh
# claude-sol-pro — `claude-openrouter --model openai/gpt-5.6-sol-pro --enable-mcp`.
#
# Same capability quadrant as gpt-5.6-sol (tested 2026-07-10): the provider
# accepts open-ended-map MCP tool schemas (MCP stays enabled), but via
# OpenRouter it returns thinking blocks with EMPTY signatures — so the
# stripping proxy stays on.
#
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model openai/gpt-5.6-sol-pro --enable-mcp "$@"
