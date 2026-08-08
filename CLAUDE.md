# CLAUDE.md — Snap2Ink

## Worktree sessions

Work often happens in a `worktree-bridge-cse_*` branch/worktree under `.claude/worktrees/`, isolated
from `main`. That isolation is temporary, not a parking spot: once a session's work is done and
tested, cherry-pick (or merge) its commits into `main` before considering the task finished — don't
leave fixes sitting on a bridge branch that another session, or `main` itself, never sees. Two bridge
sessions have already shipped the same bug fix independently because neither knew the other's commits
existed; that's what this policy is for.

Before merging, check `git worktree list` and diff each bridge branch against `main` — there may be
other sessions' work also waiting to land, not just your own.

A `SessionStart` hook (`.claude/hooks/prune-worktree-bridges.sh`) prunes bridge worktrees/branches
once their commits are confirmed present in `main` (by patch-id, commit-message match, or reverse-diff
apply), and flags (once, via a desktop notification) any bridge branch that never landed — that
notification means a session's work needs to be reviewed and merged or explicitly discarded, not
ignored.

## Git guardrails

A `pre-push` hook lives at `.githooks/pre-push` (tracked). Snap2Ink is TestFlight-only by choice and
has no remote, so its allowlist is deliberately **empty** — the hook refuses every push outright,
with a message pointing at where to add a URL if a backup remote is ever intentionally introduced.
It also refuses any `refs/heads/worktree-*` ref, same as the bridge-worktree policy above. This
exists because of the 2026-08-03 incident: private SpokenFeeds history got pushed to the public
`xteink-companion-ble` firmware remote after an agent inside that repo's firmware submodule checkout
reconfigured the superproject's origin. Snap2Ink no longer carries that submodule (it depends on the
versioned `CompanionKit` Swift package instead, see the README's "Firmware dependency" section), but
keeps the matching guard regardless — it costs nothing and the incident class it guards against
(an agent pushing this repo's history somewhere it shouldn't) is not specific to submodules.

**One-time setup per clone** (the hook is tracked but git does not use `.githooks` by default):
```bash
git config core.hooksPath .githooks
```

Deliberate bypass: `ALLOW_PUSH_ANYWAY=1 git push ...`

## Deploying

`./deploy-testflight.sh` builds and uploads the Release scheme to TestFlight — see `docs/testflight.md`.
Always deploy from `main`, after the relevant work has landed there, not from a bridge worktree.

Always push to TestFlight after making a commit, unless told otherwise — don't wait to be asked each
time. The orientation work in particular depends on fast on-device round-trips, so a commit that isn't
followed by a deploy is a confirmation cycle stalled for no reason.

## CompanionKit development

The dependency in `project.yml` is the versioned [`CompanionKit`](https://github.com/DarkStarDS9/CompanionKit)
package (major version = protocol version), not a path into the firmware submodule. To work on the
kit itself alongside Snap2Ink: drag a local CompanionKit checkout into the Xcode workspace — Xcode
shadows the remote package reference with the local one automatically, no project file changes
needed. Release flow: bump the kit, tag it (major = protocol version), then bump the pin here
(`project.yml`'s `from:` version, followed by `xcodegen` and a fresh dependency resolution, which
updates `Package.resolved`).
