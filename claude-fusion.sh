#!/bin/sh
# claude-fusion — thin alias for `claude-openrouter --model openrouter/fusion`.
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model openrouter/fusion "$@"
