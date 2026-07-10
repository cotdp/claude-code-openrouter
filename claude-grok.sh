#!/bin/sh
# claude-grok — `claude-openrouter --model x-ai/grok-4.5`.
# MCP stays OFF: xAI's strict function-calling validator rejects the open-ended
# -map tool schemas several MCP servers use (one bad tool 400s the whole
# request). grok is the only model in this repo with that limitation.
# Extra args forwarded to claude-openrouter.
exec claude-openrouter --model x-ai/grok-4.5 "$@"
