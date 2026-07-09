#!/bin/sh
# claude-kimi — thin alias for `claude-openrouter --model moonshotai/kimi-k2.7-code`.
# Any extra args are forwarded to claude-openrouter (hence to claude).
exec claude-openrouter --model moonshotai/kimi-k2.7-code "$@"
