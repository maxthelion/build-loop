#!/usr/bin/env bash
# Check-ready: report whether all gates are clean and HEAD has been reviewed.
# Exits 0 if ready (signal-ready is the next action). Exits 1 otherwise.
# Useful for CI hooks, the meta hub, and humans who just want a quick yes/no.

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO"

STATE_DIR="$REPO/.claude/state"
issues=()

check() {
  local label="$1"
  local cond="$2"
  if eval "$cond"; then
    issues+=("$label")
  fi
}

check "tests-failure file present"     '[ -s "$STATE_DIR/last-tests-failure.md" ]'
check "open inbox items"               '[ "$(find "$STATE_DIR/inbox" -maxdepth 1 -type f -name "*.md" ! -name "README.md" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
check "open review-queue items"        '[ "$(find "$STATE_DIR/review-queue" -maxdepth 1 -type f -name "*.md" ! -name "README.md" 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'
check "partial-work outstanding"       '[ -s "$STATE_DIR/partial-work.md" ]'
check "work-item in progress"          '[ -s "$STATE_DIR/work-item.md" ]'

# Mandatory: last-review-sha == HEAD
HEAD_SHA="$(git rev-parse HEAD)"
last_review_sha=""
[ -f "$STATE_DIR/last-review-sha" ] && last_review_sha="$(cat "$STATE_DIR/last-review-sha" | tr -d '[:space:]')"
if [ "$last_review_sha" != "$HEAD_SHA" ]; then
  issues+=("last-review-sha (\`${last_review_sha:-none}\`) != HEAD (\`$HEAD_SHA\`)")
fi

# Untcked plan tasks
if [ -d "docs/plans" ]; then
  unticked=$(grep -l '^- \[ \] ' docs/plans/*.md 2>/dev/null | wc -l | tr -d ' ')
  [ "$unticked" -gt 0 ] && issues+=("$unticked plan file(s) have unticked tasks")
fi

if [ "${#issues[@]}" -eq 0 ]; then
  echo "READY: all gates clean, HEAD reviewed."
  exit 0
fi

echo "NOT READY:"
for i in "${issues[@]}"; do
  echo "  - $i"
done
exit 1
