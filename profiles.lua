-- Start Agent… and Start Accessory…: palette commands that open a form in the side slot. The form
-- starts a profile with hub.spawn in a chosen directory, in a new tab or in a split beside the
-- source pane. The hub owns profiles, spawns and placement; Rex and Git own directories
-- (profiles_directories.lua). This plugin owns only the form, its draft and its saved starts.
-- The LazyRex Plugin SDK (docs/plugin-sdk.md) does the registration, the hub calls and the storage.
local app = require('lazyrex').plugin('profiles')
local dirs = require('profiles_directories')
local db, fail = app.db, app.fail

local kinds = {['/forms/start-agent'] = 'agent', ['/forms/start-accessory'] = 'accessory'}
local draft_ttl = 24 * 3600 -- a draft whose form never ended expires after a day

-- A draft holds the form's directory choice for one form view. dir = NULL means each profile's own
-- directory. dir_rev counts the explicit directory choices (see choose_dir). saved_values holds the
-- submitted values of a failed or pending start (JSON). A start holds the exact hub.spawn request
-- of one submit (JSON), saved before hub.spawn.
local schema = {
  'CREATE TABLE starts (op_key TEXT PRIMARY KEY, view_id TEXT NOT NULL, at INTEGER NOT NULL, request TEXT NOT NULL, saved_values TEXT)',
  'CREATE TABLE drafts (view_id TEXT PRIMARY KEY, at INTEGER NOT NULL, dir TEXT, dir_source TEXT, dir_rev INTEGER NOT NULL DEFAULT 0, ' ..
    'error TEXT, dismissed TEXT, saved_values TEXT, pending_key TEXT, pending_profile TEXT, pending_spawn_id TEXT)',
  'CREATE INDEX drafts_at ON drafts (at)',
  'CREATE INDEX starts_at ON starts (at)',
}

-- Agent parity: each user action names its agent tool or a user_only reason. Agents start a
-- profile with the hub's own hub.spawn; the form only fills one hub.spawn request.
local function action(name, label, parity)
  local a = {name = name, label = label, enabled = true}
  for k, v in pairs(parity or {}) do a[k] = v end
  return a
