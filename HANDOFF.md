# Handoff: Profiles (plugin port team)

Date: 2026-10-19. Written by the implementer (Claude) of the Profiles plugin team.

## State

- The work is complete. The reviewer (Codex) approved every commit.
- `main` on origin is `4b67eb0`: Lua tests on the real hub, agent parity, Node tests removed.
- The live hub runs Profiles `4b67eb0` from its release clone. A push to `main` does not deploy.
  A release needs the user's approval, through the coordinator.
- Branch `harness` is `main` plus this file only. No other unpushed commits or branches exist.

## What the plugin does for agents

- The plugin exports no actions. Agents use the hub's own `hub.profiles` and `hub.spawn`.
- The palette commands, the form's Start and Check again name `tool = 'hub.spawn'`.
- The directory choices (worktree, profile default) are `user_only = 'draft is UI state'`: an
  agent sends `cwd` directly.

## Tests

Run in this repository: `lazyrex-hub test` (build the hub in LazyRex `hub/`; see README).
Last full run: LazyRex main `c9b3e0d`, parity 4 and all 7 files pass (contract 3, directories 9,
errors 2, form 11, pending 5, restart 4, start 8). The coverage map of the removed Node tests is
in the message of commit `4b67eb0`.

## Decisions that the tests follow

- Agents may stop any worker, also one that another agent or the user started (LazyRex
  `docs/decisions.md`, 7cf0851). `start.lua` checks it; the hub change is LazyRex 9bc00c8.
- A form `tool` may name a hub tool on the agent face (LazyRex parity checker).

## Known limits (accepted by the reviewer)

- The UI branch "pending, then failed, values come back" is unreachable on the real hub: a
  pending spawn fails only when its session is gone, and that closes the form (source-verified).
  The code stays as defense.
- The replay test proves recovery from an existing saved start request. It does not prove a
  concurrent `op_exists` race: no reachable competing writer is known.
- `ensure_draft` has two freeze guards; a mutation of only one of them passes the tests.

## Open items outside Profiles

None known for this repository. Ask the coordinator about LazyRex harness items.

## Next step

None required. A new task for Profiles starts from `main`.
