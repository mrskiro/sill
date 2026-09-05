#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

case "$CMD" in
  *git\ push*) ;;
  *) exit 0 ;;
esac

block() {
  jq -n '{
    decision: "block",
    reason: "Direct push to main is not allowed. Create a branch and open a PR."
  }'
  exit 0
}

# Tag-only pushes are fine from anywhere.
case "$CMD" in
  *--tags*|*refs/tags/*) exit 0 ;;
esac

# An explicit refspec whose destination is main/master (e.g. `HEAD:main`, `origin main`).
if printf '%s' "$CMD" | grep -Eq 'git push[^|;&]*([[:space:]]|:)(main|master)([[:space:]]|$)'; then
  block
fi

# No refspec after the remote: the current branch is what gets pushed.
if ! printf '%s' "$CMD" | grep -Eq 'git push([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]-]+[[:space:]]+[^[:space:]-]'; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  case "$BRANCH" in
    main|master) block ;;
  esac
fi
