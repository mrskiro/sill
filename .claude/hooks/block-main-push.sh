#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

case "$CMD" in
  *git\ push*) ;;
  *) exit 0 ;;
esac

BRANCH=$(git branch --show-current 2>/dev/null)

case "$BRANCH" in
  main|master)
    jq -n '{
      decision: "block",
      reason: "Direct push to main is not allowed. Create a branch and open a PR."
    }'
    ;;
esac
