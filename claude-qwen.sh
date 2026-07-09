#!/bin/sh
# claude-qwen — thin alias for `claude-openrouter --model qwen/qwen3.7-plus`.
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model qwen/qwen3.7-plus "$@"
