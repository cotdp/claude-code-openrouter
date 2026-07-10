#!/bin/sh
# claude-fusion — `claude-openrouter --model openrouter/fusion --enable-mcp`.
# MCP verified working (full tool set, 2026-07-10); proxy stays on for the
# empty-signature thinking blocks. Extra args forwarded to claude-openrouter.
exec claude-openrouter --model openrouter/fusion --enable-mcp "$@"
