-- Start Agent… and Start Accessory…: palette commands that open a form in the side slot. The form
-- starts a profile with hub.spawn in a chosen directory, in a new tab or in a split beside the
-- source pane. The hub owns profiles, spawns and placement; Rex and Git own directories
-- (profiles_directories.lua). This plugin owns only the form and its draft.
local hub_id = assert(rex.args.hub_client_id, 'hub_client_id is required')
local instance_id = assert(rex.args.instance_id, 'instance_id is required')
local function fail(code, message) error({code = code, message = message}) end
local function hub(action, args)
  local response, call_error = rex.call('client.perform', {client_id = hub_id, action = action, args = args or {}, timeout_ms = 10000})
  if type(response) ~= 'table' then
    if type(call_error) == 'table' then fail(call_error.code or 'unavailable', call_error.message or 'Hub request failed') end
    fail('unavailable', tostring(call_error or 'Hub request failed'))
  end
  if type(response.result) ~= 'table' then fail('internal', 'Invalid hub result') end
  return response.result
end
-- The helper is a sibling file. The hub starts this script by its absolute path (lab, Rex 1203:
-- debug.getinfo gives that path without a leading @).
local script = debug.getinfo(1, 'S').source:gsub('^@', '')
if script:sub(1, 1) ~= '/' then fail('internal', 'The plugin path is not absolute: ' .. script) end
local dirs = assert(loadfile(script:match('^(.*)/') .. '/profiles_directories.lua'))()

