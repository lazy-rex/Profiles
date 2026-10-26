# Profiles

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. It starts your configured profiles from
the palette: an agent, or an accessory such as a dev server, a log tail or a shell. You choose the
directory and the placement (a new tab or a split) in one form.

## Get it

LazyRex setup installs Profiles with the other core plugins. To add it by hand, add an entry to
the `plugins` list of the hub config:

```json
{"source": "/path/to/Profiles"}
```

The source is the plugin directory. The plugin needs LazyRex hub v0.5.0-rc.1 or later (the base
migration step of the Plugin SDK).

## Palette commands

- **LazyRex: Start Agent…** opens a form that starts an agent profile in a directory.
- **LazyRex: Start Accessory…** opens a form that starts a dev server, log tail or shell profile.

The hub owns the profiles. The profiles file is described in the LazyRex hub docs,
[Profiles and workers](https://github.com/lazy-rex/LazyRex/blob/main/docs/hub.md#profiles-and-workers).

## The form

- **Directory.** The form shows the source pane's directory. The hub reads that directory once,
  when it opens the form. An empty field uses the directory that the form showed. Only when the
  form shows no directory does an empty field use each profile's own directory. The app's
  directory browser can fill the field.
- **Directory choices.** When the directory is in a Git repository with more than one worktree, the
  form lists each worktree. **Use each profile's own directory** clears the shown directory, so
  each profile starts in its own directory.
- **Profile.** The profiles of the command's kind.
- **Args.** One field for each arg name that the profiles of this kind declare. An empty field is
  not sent, so the profile's default applies. The hub checks the required args.
- **Tab title (optional).**
- **Placement.** **New tab**, or **Split beside the source pane**. The split goes to the right of
  the source pane. The form offers the split only when it has a source pane.

**Start** sends one `hub.spawn` request.

## Pending starts

When the outcome of a start is not known, the form shows the start as pending:

- **Check again** sends the same `hub.spawn` request with the same key.
- **Dismiss pending start** forgets the pending start in this form only. The form shows it only
  when the hub returned a spawn ID.

Dismiss does not stop the start. The hub still tracks the spawn, so a pane can still appear, and a
new start can make a duplicate. The form says so before and after a dismiss.

## Agents

The plugin has no agent actions. Agents use the hub's own actions, `hub.profiles` and `hub.spawn`.
An agent sends the directory as `cwd`. The directory choices and Dismiss are form state only.

## Settings

The plugin has no plugin args.

## Storage

The plugin keeps its data in its own SQL database (`hub.sql`):

- `drafts`: a row for each form after a directory choice, or after a failed or pending start.
- `starts`: the `hub.spawn` request and the form values of each submit.

The plugin removes rows that are older than one day, at its start and every hour. A start that a
pending form names stays while the draft of that form stays. The draft also expires after one
day, and then the plugin can remove the start. A render of the form writes nothing.

## Limits

- The form reads the source pane's directory only once. A later `cd` in that pane does not change
  the form.
- A dismissed pending start can still open a pane.

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them against the real hub, on an
isolated lab Rex server that it starts and stops (LazyRex
[docs/testing.md](https://github.com/lazy-rex/LazyRex/blob/main/docs/testing.md#run)). No test
touches your own Rex server. Run the tests from the Profiles directory, with `lazyrex-hub` on
`PATH`:

```sh
lazyrex-hub test
```

`lazyrex-hub test` needs a LazyRex checkout: `-lazyrex <dir>`, `LAZYREX_DIR`, or `../LazyRex` beside
the plugin directory.

- contract.lua: the plugin client and the agent face.
- start.lua: each start flow as the user (the form) and as an agent (`hub.spawn`); admission,
  replay, conflicts and stop.
- form.lua: the form's tree, its draft, the Directory field's text, draft expiry, the schema and
  its rows over a restart.
- pending.lua: pending and failed starts (the hub's spawn-create faults), a lost `hub.spawn` reply
  that the hub retries with the same key, and Dismiss pending start.
- restart.lua: a pending start across a hub stop and a crash.
- startup.lua: the start order in a sandbox (the real SDK, a fake rex). The startup expiry runs
  after the registration. A failed expiry is logged, and the plugin start completes. A version-1
  database stops the start.
- errors.lua: a hub refusal ends the operation. A missing directory fails at once.
- directories.lua: the directory helper: the decoder of an OSC 7 report, and Git worktrees.

`tests/support/fixture.lua` is the shared lab fixture: a Git repository and worktree, a source
pane that reports its directory, and harmless profiles. The `test` field of `lazyrex.json`
configures the tests.