end
local spawn_tool = {tool = 'hub.spawn'}
local ui_state = {user_only = 'draft is UI state'}
local dismiss_warning = 'Dismiss this pending start? A pane may still appear. Starting again can create a duplicate.'
local function part(value) return tostring(#value) .. ':' .. value end
local function context_of(args)
  local context = args.context
  if type(context) ~= 'table' or type(context.session_id) ~= 'string' or context.session_id == '' then
    fail('invalid_input', 'The form has no source session')
  end
  return context
end
local function view_id(args)
  if type(args.view_id) ~= 'string' or args.view_id == '' then fail('invalid_input', 'The hub sent no view_id') end
  return args.view_id
end
local function profiles_of(kind)
  local list = {}
  for _, profile in ipairs(app.hub('hub.profiles').profiles or {}) do
    if profile.kind == kind then list[#list + 1] = profile end
  end
  return list
end
local function json(text) return text and rex.json.decode(text) or nil end

local function read_draft(id)
  local d = db.first('SELECT * FROM drafts WHERE view_id = ?', id)
  if not d then return nil end
  d.values = json(d.saved_values)
  if d.pending_key then d.pending = {op_key = d.pending_key, profile = d.pending_profile, spawn_id = d.pending_spawn_id} end
  return d
end
-- A start's own row stays while a pending draft names it.
local function expire_drafts()
  local old = os.time() - draft_ttl
  db.exec('DELETE FROM drafts WHERE at < ?', old)
  db.exec('DELETE FROM starts WHERE at < ? AND op_key NOT IN (SELECT pending_key FROM drafts WHERE pending_key IS NOT NULL)', old)
end

-- The one-time import from hub.store (before the move to SQL). First every saved start request
-- (hub.store.ops_scan): a retry of its operation key must send that exact request, also when no
-- draft names it yet (a stop between the save and hub.spawn). Then the drafts younger than a day; a
-- pending draft keeps its start, so the form still offers Check again. The saved replies of
-- directory choices are not imported: a retried choice runs again and changes nothing more.
local function import_old()
  local now, after = os.time(), nil
  repeat
    local page = app.hub('hub.store.ops_scan', {after = after, limit = 100})
    for _, op in ipairs(page.ops or {}) do
      local n, rest = tostring(op.key):match('^start/(%d+):(.*)$')
      local start = type(op.result) == 'table' and op.result
      if n and start and type(start.request) == 'table' then
        db.exec('INSERT INTO starts (op_key, view_id, at, request, saved_values) VALUES (?, ?, ?, ?, ?)', op.key, rest:sub(1, tonumber(n)), now,
          rex.json.encode(start.request), type(start.values) == 'table' and rex.json.encode(start.values) or nil)
      end
    end
    after = page.next
  until type(after) ~= 'string' or after == ''
  after = nil
  repeat
    local page = app.hub('hub.store.scan', {prefix = 'draft/', after = after, limit = 100})
    for key, record in pairs(page.records or {}) do
      local d = type(record) == 'table' and record.value
      if type(d) == 'table' and type(d.at) == 'number' and d.at >= now - draft_ttl then
        local p = type(d.pending) == 'table' and type(d.pending.op_key) == 'string' and d.pending or nil
        if p and not db.first('SELECT op_key FROM starts WHERE op_key = ?', p.op_key) then p = nil end
        db.exec('INSERT INTO drafts (view_id, at, dir, dir_source, dir_rev, error, dismissed, saved_values, pending_key, pending_profile, pending_spawn_id) ' ..
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', key:sub(7), d.at, d.dir, d.dir_source, tonumber(d.dir_rev) or 0, d.error,
          d.dismissed, type(d.values) == 'table' and rex.json.encode(d.values) or nil, p and p.op_key, p and tostring(p.profile), p and p.spawn_id)
      end
    end
    after = page.next
  until type(after) ~= 'string' or after == ''
end
schema[#schema + 1] = import_old
app.db.migrate {function() for _, step in ipairs(schema) do if type(step) == 'function' then step() else db.exec(step) end end end}

-- form_dir answers the directory that the form shows. The hub reads the source pane's directory
-- once, when it opens the form, and each render and action gets that report (ctx.source.pwd, or
-- ctx.source.pwd_error; LazyRex docs/hub.md). So the form keeps the directory that it first showed,
-- also when the source pane changes directory later. An explicit choice or an imported draft wins.
local function form_dir(ctx, draft)
  if draft and ((draft.dir_rev or 0) > 0 or draft.dir_source) then return draft.dir, draft.dir_source end
  local path = dirs.pwd_path(ctx.source and ctx.source.pwd)
  return path, path and 'pwd' or nil
end

-- The draft holds a raw path; the Directory field holds editor text, which normalize_dir decodes.
-- For an absolute path only the backslash is special, so escaping it makes the round trip exact.
local function dir_text(dir) return dir and (dir:gsub('\\', '\\\\')) or '' end

-- An explicit directory choice (a worktree or the profile default) must reach the Directory field,
-- also when the user edited it. The choice increments dir_rev, the field's rev: a changed rev makes
-- the renderer replace the editor text. The choice also replaces the directory in the values saved
-- by a failed start, and keeps the other saved values.
local function choose_dir(args, dir, source)
  db.exec('INSERT INTO drafts (view_id, at, dir, dir_source, dir_rev) VALUES (?, ?, ?, ?, 1) ON CONFLICT (view_id) DO UPDATE SET ' ..
    "at = excluded.at, dir = excluded.dir, dir_source = excluded.dir_source, dir_rev = dir_rev + 1, saved_values = json_set(saved_values, '$.dir', ?)",
    view_id(args), os.time(), dir, source, dir_text(dir))
  return {}
end

local function directory_nodes(dir, note, nodes)
  if note then nodes[#nodes + 1] = {id = 'directory_note', type = 'widget', text = note} end
  local items = {}
  if dir then
    local ok, trees = pcall(dirs.worktrees, dir)
    if ok and trees and #trees.list > 1 then
      for _, tree in ipairs(trees.list) do
        local name = tree.branch or (tree.detached and 'detached' or '?')
        local mark = tree.path == trees.current and ' (current)' or ''
        items[#items + 1] = {id = 'tree:' .. tree.path, label = 'Worktree ' .. name .. mark, detail = tree.path, action = action('choose', 'Choose', ui_state)}
      end
    end
    items[#items + 1] = {id = 'default', label = "Use each profile's own directory", action = action('default', 'Use', ui_state)}
  end
  if #items > 0 then nodes[#nodes + 1] = {id = 'dir_choices', type = 'list', label = 'Directory', items = items} end
end

local function render_start(ctx, args)
  local kind = kinds[args.route]
  local context = context_of(args)
  local draft = read_draft(view_id(args)) or {}
  local dir, dir_source = form_dir(ctx, draft)
  local title = kind == 'agent' and 'Start Agent' or 'Start Accessory'
  local nodes = {}
  if draft.pending then
    -- The start's outcome is not known. This comes before the profiles load: Check again needs only
    -- the saved request, also when the profiles file broke or lost the profile since. Start stays
    -- hidden: a new key could start a second copy.
    local detail = ''
    local listed, workers = pcall(app.hub, 'hub.workers')
    for _, worker in ipairs(listed and workers.workers or {}) do
      if worker.spawn_id == draft.pending.spawn_id and type(worker.error) == 'string' then detail = ' (' .. worker.error .. ')' end
    end
    nodes[#nodes + 1] = {id = 'pending', type = 'widget', text = 'Starting ' .. tostring(draft.pending.profile) ..
      '… The outcome is not known yet' .. detail .. '. LazyRex will not start it twice.'}
    nodes[#nodes + 1] = {id = 'pending_actions', type = 'list', items = {{id = 'check', label = 'Check again', action = action('check', 'Check', spawn_tool)}}}
    -- Dismiss forgets the pending start in this form only. The hub still tracks the spawn, so the
    -- warning comes first, in full (a row label can be cut off).
    if type(draft.pending.spawn_id) == 'string' and draft.pending.spawn_id ~= '' then
      nodes[#nodes + 1] = {id = 'dismiss_warning', type = 'widget', text = dismiss_warning}
      nodes[#nodes + 1] = {id = 'dismiss_actions', type = 'list', items = {{id = 'dismiss:' .. draft.pending.spawn_id,
        label = 'Dismiss pending start', action = action('dismiss', 'Dismiss pending start', ui_state)}}}
    end
    nodes[#nodes + 1] = {id = 'cancel', type = 'widget', text = '', action = action('$cancel', 'Cancel')}
    return {title = title, nodes = nodes, status = {state = 'working', msg = 'Starting'}}
  end
  -- A broken profiles file is shown, not retried: the hub retries a render that fails as unavailable.
  local loaded, profiles = pcall(profiles_of, kind)
  if not loaded then
    local reason = type(profiles) == 'table' and profiles.message or tostring(profiles)
    nodes[#nodes + 1] = {id = 'profiles_error', type = 'widget', text = 'Profiles could not be loaded: ' .. (reason or 'Unknown error')}
    nodes[#nodes + 1] = {id = 'cancel', type = 'widget', text = '', action = action('$cancel', 'Cancel')}
    return {title = title, nodes = nodes}
  end
  if #profiles == 0 then
    nodes[#nodes + 1] = {id = 'no_profiles', type = 'widget', text = 'No ' .. kind .. ' profiles are configured.'}
    nodes[#nodes + 1] = {id = 'cancel', type = 'widget', text = '', action = action('$cancel', 'Cancel')}
    return {title = title, nodes = nodes}
  end
  if draft.error then nodes[#nodes + 1] = {id = 'start_error', type = 'widget', text = 'The last start failed: ' .. draft.error} end
  if draft.dismissed then
    nodes[#nodes + 1] = {id = 'dismissed', type = 'widget', text = 'You dismissed the pending start of ' .. tostring(draft.dismissed) ..
      '. Dismiss does not stop or remove the worker. A pane may still appear. ' ..
      'Starting again can create a duplicate.'}
  end
  directory_nodes(dir, ctx.source and ctx.source.pwd_error, nodes)
  local options, fields, seen, order = {}, {}, {}, {}
  -- After a failed pending start, the fields show the values that the user submitted.
  local saved = type(draft.values) == 'table' and draft.values or {}
  local function kept(id, default) return type(saved[id]) == 'string' and saved[id] or default end
  -- Directory: a text field. browse = "native": the renderer offers the app's directory browser,
  -- which types the chosen path into the field (pane.insert_path). When the app refuses the browser
  -- (no_app, ambiguous_app), the user types the path.
  local dir_label = 'Directory'
  if dir_source == 'pwd' then dir_label = dir_label .. ' (from the source pane)' end
  if not dir then dir_label = dir_label .. " (empty: each profile's own directory)" end
  -- The renderer takes a changed value while the user has not edited the field. A changed rev
  -- (an explicit choice, choose_dir) replaces the text also after an edit. Saved submitted values
  -- are editor text already.
  fields[#fields + 1] = {id = 'dir', label = dir_label, kind = 'text', required = false, value = kept('dir', dir_text(dir)),
    browse = 'native', rev = draft.dir_rev or 0}
  for _, profile in ipairs(profiles) do options[#options + 1] = {value = profile.id, label = profile.name or profile.id} end
  local function offered(list, value)
    for _, o in ipairs(list) do if o.value == value then return value end end
    return list[1].value
  end
  fields[#fields + 1] = {id = 'profile', label = 'Profile', kind = 'select', required = true, value = offered(options, kept('profile', '')), options = options}
  -- One field per arg name: profiles of one kind usually share them (for example Task). A field
  -- starts empty, and an empty field is not sent, so the chosen profile's own default applies. The
  -- start sends only the args that the chosen profile declares; the hub checks required ones.
  for _, profile in ipairs(profiles) do
    for _, arg in ipairs(profile.args or {}) do
      local f = seen[arg.name]
      if not f then
        f = {labels = {}, has_default = false}
        seen[arg.name] = f
        order[#order + 1] = arg.name
      end
      local label = arg.label or arg.name
      if not f.labels[label] then
        f.labels[label] = true
        f.labels[#f.labels + 1] = label
      end
      f.has_default = f.has_default or (arg.default or '') ~= ''
    end
  end
  for _, name in ipairs(order) do
    local f = seen[name]
    local label = table.concat(f.labels, ' / ')
    if f.has_default then label = label .. " (empty: the profile's default)" end
    fields[#fields + 1] = {id = 'arg/' .. name, label = label, kind = name == 'task' and 'multiline' or 'text', required = false, value = kept('arg/' .. name, '')}
  end
  fields[#fields + 1] = {id = 'title', label = 'Tab title (optional)', kind = 'text', required = false, value = kept('title', '')}
  local places = {{value = 'tab', label = 'New tab'}}
  if context.source_block_id then places[#places + 1] = {value = 'split', label = 'Split beside the source pane'} end
  fields[#fields + 1] = {id = 'placement', label = 'Placement', kind = 'select', required = true, value = offered(places, kept('placement', 'tab')), options = places}
  nodes[#nodes + 1] = {id = 'start', type = 'form', fields = fields, submit_action = action('start', 'Start', spawn_tool)}
  nodes[#nodes + 1] = {id = 'cancel', type = 'widget', text = '', action = action('$cancel', 'Cancel')}
  return {title = title, nodes = nodes, status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}}
end

-- normalize_dir turns the Directory field's text into an absolute path, as data (no shell, no trim).
-- The app's Insert Path types "~/My\ Dir/" (observed: backslash escapes, ~ for home, a trailing /).
-- A fully single-quoted value is accepted too (untested in the app). Empty text means fallback: the
-- directory that the form showed.
local function normalize_dir(text, fallback)
  if type(text) ~= 'string' or text == '' then return fallback end
  local value = text:match("^'([^']*)'$")
  -- One gsub, not a list of characters: Rex Lua table.concat fails above 2559 items (LazyRex
  -- docs/rex-protocol.md).
  if not value then
    value = text:gsub('\\(.?)', function(c)
      if c == '' then fail('invalid_input', 'The directory ends with a lone backslash: ' .. text) end
      return c
    end)
  end
  if value == '~' or value:sub(1, 2) == '~/' then value = (os.getenv('HOME') or '') .. value:sub(2) end
  while #value > 1 and value:sub(-1) == '/' do value = value:sub(1, -2) end
  if value:sub(1, 1) ~= '/' then fail('invalid_input', 'The directory must be an absolute path: ' .. text) end
  return value
end

-- build_request turns the submitted values into one hub.spawn request.
local function build_request(ctx, args, kind, values)
  local context = context_of(args)
  local profile
  for _, p in ipairs(profiles_of(kind)) do if p.id == values.profile then profile = p end end
  if not profile then fail('invalid_input', 'Select a profile') end
  -- focus: the hub shows the new pane only while the form's tab is still the active tab.
  local request = {['for'] = 'user', profile = profile.id, key = 'profiles-start/' .. args.operation_key,
    placement = {session = context.session_id, focus = {source_window_id = context.window_id}}}
  local named = {}
  for _, arg in ipairs(profile.args or {}) do
    local value = values['arg/' .. arg.name]
    if type(value) == 'string' and value ~= '' then named[arg.name] = value end
  end
  if next(named) then request.args = named end
  if type(values.title) == 'string' and values.title ~= '' then request.title = values.title end
  -- The submitted Directory field wins. Empty, or no field (an older renderer): the shown directory.
  request.cwd = normalize_dir(values.dir or '', (form_dir(ctx, read_draft(view_id(args)))))
  if values.placement == 'split' then
    if type(context.source_block_id) ~= 'string' or context.source_block_id == '' then fail('invalid_input', 'The form has no source pane') end
    request.placement.beside, request.placement.direction = context.source_block_id, 'right'
  elseif values.placement ~= 'tab' then
    fail('invalid_input', 'Select a placement')
  end
  return request
end

-- finish sends the saved request and applies its result. hub.spawn is idempotent per key, so a
-- repeat returns the same spawn. A pending outcome completes the view operation and records the
-- pending start in the draft: an operation that stays unknown would hold every later operation of
-- this plugin in the hub's queue. Each write is one statement, so it needs no transaction.
local function finish(args, op_key, request, values)
  local result = app.hub('hub.spawn', request)
  local id = view_id(args)
  -- values is nil for Check again: the pending start saved them.
  local saved = type(values) == 'table' and rex.json.encode(values) or nil
  -- Pending: the draft names the start. Failed: the earlier spawn definitely failed, so Start
  -- returns with the error, and a new submit uses a new key. Both show the submitted values again.
  local pending = result.status == 'pending'
  if pending or result.status == 'failed' then
    db.exec('INSERT INTO drafts (view_id, at, saved_values, error, pending_key, pending_profile, pending_spawn_id) VALUES (?, ?, ?, ?, ?, ?, ?) ' ..
      'ON CONFLICT (view_id) DO UPDATE SET at = excluded.at, saved_values = coalesce(excluded.saved_values, saved_values), error = excluded.error, ' ..
      'pending_key = excluded.pending_key, pending_profile = excluded.pending_profile, pending_spawn_id = excluded.pending_spawn_id, dismissed = NULL',
      id, os.time(), saved, not pending and (result.error or 'The profile did not start') or nil,
      pending and op_key or nil, pending and request.profile or nil, pending and result.spawn_id or nil)
    return {}
  end
  db.exec('DELETE FROM drafts WHERE view_id = ?', id)
  return {close_form = true}
end

local function saved_start(op_key)
  local row = db.first('SELECT request, saved_values FROM starts WHERE op_key = ?', op_key)
  return row and {request = json(row.request), values = json(row.saved_values)}
end

-- start runs one submit. The exact request is saved before hub.spawn, so a retry with the same
-- operation key sends the same request (hub.spawn refuses a changed request for a key).
local function start(ctx, args, kind)
  local op_key = 'start/' .. part(view_id(args)) .. part(args.operation_key)
  local saved = saved_start(op_key)
  if not saved then
    local values = type(args.input) == 'table' and type(args.input.values) == 'table' and args.input.values or {}
    db.exec('INSERT INTO starts (op_key, view_id, at, request, saved_values) VALUES (?, ?, ?, ?, ?) ON CONFLICT (op_key) DO NOTHING',
      op_key, args.view_id, os.time(), rex.json.encode(build_request(ctx, args, kind, values)), rex.json.encode(values))
    saved = saved_start(op_key)
  end
  if not saved or type(saved.request) ~= 'table' then fail('internal', 'Invalid saved start request') end
  return finish(args, op_key, saved.request, type(saved.values) == 'table' and saved.values or nil)
end

local function view_action(ctx, args)
  local kind = kinds[args.route]
  context_of(args)
  if type(args.operation_key) ~= 'string' or args.operation_key == '' then fail('invalid_input', 'An operation key is required') end
  local input = type(args.input) == 'table' and args.input or {}
  local id = type(input.item_id) == 'string' and input.item_id or ''
  if args.node_id == 'start' and args.action == 'start' then
    -- A replay of the pending start itself goes on (it sends the saved request); a new key cannot.
    local draft = read_draft(view_id(args))
    if draft and draft.pending and draft.pending.op_key ~= 'start/' .. part(args.view_id) .. part(args.operation_key) then
      fail('conflict', 'A start is still pending; use Check again')
    end
    return start(ctx, args, kind)
  end
  if args.node_id == 'pending_actions' and args.action == 'check' then
    local draft = read_draft(view_id(args))
    if not draft or not draft.pending then return {} end
    local saved = saved_start(draft.pending.op_key)
    if not saved or type(saved.request) ~= 'table' then fail('internal', 'Invalid saved start request') end
    return finish(args, draft.pending.op_key, saved.request)
  end
  -- Dismiss clears only the pending start that the form showed (its spawn_id). A stale or absent
  -- target changes nothing. The saved values and start record stay; the hub's spawn does not change.
  if args.node_id == 'dismiss_actions' and args.action == 'dismiss' and id:sub(1, 8) == 'dismiss:' then
    db.exec('UPDATE drafts SET at = ?, dismissed = pending_profile, pending_key = NULL, pending_profile = NULL, pending_spawn_id = NULL ' ..
      'WHERE view_id = ? AND pending_spawn_id = ?', os.time(), view_id(args), id:sub(9))
    return {}
  end
  if args.node_id == 'dir_choices' then
    if args.action == 'default' then return choose_dir(args, nil, nil) end
    if args.action == 'choose' and id:sub(1, 5) == 'tree:' then return choose_dir(args, id:sub(6), 'worktree') end
  end
  fail('invalid_input', 'Unknown action ' .. tostring(args.action) .. ' on ' .. tostring(args.node_id))
end

-- tx = false: a start calls hub.spawn (up to 10 s), longer than a handler transaction may stay open.
for route in pairs(kinds) do app.view(route, {render = render_start, ['view.action'] = view_action}, {tx = false}) end
app.command({id = 'start_agent', title = 'Start Agent…', description = 'Start an agent profile in a directory',
  keywords = {'agent', 'profile', 'claude', 'codex'}, route = '/forms/start-agent', action = 'hub.spawn'})
app.command({id = 'start_accessory', title = 'Start Accessory…', description = 'Start a dev server, log tail or shell',
  keywords = {'accessory', 'profile', 'shell', 'server'}, route = '/forms/start-accessory', action = 'hub.spawn'})
-- A worker changed: a pending start's form shows its current state.
app.on('hub.changed', function(args) if args.what == 'workers' then app.refresh() end end)
-- Drafts expire at start and each hour (a render only reads).
app.after(0, expire_drafts)
app.every(3600, expire_drafts)