local kinds = {['/forms/start-agent'] = 'agent', ['/forms/start-accessory'] = 'accessory'}
local draft_ttl = 24 * 3600 -- a draft whose form never ended expires after a day
local function action(name, label) return {name = name, label = label, enabled = true} end
local function part(value) return tostring(#value) .. ':' .. value end
local function context_of(args)
  local context = args.context
  if type(context) ~= 'table' or type(context.session_id) ~= 'string' or context.session_id == '' then
    fail('invalid_input', 'The form has no source session')
  end
  return context
end
local function profiles_of(kind)
  local list = {}
  for _, profile in ipairs(hub('hub.profiles').profiles or {}) do
    if profile.kind == kind then list[#list + 1] = profile end
  end
  return list
end

-- The draft holds the form's directory choice for one form view:
-- {dir, dir_source, dir_rev, at, pending, error, values}. dir = nil means each profile's own
-- directory. dir_rev counts the explicit directory choices (see choose_dir). Drafts from before
-- the in-form browser was removed can also hold browse and prefix; nothing reads them.
local function draft_key(args)
  if type(args.view_id) ~= 'string' or args.view_id == '' then fail('invalid_input', 'The hub sent no view_id') end
  return 'draft/' .. args.view_id
end
local function read_draft(key)
  local record = hub('hub.store.get', {keys = {key}}).records[key]
  if type(record) ~= 'table' or type(record.rev) ~= 'string' then fail('internal', 'Invalid store record: ' .. key) end
  return record
end
local function expire_drafts()
  local now, after = os.time(), nil
  repeat
    local page = hub('hub.store.scan', {prefix = 'draft/', after = after, limit = 100})
    local ops = {}
    for key, record in pairs(page.records or {}) do
      if type(record.value) ~= 'table' or type(record.value.at) ~= 'number' or record.value.at < now - draft_ttl then
        ops[#ops + 1] = {key = key, if_rev = record.rev, delete = true}
      end
    end
    if #ops > 0 then hub('hub.store.batch', {ops = ops}) end
    after = page.next
  until type(after) ~= 'string' or after == ''
end

-- The first render records the default directory, so the start uses the directory that the form
-- showed, also when the source pane changes directory later.
local function ensure_draft(args, key)
  local record = read_draft(key)
  if record.rev ~= '0' then return record.value end
  local value = {at = os.time()}
  local ok, found = pcall(dirs.source_directory, context_of(args), nil)
  if ok and found then value.dir, value.dir_source = found.path, found.source
  elseif not ok then value.note = type(found) == 'table' and found.message or tostring(found) end
  local stored = hub('hub.store.batch', {ops = {{key = key, if_rev = '0', value = value}}})
  if type(stored.revs) ~= 'table' then return read_draft(key).value end
  pcall(expire_drafts)
  return value
end

-- change_draft applies one action to the draft. The operation record commits with the draft, so a
-- replayed action (same operation key) changes nothing again.
local function change_draft(args, change)
  if type(args.operation_key) ~= 'string' or args.operation_key == '' then fail('invalid_input', 'An operation key is required') end
  local key = draft_key(args)
  local op = {key = 'draft-op/' .. part(args.view_id) .. part(args.operation_key), fingerprint = 'draft-v1/' .. part(args.node_id) .. part(args.action), result = {}}
  for _ = 1, 5 do
    local record = read_draft(key)
    local value = record.rev ~= '0' and record.value or {at = os.time()}
    change(value)
    value.at = os.time()
    local stored = hub('hub.store.batch', {ops = {{key = key, if_rev = record.rev, value = value}}, op = op})
    if stored.op_exists or type(stored.revs) == 'table' then return {} end
    if not stored.conflict or stored.conflict.kind ~= 'revision' then fail('internal', 'Invalid draft write result') end
  end
  fail('unavailable', 'The form changed during the action; try again')
end

-- The draft holds a raw path; the Directory field holds editor text, which normalize_dir decodes.
-- For an absolute path only the backslash is special, so escaping it makes the round trip exact.
local function dir_text(dir) return dir and (dir:gsub('\\', '\\\\')) or '' end

-- Rex Lua is 5.1 (no math.tointeger): a stored count is a number that may be missing or invalid.
local function count(value)
  value = tonumber(value)
  if value and value >= 0 and value == math.floor(value) then return value end
  return 0
end

-- An explicit directory choice (a worktree or the profile default) must
-- reach the Directory field, also when the user edited it. The choice increments dir_rev, the
-- field's rev: a changed rev makes the renderer replace the editor text. The choice also replaces
-- the directory in the values saved by a failed start, and keeps the other saved values.
local function choose_dir(d, dir, source)
  d.dir = dir
  d.dir_source = source
  d.dir_rev = count(d.dir_rev) + 1
  if type(d.values) == 'table' then d.values.dir = dir_text(dir) end
end

local function directory_nodes(draft, nodes)
  if draft.note then nodes[#nodes + 1] = {id = 'directory_note', type = 'widget', text = draft.note} end
  local items = {}
  if draft.dir then
    local ok, trees = pcall(dirs.worktrees, draft.dir)
    if ok and trees and #trees.list > 1 then
      for _, tree in ipairs(trees.list) do
        local name = tree.branch or (tree.detached and 'detached' or '?')
        local mark = tree.path == trees.current and ' (current)' or ''
        items[#items + 1] = {id = 'tree:' .. tree.path, label = 'Worktree ' .. name .. mark, detail = tree.path, action = action('choose', 'Choose')}
      end
    end
    items[#items + 1] = {id = 'default', label = "Use each profile's own directory", action = action('default', 'Use')}
  end
  if #items > 0 then nodes[#nodes + 1] = {id = 'dir_choices', type = 'list', label = 'Directory', items = items} end
end

local function render_start(args)
  local kind = kinds[args.route]
  local context = context_of(args)
  local draft = ensure_draft(args, draft_key(args))
  local title = kind == 'agent' and 'Start Agent' or 'Start Accessory'
  local nodes = {}
  if draft.pending then
    -- The start's outcome is not known. This comes before the profiles load: Check again needs only
    -- the saved request, also when the profiles file broke or lost the profile since. Start stays
    -- hidden: a new key could start a second copy.
    local detail = ''
    local listed, workers = pcall(hub, 'hub.workers')
    for _, worker in ipairs(listed and workers.workers or {}) do
      if worker.spawn_id == draft.pending.spawn_id and type(worker.error) == 'string' then detail = ' (' .. worker.error .. ')' end
    end
    nodes[#nodes + 1] = {id = 'pending', type = 'widget', text = 'Starting ' .. tostring(draft.pending.profile) ..
      '… The outcome is not known yet' .. detail .. '. LazyRex will not start it twice.'}
    nodes[#nodes + 1] = {id = 'pending_actions', type = 'list', items = {{id = 'check', label = 'Check again', action = action('check', 'Check')}}}
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
  directory_nodes(draft, nodes)
  local options, fields, seen, order = {}, {}, {}, {}
  -- After a failed pending start, the fields show the values that the user submitted.
  local saved = type(draft.values) == 'table' and draft.values or {}
  local function kept(id, default) return type(saved[id]) == 'string' and saved[id] or default end
  -- Directory: a text field. browse = "native": the renderer offers the app's directory browser,
  -- which types the chosen path into the field (pane.insert_path). When the app refuses the browser
  -- (no_app, ambiguous_app), the user types the path.
  local dir_label = 'Directory'
  if draft.dir_source == 'pwd' then dir_label = dir_label .. ' (from the source pane)' end
  if not draft.dir then dir_label = dir_label .. " (empty: each profile's own directory)" end
  -- The renderer takes a changed value while the user has not edited the field. A changed rev
  -- (an explicit choice, choose_dir) replaces the text also after an edit. Saved submitted values
  -- are editor text already.
  fields[#fields + 1] = {id = 'dir', label = dir_label, kind = 'text', required = false, value = kept('dir', dir_text(draft.dir)),
    browse = 'native', rev = count(draft.dir_rev)}
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
  nodes[#nodes + 1] = {id = 'start', type = 'form', fields = fields, submit_action = action('start', 'Start')}
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
  if not value then
    local out, i = {}, 1
    while i <= #text do
      local c = text:sub(i, i)
      if c == '\\' then
        if i == #text then fail('invalid_input', 'The directory ends with a lone backslash: ' .. text) end
        out[#out + 1] = text:sub(i + 1, i + 1)
        i = i + 2
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    value = table.concat(out)
  end
  if value == '~' or value:sub(1, 2) == '~/' then value = (os.getenv('HOME') or '') .. value:sub(2) end
  while #value > 1 and value:sub(-1) == '/' do value = value:sub(1, -2) end
  if value:sub(1, 1) ~= '/' then fail('invalid_input', 'The directory must be an absolute path: ' .. text) end
  return value
end

-- build_request turns the submitted values into one hub.spawn request.
local function build_request(args, kind, values)
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
  local draft = read_draft(draft_key(args))
  local shown = draft.rev ~= '0' and type(draft.value.dir) == 'string' and draft.value.dir or nil
  request.cwd = normalize_dir(values.dir or '', shown)
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
-- this plugin in the hub's queue.
local function finish(args, op_key, request, values)
  local result = hub('hub.spawn', request)
  if result.status == 'pending' then
    return change_draft(args, function(d)
      d.pending = {op_key = op_key, profile = request.profile, spawn_id = result.spawn_id}
      if values then d.values = values end -- restored in the fields if the start fails
      d.error = nil
    end)
  end
  if result.status == 'failed' then
    -- The earlier spawn definitely failed: Start returns, and a new submit uses a new key.
    return change_draft(args, function(d)
      d.pending = nil
      d.error = result.error or 'The profile did not start'
    end)
  end
  local key = draft_key(args)
  local draft = read_draft(key)
  if draft.rev ~= '0' then pcall(hub, 'hub.store.batch', {ops = {{key = key, if_rev = draft.rev, delete = true}}}) end
  return {close_form = true}
end

local function saved_request(op_key)
  local saved = hub('hub.store.op', {key = op_key})
  local request = saved.found and type(saved.result) == 'table' and saved.result.request
  if type(request) ~= 'table' then fail('internal', 'Invalid saved start request') end
  return request
end

-- start runs one submit. The exact request is saved before hub.spawn, so a retry with the same
-- operation key sends the same request (hub.spawn refuses a changed request for a key).
local function start(args, kind)
  if type(args.operation_key) ~= 'string' or args.operation_key == '' then fail('invalid_input', 'An operation key is required') end
  local op_key = 'start/' .. part(args.view_id) .. part(args.operation_key)
  local request, values
  local saved = hub('hub.store.op', {key = op_key})
  if saved.found then
    request = type(saved.result) == 'table' and saved.result.request
    values = type(saved.result) == 'table' and saved.result.values
  else
    values = type(args.input) == 'table' and type(args.input.values) == 'table' and args.input.values or {}
    request = build_request(args, kind, values)
    local stored = hub('hub.store.batch', {ops = {}, op = {key = op_key, fingerprint = 'start-v1', result = {request = request, values = values}}})
    if stored.op_exists then
      request = type(stored.op_exists.result) == 'table' and stored.op_exists.result.request
      values = type(stored.op_exists.result) == 'table' and stored.op_exists.result.values
    end
  end
  if type(request) ~= 'table' then fail('internal', 'Invalid saved start request') end
  return finish(args, op_key, request, type(values) == 'table' and values or nil)
end

local function view_action(args)
  local kind = kinds[args.route]
  context_of(args)
  local input = type(args.input) == 'table' and args.input or {}
  local id = type(input.item_id) == 'string' and input.item_id or ''
  if args.node_id == 'start' and args.action == 'start' then
    -- A replay of the pending start itself goes on (it sends the saved request); a new key cannot.
    local draft = read_draft(draft_key(args))
    local pending = draft.rev ~= '0' and draft.value.pending
    if type(pending) == 'table' and pending.op_key ~= 'start/' .. part(args.view_id) .. part(tostring(args.operation_key)) then
      fail('conflict', 'A start is still pending; use Check again')
    end
    return start(args, kind)
  end
  if args.node_id == 'pending_actions' and args.action == 'check' then
    local draft = read_draft(draft_key(args))
    local pending = draft.rev ~= '0' and draft.value.pending
    if type(pending) ~= 'table' or type(pending.op_key) ~= 'string' then return {} end
    return finish(args, pending.op_key, saved_request(pending.op_key))
  end
  if args.node_id == 'dir_choices' then
    if args.action == 'default' then
      return change_draft(args, function(d) choose_dir(d, nil, nil) end)
    elseif args.action == 'choose' and id:sub(1, 5) == 'tree:' then
      return change_draft(args, function(d) choose_dir(d, id:sub(6), 'worktree') end)
    end
  end
  fail('invalid_input', 'Unknown action ' .. tostring(args.action) .. ' on ' .. tostring(args.node_id))
end

local handlers = {
  ['view.render'] = function(args) return {tree = render_start(args)} end,
  ['view.action'] = view_action,
  ['view.seen'] = function() return {} end,
  -- A worker changed: a pending start's form shows its current state.
  ['hub.changed'] = function(args)
    if args.what == 'workers' then pcall(hub, 'hub.ui.invalidate') end
    return {}
  end,
}
local actions = {}
for name in pairs(handlers) do actions[#actions + 1] = {name = name, kind = 'client', title = name,
  args = {type = 'object', additionalProperties = true}} end
rex.call('client.keymap', {actions = actions})
hub('hub.register', {plugin = 'profiles', instance_id = instance_id, exports = {},
  commands = {{id = 'start_agent', title = 'Start Agent…', description = 'Start an agent profile in a directory', keywords = {'agent', 'profile', 'claude', 'codex'}, route = '/forms/start-agent'},
    {id = 'start_accessory', title = 'Start Accessory…', description = 'Start a dev server, log tail or shell', keywords = {'accessory', 'profile', 'shell', 'server'}, route = '/forms/start-accessory'}}})
pcall(expire_drafts)
rex.on('client_perform_requested', function(ctx, ev)
  local ok, result = pcall(function()
    if not ev.requester or ev.requester.client_id ~= hub_id then fail('refused', 'Only the hub calls profiles actions') end
    local handler = handlers[ev.action]
    if not handler then fail('not_supported', 'Unknown profiles action') end
    local args = ev.args or {}
    if ev.action ~= 'hub.changed' and ev.action ~= 'view.seen' and (not kinds[args.route] or args.user ~= 'user') then
      fail('refused', 'Unknown profiles route or user')
    end
    return handler(args)
  end)
  if ok then rex.call('client.reply', {call_id = ev.call_id, result = result})
  else rex.call('client.reply', {call_id = ev.call_id, error = type(result) == 'table' and result or {code = 'internal', message = tostring(result)}}) end
end)
rex.call('client.set_label', {label = 'lazyrex-plugin:profiles'})
