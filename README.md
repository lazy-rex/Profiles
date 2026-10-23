# Profiles

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Start Agent… and Start Accessory…: palette commands that open a form, start a profile (an agent or a shell, dev server or log tail) in a directory, and place it as a tab or a split.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "profiles", "path": "/path/to/Profiles/profiles.lua"}
```

The plugin uses the LazyRex Plugin SDK (`"sdk": "0"` in `lazyrex.json`), and it loads its other
files from its own directory, so keep them together. Its data is in its own SQL database (hub.sql):
the table `drafts` (one row for each open form) and the table `starts` (the exact `hub.spawn`
request of each submit). Drafts expire after a day. The hub reads the source pane's directory once,
when it opens the form (LazyRex form context `source_pwd`), so a render only reads.

## Agents

Agents start profiles with the hub's own tools, `hub.profiles` and `hub.spawn`; the plugin exports
no actions. The form fills one `hub.spawn` request, so its Start and Check again name that tool.
The directory choices in the form are UI state: an agent sends `cwd` directly.

## Pending starts

When the outcome of a start is not known, the form shows it as pending, with Check again (the same
`hub.spawn` request and key) and Dismiss pending start. Dismiss forgets the pending start in this
form only. It is UI state, so it has no agent tool. The hub still tracks the spawn, so a pane can
still appear, and a new start can create a duplicate: the form says so before and after.

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them against the real hub, on an
isolated lab Rex server that it starts and stops (LazyRex `docs/testing.md`). No test touches your
own Rex server.

```sh
cd ../LazyRex/hub && go build -o ~/bin/lazyrex-hub ./cmd/hub
cd ../../Profiles && lazyrex-hub test
```

- contract.lua: the plugin client and the agent face.
- start.lua: each start flow as the user (the form) and as an agent (hub.spawn); admission,
  replay, conflicts and stop.
- form.lua: the form's tree, its draft, the Directory field's text, draft expiry and the schema upgrade.
- pending.lua: pending and failed starts (the hub's spawn-create faults), and a lost hub.spawn
  reply that the hub retries with the same key; Dismiss pending start.
- restart.lua: a pending start across a hub stop and a crash.
- startup.lua: the start order in a sandbox (the real SDK, a fake rex): the startup expiry runs
  after the registration, also when the plugin timer runs first; a failed expiry is logged, and
  the plugin start completes.
- errors.lua: a hub refusal ends the operation. A missing directory fails at once: the profile's own
  (form and hub.spawn), a shown directory removed before Start, and `~` text (form).
- directories.lua: the directory helper: the decoder of an OSC 7 report, and Git worktrees.

`tests/support/fixture.lua` is the shared lab fixture: a Git repository and worktree, a source
pane that reports its directory, and harmless profiles. `lazyrex.json` is the test manifest.
