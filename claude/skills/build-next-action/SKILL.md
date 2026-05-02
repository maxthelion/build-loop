---
name: build-next-action
description: Run one iteration of the build behaviour-tree loop in a promoted feature worktree. Refreshes the deterministic selector, dispatches one action via build-implementer or build-adversarial-reviewer subagents, and exits. Pair with /loop for an autonomous build heartbeat.
---

# Build Next Action

## The split

This is the build-side counterpart of `/pm-next-action`. Selector and
executor are deliberately separated so only the expensive part uses an LLM.

1. **`scripts/build-loop/select-build-action.sh`** — pure bash.
   Reads `.claude/state/*` and the current git tree. Picks one action
   from a fixed priority order (see below). Writes
   `.claude/state/next-action.md`.

2. **This skill (`/build-next-action`)** — LLM. Reads `next-action.md`,
   dispatches the right sub-agent, commits via
   `commit-build-action.sh`, and exits. Does not chain.

Under `/loop`, the pattern is:

```
loop iteration:
  → select-build-action.sh writes next-action.md
  → /build-next-action reads it, dispatches, commits, exits
next iteration:
  → select-build-action.sh re-evaluates against new state
```

## Selector priority

The selector emits one of these actions, in order. **Adversarial review
is a gate, not just a verb**: nothing reaches `signal-ready` until
`last-review-sha == HEAD`.

| Priority | Trigger | Action verb |
|---|---|---|
| 1 | `last-tests-failure.md` exists | `fix-tests` |
| 2 | `inbox/*.md` with `status: question` | `surface-inbox-question` (stop) |
| 3 | `inbox/*.md` with `status: auto` | `handle-inbox` |
| 4 | `review-queue/*.md` exists | `address-critique` |
| 5 | `partial-work.md` exists | `continue-partial-work` |
| 6 | `work-item.md` exists | `execute-work-item` |
| 7 | `docs/plans/*.md` has unticked task | `select-work-item` |
| 8 | `last-review-sha != HEAD` | `adversarial-review` (mandatory) |
| 9 | All clean and `last-review-sha == HEAD` | `signal-ready` |

## What this skill does

1. **Refresh the selector.** Run
   `scripts/build-loop/select-build-action.sh`. It rewrites
   `.claude/state/next-action.md` against current state.

2. **Read `.claude/state/next-action.md`.** Capture the action verb,
   reason, hint, and input.

3. **Decide whether to act.**
   - `surface-inbox-question` → stop. Print the inbox file path and
     what decision is needed. Do not commit.
   - `signal-ready` → write a one-paragraph summary plus a list of
     commits/files to review into `.claude/state/ready-for-user.md`.
     Commit only the state-file change. Stop.
   - Anything else → continue to step 4.

4. **Dispatch the right agent.** Use the `Agent` tool with one of the
   following `subagent_type` values:

   | Action | Agent |
   |---|---|
   | `fix-tests`, `address-critique`, `continue-partial-work`, `execute-work-item`, `handle-inbox`, `select-work-item` | `build-implementer` |
   | `adversarial-review` | `build-adversarial-reviewer` |

   The brief must be self-contained: include the action verb, reason,
   hint, and input from `next-action.md`. Tell the agent to follow its
   own contract in `.claude/agents/<role>.md` and return a tight report
   (`DONE` / `BLOCKED` / `DONE_WITH_NOTES` plus changed paths).

5. **Apply the result.**
   - If the agent reports `DONE` and changed files,
     run `scripts/build-loop/commit-build-action.sh <action> "<message>" [<path>...]`.
   - For `adversarial-review`: when the review is clean (no new files
     in `review-queue/`), update `.claude/state/last-review-sha` to
     HEAD and commit. When it produced critiques, do **not** update
     `last-review-sha`; the next selector run will route to
     `address-critique`.
   - If the agent reports `BLOCKED`, it should have written into
     `.claude/state/inbox/` with `status: question`. The next
     selector run will surface it.

6. **Refresh the selector** so the post-action state is reflected.
   Print the new next action.

7. **Exit.** Do not chain into a second action. The next loop
   iteration evaluates from scratch.

## Loop boundary — do not cross

- **Operate only in promoted feature worktrees** (`.worktrees/roadmap-*`
  for in-sequence-style projects, or any feature-scoped checkout).
  Not the main checkout.
- **No PM artifact writes.** `docs/roadmap/**` is owned by the PM loop.
  The build loop reads architecture/spec/plan/handoff but does not
  modify them. If implementation reveals a missing product decision,
  write into `inbox/` with `status: question` and stop.
- **No branch operations beyond commit.** No rebase, force-push,
  branch creation/deletion, or worktree management. Promotion lives in
  pm-loop's `promote-ready-item-to-worktree.sh`.
- **One commit per action.** Use `commit-build-action.sh` so the diff
  stays narrow. No mixed commits.

## Safety rails

- **One action per invocation.** No chaining. Next loop iteration
  picks the next item.
- **`last-review-sha` cannot be set without a clean review.** The
  build-adversarial-reviewer agent is the only thing that updates it.
- **Surface, don't improvise.** When the agent's contract doesn't
  cover a situation, write into `inbox/` with `status: question` and
  stop.

## Final report format

End the response with two short blocks:

```
Build action: <verb> — <DONE|BLOCKED|DONE_WITH_NOTES|skipped>
<one-line description of what was written or why nothing ran>

Next: <whatever select-build-action.sh now reports>
```

Keep it tight. The diff is the source of truth.

## Related

- `scripts/build-loop/select-build-action.sh` — selector
- `scripts/build-loop/commit-build-action.sh` — narrow commit helper
- `scripts/build-loop/check-ready.sh` — yes/no signal for the meta hub
- `.claude/agents/build-implementer.md` — code-writing sub-agent
- `.claude/agents/build-adversarial-reviewer.md` — review sub-agent
- `/pm-next-action` — the planning-loop counterpart
