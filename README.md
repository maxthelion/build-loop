# build-loop

A reusable build-side behaviour-tree bundle for codebases that promote
PM-loop features into separate implementation worktrees. Sits between
`pm-loop` (planning) and `shoe-makers` (overnight maintenance).

## What it gives you

- A **deterministic selector**
  (`scripts/build-loop/select-build-action.sh`) that picks one action
  per wakeup from a fixed priority order.
- A **`build-next-action` skill** that reads the selector output,
  dispatches the right sub-agent, and exits.
- Two sub-agents — **`implementer`** (writes code) and
  **`adversarial-reviewer`** (reads diffs).
- A **mandatory adversarial-review gate**: nothing reaches
  `signal-ready` until `last-review-sha == HEAD`. The user is never
  told a feature is ready while the latest commit has only been seen
  by the agent that wrote it.
- A **`signal-ready` action** that writes
  `.claude/state/ready-for-user.md` summarising what changed and
  where to look. The meta hub surfaces this.
- A **`check-ready.sh` helper** for CI / dashboard yes-no checks.

## Goals

- **Mandatory review before user attention.** This is the load-bearing
  invariant. Other build loops have adversarial review as a verb that
  may or may not run; here it is a gate that gates the ready signal.
- **One action per wakeup, narrow commits.** No chaining. The selector
  re-evaluates from scratch every tick.
- **State on disk, not in chat.** `.claude/state/` is committed. The
  meta hub, the next wakeup, and a human inspecting the worktree all
  see the same thing.
- **Loop boundary.** The build loop does not edit roadmap PM
  artifacts, run promotion, merge, or push. Those are user actions in
  the main checkout.

## Selector priority

| Priority | Trigger | Action |
|---|---|---|
| 1 | `last-tests-failure.md` | `fix-tests` |
| 2 | inbox `status: question` | `surface-inbox-question` (stop) |
| 3 | inbox `status: auto` | `handle-inbox` |
| 4 | `review-queue/*` | `address-critique` |
| 5 | `partial-work.md` | `continue-partial-work` |
| 6 | `work-item.md` | `execute-work-item` |
| 7 | unticked plan task | `select-work-item` |
| 8 | `last-review-sha != HEAD` | `adversarial-review` (mandatory) |
| 9 | All clean, `last-review-sha == HEAD` | `signal-ready` |

## Install

```sh
# from ~/dev/meta:
bun run bundle -- install --kind build-loop /path/to/worktree
```

Or any consumer of the manifest format. See
[maxthelion/meta](https://github.com/maxthelion/meta) for the
installer + dashboard.

## Use

After install, in the worktree:

```sh
scripts/build-loop/select-build-action.sh   # write next-action.md
/loop 5m /build-next-action                 # autonomous heartbeat (Claude Code)
```

For one-off:

```sh
/build-next-action
```

For a yes/no readiness check (useful for the dashboard):

```sh
scripts/build-loop/check-ready.sh
```

Exits 0 if all gates clean and HEAD has been reviewed.

## Layout in a consuming project

```
<worktree>/
├── scripts/build-loop/
│   ├── select-build-action.sh
│   ├── check-ready.sh
│   └── commit-build-action.sh
├── .claude/agents/{implementer,adversarial-reviewer}.md
├── .claude/skills/build-next-action/SKILL.md
├── .claude/state/                          # owned by the loop
│   ├── next-action.md
│   ├── work-item.md (when active)
│   ├── partial-work.md (when active)
│   ├── last-tests-sha
│   ├── last-tests-failure.md (when active)
│   ├── last-review-sha
│   ├── inbox/
│   ├── review-queue/
│   └── ready-for-user.md (when signal-ready fires)
├── docs/working-through-a-build.md
└── .build-loop.lock                         # written by the bundle CLI
```

## Status

v0.1 — extracted as a fresh template, not from any single project.
The selector and contracts have been designed but not yet
battle-tested across multiple consumers; expect refinements as the
first projects adopt it. Designed for compatibility with `pm-loop`
(consumes `docs/plans/*.md` and `docs/roadmap/<feature>/spec.md` from
the main checkout's PM work) and the meta hub's implementation-worktrees
panel.

## Repos

- This bundle: [maxthelion/build-loop](https://github.com/maxthelion/build-loop)
- Hub + installer: [maxthelion/meta](https://github.com/maxthelion/meta)
- Sibling planning bundle: [maxthelion/pm-loop](https://github.com/maxthelion/pm-loop)
