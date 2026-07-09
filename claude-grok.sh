#!/bin/sh
# claude-grok — thin alias for `claude-openrouter --model x-ai/grok-4.5`.
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model x-ai/grok-4.5 "$@"
