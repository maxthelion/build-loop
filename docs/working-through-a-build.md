# Working Through A Build

This is the process reference for the build-loop in a promoted feature
worktree. It is the implementation-side counterpart to
`docs/working-through-a-roadmap.md` (the PM loop).

## When to use the build loop

The build loop runs **inside a promoted worktree** — typically
`<repo>/.worktrees/roadmap-<id>-<slug>` — after the PM loop has
written a coherent `spec.md`, `plan.md`, and `implementation-handoff.md`
and the user has explicitly promoted the feature to build via
`scripts/roadmap/promote-ready-item-to-worktree.sh`.

Do not run the build loop on the main checkout. The main checkout is
where PM work continues and where merges land. Building on a separate
worktree means broken builds, half-done refactors, and reviewer
critiques never destabilise the planning side.

## What the loop does, end to end

1. The deterministic selector (`scripts/build-loop/select-build-action.sh`)
   reads `.claude/state/*` and the current HEAD. It emits one action
   verb into `.claude/state/next-action.md`.

2. The `/build-next-action` skill reads that file, dispatches the
   right subagent (`implementer` for work verbs,
   `adversarial-reviewer` for review), takes the result, commits via
   `commit-build-action.sh`, and exits.

3. Under `/loop`, this repeats until the selector emits
   `signal-ready` — at which point the loop writes
   `.claude/state/ready-for-user.md` and stops.

The user only sees a "ready" signal once **the latest commit has been
adversarially reviewed**. That is the load-bearing invariant: until
`last-review-sha == HEAD`, no ready signal can fire.

## State schema

Everything the loop knows lives in `.claude/state/`:

```
.claude/state/
├── next-action.md               # written by the selector each tick
├── work-item.md                 # the current narrow slice (deleted on completion)
├── partial-work.md              # handoff when a slice spans wakeups
├── last-tests-sha               # last commit at which tests passed
├── last-tests-failure.md        # captured failure when tests fail
├── last-review-sha              # last commit that passed adversarial review
├── inbox/                       # incoming items (status: question | auto)
├── review-queue/                # open critiques from adversarial review
└── ready-for-user.md            # final summary when signal-ready fires
```

State is committed (not gitignored) so the meta hub, the next wakeup,
and a human inspecting the worktree all see the same picture.

## The action verbs

The selector picks one of these per wakeup. The order in which they're
listed below is the priority order — the first whose precondition holds
wins.

### fix-tests

`last-tests-failure.md` exists. The implementer reads it, fixes
narrowly, runs tests, deletes the failure file on success, updates
`last-tests-sha`, commits.

### surface-inbox-question

An inbox item has `status: question`. The loop stops and prints what
decision is needed. No commit. Resolution is by the user editing the
inbox file (or removing it) and the next selector run picking up the
new state.

### handle-inbox

An inbox item has `status: auto`. The implementer performs the action
the file describes and archives or deletes the file.

### address-critique

`review-queue/` has one or more open critiques. The implementer takes
the lexicographically-first critique, applies the minimum fix, runs
tests, and deletes the critique on success. One critique per commit.

### continue-partial-work

`partial-work.md` exists. The implementer either finishes the slice
(deletes the handoff and commits the work) or rewrites the handoff to
describe what still remains.

### execute-work-item

`work-item.md` exists. The implementer implements exactly that slice
plus its tests, runs the full test suite, deletes `work-item.md` on
success, and commits.

### select-work-item

The plan has unticked tasks but no active work-item. The implementer
chooses the next slice, writes `work-item.md` describing it, and
commits only the state change. The next wakeup will pick it up via
`execute-work-item`.

### adversarial-review (mandatory)

`last-review-sha != HEAD`. The reviewer agent reads `git diff
<base>..HEAD`, files concrete critiques into `review-queue/`, and —
only when no critiques are produced — updates `last-review-sha` to
the current HEAD. The reviewer cannot edit production code.

This action will fire repeatedly as new commits land. Until it fires
on a clean diff, `signal-ready` cannot.

### signal-ready

All gates clean and `last-review-sha == HEAD`. The skill writes
`.claude/state/ready-for-user.md` containing a one-paragraph summary
of what changed plus a list of files/commits to review first. The meta
hub surfaces this; the loop stops.

## Loop boundary

What the build loop **does not** do:

- Edit `docs/roadmap/**`. PM artifacts are owned by the planning loop.
- Run promotion. Promotion is an explicit user action via
  `scripts/roadmap/promote-ready-item-to-worktree.sh`.
- Merge or push. Landing the work is a separate user step (typically
  `git merge --squash` from main, or a PR).
- Update wiki pages or specs. If the implementation reveals a missing
  product decision, write into `inbox/` with `status: question` and
  stop.
- Operate on multiple worktrees in one wakeup. Pick one and finish
  one action.

## Mandatory review, in detail

The most-asked question about this loop is "why a mandatory review
gate?" The short version: without it, the build loop will tell the
user a feature is ready while the latest commit hasn't been read by
anything other than the agent that wrote it. Adversarial review with a
fresh context window catches:

- Out-of-scope changes ("the implementer extended the work beyond the
  work-item").
- Trivially-passing tests (`expect(true).toBe(true)`-style).
- Missing tests for spec'd behaviour.
- Public-surface changes without a contract update.
- TODO/console.log/commented-out code left behind.
- Mixed-commit churn that breaks bisection.

These are exactly the things a tired human will miss when they're
glancing at a worktree to "see if it's done." The review gate makes
the loop conservative on the user's behalf.

The reviewer's contract is in `.claude/agents/adversarial-reviewer.md`.

## Surfacing readiness to humans

When `signal-ready` fires, `.claude/state/ready-for-user.md` is the
single canonical signal. It contains:

- One paragraph summary of what was built.
- The merge base SHA and the HEAD SHA (so the user knows the diff
  range).
- The top files to read first, in order.
- Anything the reviewer flagged as `DONE_WITH_NOTES`.

The meta hub's implementation-worktrees panel reads this file. A
worktree without `ready-for-user.md` shows up as "still cooking";
one with the file shows up as "ready for review" along with a button
to run `scripts/open-latest-build.sh`.

## Pairing with `/loop`

For an autonomous build heartbeat:

```
/loop 5m /build-next-action
```

5 minutes is roughly long enough for one selector cycle plus one agent
dispatch on most projects. If your project's tests take longer, use a
longer interval. The selector itself is idempotent and cheap (pure
bash, no LLM), so frequent re-evaluation has no real cost.

For one-off operation:

```
/build-next-action
```

Stops after one action.
