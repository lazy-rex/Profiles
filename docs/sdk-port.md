# Port to the Plugin SDK: plan

Status: **proposed** (2026-10-21). Base: LazyRex `origin/hub/sql-contract` at `a2a0ece`
(docs/plugin-sdk.md and docs/sql.md, draft 3). The port starts when the to-do lab passes.

Before: profiles.lua 451 lines, profiles_directories.lua 116, tests 1261 (with the fixture).
Target: the same behavior and the same tests, profiles.lua at about 250 lines.

## What the SDK replaces in profiles.lua

| Code now | Lines | After the port |
|---|---|---|
| `hub()` wrapper and its error-code parse | 8-22 | the SDK's hub call (gap 1). The rule stays: a hub refusal is final |
| `fail`, the error replies, the `pcall` dispatch | 7, 437-450 | `error()` in a handler |
| `handlers`, `client.keymap`, `hub.register`, `client.set_label` | 417-433, 451 | the SDK registration (gap 2) |
| `read_draft`, `ensure_draft`, the `change_draft` if_rev retry loop | 65-116 | SQL in the handler transaction |
| `draft-op/...` operation records | 105, 111 | the SDK's saved replies (operation_key) |
| `start/...` records in `hub.store.op` | 345-373 | a `starts` table, written before `hub.spawn` |
| `expire_drafts` (scan pages, batch delete), `rex.after` at start | 70-83, 436 | one `DELETE FROM drafts WHERE at < ?` |
| `hub.changed` and `hub.ui.invalidate` | 422-425 | a render dependency on workers (gap 4) |
| node/action/item_id dispatch in `view_action` | 375-415 | `on_select` and a form submit handler (gap 3) |
| the `debug.getinfo` and `loadfile` path code | 23-27 | `require` of a sibling file (gap 5) |

These stay: the form tree, `normalize_dir`, `build_request`, the pending, failed and dismiss logic,
and all of profiles_directories.lua (it calls Rex and Git, not the hub).

## Schema (migration 1)

```sql
CREATE TABLE drafts (
  view_id TEXT PRIMARY KEY, at INTEGER NOT NULL,
  dir TEXT, dir_source TEXT, dir_rev INTEGER NOT NULL DEFAULT 0, note TEXT,
  error TEXT, dismissed TEXT, saved_values TEXT,            -- JSON of the submitted values
  pending_key TEXT REFERENCES starts(op_key) ON DELETE SET NULL,
  pending_profile TEXT, pending_spawn_id TEXT);
CREATE TABLE starts (
  op_key TEXT PRIMARY KEY, view_id TEXT NOT NULL, at INTEGER NOT NULL,
  request TEXT NOT NULL, saved_values TEXT);              -- JSON; the exact hub.spawn request
CREATE INDEX drafts_at ON drafts(at);
CREATE INDEX starts_at ON starts(at);
```

The start writes its `starts` row and commits before `hub.spawn`, so a retry sends the same request
(hub.spawn refuses a changed request for a key). Then `hub.spawn` runs outside a transaction: it can
take up to 10 s, more than the handler transaction allows (gap 6).

## One-time import

Drafts live for one day, but a pending start must survive the cutover (an open form keeps Check
again, and Start stays hidden). The import runs once, in migration 2:

1. Scan `hub.store` prefix `draft/`. Insert each draft younger than one day.
2. A start or a directory choice that the hub retries after the cutover has an operation key but
   no SQL row. The handler then reads the legacy record by its known key (`hub.store.op` of
   `start/...` or `draft-op/...`), so no scan of operation records is necessary. The key is
   known at the retry: it is made from the view ID and the operation key.
3. Leave the hub.store records. They expire with no reader. A later commit can delete them.

The import needs hub.store reads through `app.hub` (gap 1). Step 1 runs once, at the first start
after migration 1 (a row in a `meta` table records it).

## Delete

- All the code in the table above.
- The README text about drafts in hub.store.
- No test is deleted. The tests change only where they read hub.store (below).

## Tests that must stay green

All files: contract, start, form, pending, restart, errors, directories. The behavior checks stay
the same. These parts change with the storage:

- `store('draft/...')` and `write({...})` (form 34, 65-69, 112-115, 147-157; start 31; pending 108,
  174-242; restart 40-68) read and write SQL rows instead (gap 8).
- The lost write reply test (pending 171) puts its fault on `hub.sql.commit` instead of
  `hub.store.batch` (gap 8).
- A dismiss of a stale or absent target returns no error and writes nothing now. The SDK gives "an
  item that is gone" a visible error. Either the SDK lets the handler decide, or the test changes
  with the user's approval (gap 3).
- New: the import (a pending draft from hub.store keeps Check again after the cutover).

## SDK gaps (sent to the hub lead and the SDK module pair)

The hub lead answered 1, 5, 6 and 8 (hub.sql handoff, 2026-10-22): `app.hub` keeps the code, the
sibling `require` works, long work uses `tx = false` with `hub.sql.batch`, and the harness gets
`H.sql` and a commit fault. Gap 4: `hub.ui.invalidate` and explicit deps stay. Open with the SDK
module pair: 2, 3, 4 (an SDK wrapper) and 7.

1. A call to a hub action (`hub.profiles`, `hub.spawn`, `hub.workers`, `hub.store.*` for the
   import), with the hub's error code kept.
2. Palette commands that open a form route, not a panel tab.
3. Form views: one view per form instance (`view_id`, `context` with the source pane), `form` nodes
   with field kinds, `rev` and `browse`, a submit handler, `$cancel`, `close_form`, the view
   status, action labels, agent parity (`tool` or `user_only`), and a handler that decides itself
   about a gone item.
4. A render dependency on hub state (workers), not only on tables.
5. `require` of a sibling file of the plugin.
6. A long handler: commit a row, call the hub, then write again, with the operation key's replay.
7. A first render that writes a row, and a migration step that calls the hub.
8. Test harness: SQL reads and writes of the plugin's database, and faults on `hub.sql.*`.
9. Withdrawn: the legacy records are read by their known key (step 2 of the import).
