#!/usr/bin/env bash
# Build-loop selector. Reads .claude/state/* and the current git tree, then
# writes .claude/state/next-action.md naming exactly one action.
#
# Selector priority (first match wins):
#   1. tests-failure       -> fix-tests
#   2. inbox/* with status: question      -> stop, surface to user
#   3. inbox/* with status: auto         -> handle-inbox
#   4. review-queue/*      -> address-critique
#   5. partial-work.md     -> continue-partial-work
#   6. work-item.md        -> execute-work-item
#   7. plan with unticked task            -> select-work-item
#   8. last-review-sha != HEAD            -> adversarial-review (mandatory)
#   9. all gates clean, last-review-sha == HEAD -> signal-ready
#
# Mandatory adversarial-review gate (#8) is the key invariant: the user is
# never told a feature is ready until its latest commit has passed review.

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO"

STATE_DIR="$REPO/.claude/state"
mkdir -p "$STATE_DIR/inbox" "$STATE_DIR/review-queue"

OUT="$STATE_DIR/next-action.md"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
HEAD_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

read_file_first_line() {
  local file="$1"
  [ -f "$file" ] || return 1
  head -n 1 "$file" 2>/dev/null
}

frontmatter_value() {
  local file="$1"
  local key="$2"
  local fallback="${3:-}"
  if [ ! -f "$file" ]; then
    printf '%s\n' "$fallback"
    return
  fi
  local value
  value="$(awk -v key="$key" '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && index($0, key ":") == 1 {
      sub("^[^:]+:[[:space:]]*", "")
      print
      exit
    }
  ' "$file")"
  if [ -n "$value" ]; then
    printf '%s\n' "$value" | sed 's/^"//; s/"$//'
  else
    printf '%s\n' "$fallback"
  fi
}

