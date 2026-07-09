#!/bin/sh
# claude-fugu — thin alias for `claude-openrouter --model sakana/fugu-ultra`.
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model sakana/fugu-ultra "$@"
