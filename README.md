# Profiles

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Start Agent… and Start Accessory…: palette commands that open a form, start a profile (an agent or a shell, dev server or log tail) in a directory, and place it as a tab or a split.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "profiles", "path": "/path/to/Profiles/profiles.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

## Agents

Agents start profiles with the hub's own tools, `hub.profiles` and `hub.spawn`; the plugin exports
no actions. The form fills one `hub.spawn` request, so its Start and Check again name that tool.
The directory choices in the form are UI state: an agent sends `cwd` directly.

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
- form.lua: the form's tree, its draft and the Directory field's text.
- pending.lua: pending and failed starts (the hub's spawn-create faults).
- restart.lua: a pending start across a hub stop and a crash.
- errors.lua: a hub refusal ends the operation.
- directories.lua: the directory helper (OSC 7 and Git worktrees).

`tests/support/fixture.lua` is the shared lab fixture: a Git repository and worktree, a source
pane that reports its directory, and harmless profiles. `lazyrex.json` is the test manifest.
