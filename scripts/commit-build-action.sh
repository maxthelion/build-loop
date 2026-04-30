#!/usr/bin/env bash
# Narrow commit helper for build-loop actions. Stages only the paths declared
# by the current action and refuses to land an empty or out-of-scope commit.
#
# Usage:
#   commit-build-action.sh <action> <message> [<path>...]
#
# Action determines the default scope when no paths are passed:
#   fix-tests, fix-critique, execute-work-item -> repo (caller must pass paths)
#   adversarial-review, select-work-item, handle-inbox -> .claude/state/
#   continue-partial-work -> .claude/state/ + repo (caller passes paths)

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <action> <message> [<path>...]" >&2
  exit 2
fi

ACTION="$1"
MESSAGE="$2"
shift 2

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

if [ "$#" -gt 0 ]; then
  git add -- "$@"
else
  case "$ACTION" in
    adversarial-review|select-work-item|handle-inbox)
      git add .claude/state
      ;;
    *)
      echo "$0: action $ACTION requires explicit paths. Pass them after the message." >&2
      exit 2
      ;;
  esac
fi

if git diff --cached --quiet; then
  echo "$0: nothing staged. No commit created."
  exit 0
fi

git commit -m "$MESSAGE"
