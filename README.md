# Profiles

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Start Agent… and Start Accessory…: palette commands that open a form, start a profile (an agent or a shell, dev server or log tail) in a directory, and place it as a tab or a split.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "profiles", "path": "/path/to/Profiles/profiles.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

## Tests

The tests use `../LazyRex` (the client library in `lib/` and the lab harness in `lab/`).
Start an isolated lab server first, and never point tests at your own Rex server:

```sh
../LazyRex/lab/server.sh /tmp/rexlab
REX_SERVER=unix:///tmp/rexlab/rex.sock node tests/<name>.mjs
```

- profiles-plugin.mjs (mock hub)
- profiles-lab.mjs, profiles-directories-lab.mjs (lab)
