#!/bin/sh
# claude-glm — thin alias for `claude-openrouter --model z-ai/glm-5.2`.
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model z-ai/glm-5.2 "$@"