count_files() {
  local dir="$1"
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

first_inbox_with_status() {
  local target_status="$1"
  local dir="$STATE_DIR/inbox"
  [ -d "$dir" ] || return 1
  local file
  while IFS= read -r file; do
    local status
    status="$(frontmatter_value "$file" "status" "auto")"
    if [ "$status" = "$target_status" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null | sort)
  return 1
}

first_review_queue_item() {
  find "$STATE_DIR/review-queue" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null | sort | head -1
}

unticked_task_in_plans() {
  # Find the first unticked task across docs/plans/*.md. Format expected:
  # "- [ ] Task description". Returns "<file>:<line>:<task>" or empty.
  if [ ! -d "docs/plans" ]; then
    return 1
  fi
  grep -nH '^- \[ \] ' docs/plans/*.md 2>/dev/null | head -1
}

last_review_sha=""
if [ -f "$STATE_DIR/last-review-sha" ]; then
  last_review_sha="$(cat "$STATE_DIR/last-review-sha" 2>/dev/null | tr -d '[:space:]')"
fi

action=""
reason=""
hint=""
input=""

# 1. Tests failed last run.
if [ -s "$STATE_DIR/last-tests-failure.md" ]; then
  action="fix-tests"
  reason="last-tests-failure.md exists. A previous test run failed and needs to be fixed before any other work."
  hint="Read .claude/state/last-tests-failure.md for the captured failure. Fix narrowly, rerun the project test command, and delete the failure file on success."
  input="$STATE_DIR/last-tests-failure.md"
fi

# 2. Inbox question item — stop and surface.
if [ -z "$action" ]; then
  q="$(first_inbox_with_status question || true)"
  if [ -n "$q" ]; then
    action="surface-inbox-question"
    reason="An inbox item is marked status: question and needs user input."
    hint="Read $q and reply via the meta hub or a follow-up commit. Do not advance other work until this is resolved."
    input="$q"
  fi
fi

# 3. Auto-handleable inbox item.
if [ -z "$action" ]; then
  a="$(first_inbox_with_status auto || true)"
  if [ -n "$a" ]; then
    action="handle-inbox"
    reason="An inbox item is marked status: auto."
    hint="Read $a, perform the action it describes, and remove or archive the file."
    input="$a"
  fi
fi

# 4. Open critique in review-queue.
if [ -z "$action" ]; then
  c="$(first_review_queue_item || true)"
  if [ -n "$c" ]; then
    action="address-critique"
    reason="A critique is open in review-queue/."
    hint="Read $c, fix the issue narrowly, run the project test command, and delete the critique file on success."
    input="$c"
  fi
fi

# 5. Partial work to continue.
if [ -z "$action" ] && [ -s "$STATE_DIR/partial-work.md" ]; then
  action="continue-partial-work"
  reason="partial-work.md exists from a previous wakeup."
  hint="Resume from .claude/state/partial-work.md. Either finish (and delete the file) or write a fresh handoff."
  input="$STATE_DIR/partial-work.md"
fi

# 6. Active work-item.
if [ -z "$action" ] && [ -s "$STATE_DIR/work-item.md" ]; then
  action="execute-work-item"
  reason="work-item.md is in progress."
  hint="Implement only the work item described in .claude/state/work-item.md. Run the project test command. Delete work-item.md on success and commit."
  input="$STATE_DIR/work-item.md"
fi

# 7. Pick the next plan task as a work-item.
if [ -z "$action" ]; then
  task="$(unticked_task_in_plans || true)"
  if [ -n "$task" ]; then
    action="select-work-item"
    reason="docs/plans/ has an unticked task and no active work-item."
    hint="Write .claude/state/work-item.md naming the next slice from the plan. Keep scope narrow. Commit only the state-file change, then stop."
    input="$task"
  fi
fi

# 8. Mandatory adversarial review before signal-ready.
if [ -z "$action" ]; then
  if [ "$last_review_sha" != "$HEAD_SHA" ] || [ -z "$last_review_sha" ]; then
    action="adversarial-review"
    reason="last-review-sha ($last_review_sha) does not match HEAD ($HEAD_SHA). The latest commit must be reviewed before the user is told the work is ready."
    hint="Diff HEAD against the parent of the build branch. Write critiques into .claude/state/review-queue/. On clean review, write HEAD into .claude/state/last-review-sha and commit."
    input="HEAD=$HEAD_SHORT"
  fi
fi

# 9. All clean and reviewed. Signal ready.
if [ -z "$action" ]; then
  action="signal-ready"
  reason="All gates clean and last-review-sha matches HEAD. Nothing left to do in this loop."
  hint="Write .claude/state/ready-for-user.md with a one-paragraph summary of what changed plus a list of files/commits to review. The meta hub will surface this."
  input=""
fi

{
  echo "# Next Build Action"
  echo
  echo "Generated: $NOW"
  echo "Branch:    $BRANCH"
  echo "HEAD:      $HEAD_SHORT"
  echo
  echo "## Action: $action"
  echo
  echo "$reason"
  echo
  if [ -n "$hint" ]; then
    echo "**How to apply.** $hint"
    echo
  fi
  if [ -n "$input" ]; then
    echo "**Input.** \`$input\`"
    echo
  fi
  echo "## Selector state"
  echo
  echo "- last-tests-failure.md: $([ -s "$STATE_DIR/last-tests-failure.md" ] && echo yes || echo no)"
  echo "- inbox/ files: $(count_files "$STATE_DIR/inbox")"
  echo "- review-queue/ files: $(count_files "$STATE_DIR/review-queue")"
  echo "- partial-work.md: $([ -s "$STATE_DIR/partial-work.md" ] && echo yes || echo no)"
  echo "- work-item.md: $([ -s "$STATE_DIR/work-item.md" ] && echo yes || echo no)"
  echo "- last-review-sha: \`${last_review_sha:-none}\`"
  echo "- HEAD:           \`$HEAD_SHA\`"
  echo "- ready-for-user.md: $([ -s "$STATE_DIR/ready-for-user.md" ] && echo yes || echo no)"
} > "$OUT.tmp.$$"

mv -f "$OUT.tmp.$$" "$OUT"
echo "Wrote $OUT  ($action)"
