#!/bin/sh
# claude-kimi — `claude-openrouter --model moonshotai/kimi-k3 --enable-mcp`.
# MCP verified working (full tool set, 2026-07-10); proxy stays on for the
# empty-signature thinking blocks. Extra args forwarded to claude-openrouter.
exec claude-openrouter --model moonshotai/kimi-k3 --enable-mcp "$@"
