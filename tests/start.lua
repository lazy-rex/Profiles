-- Start flows on both paths (agent parity): the form (the hub's view path, as the user) and
-- hub.spawn as an agent tool. For each flow the two paths must give the same worker: profile,
-- directory, session, title and placement. Only the caller differs: "user" or the agent.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
local alice, bob = agent('alice'), agent('bob')

local function succeeded(op)
  if op.status ~= 'succeeded' or op.effects == 'failed' then error('the operation did not succeed: ' .. show(op), 2) end
  return op
end
local function start_values(over)
  local values = {dir = '', profile = 'logtail', title = '', placement = 'tab'}
  for k, v in pairs(over or {}) do values[k] = v end
  return values
end

test('a new tab: the form and hub.spawn start the same worker in the source session', function()
  local src = F.source()
  local v, tree = F.form(src, 'start_accessory')
  local dir = F.field(tree, 'dir')
  expect(dir.value).to_be(F.sub)
  expect(dir.label).to_match('from the source pane')
  local offered = {}
  for _, o in ipairs(F.field(tree, 'profile').options) do offered[#offered + 1] = o.value end
  expect(offered).to_equal({'shell', 'logtail'})

  local before = F.ids(alice)
  local op = succeeded(v:action('start', 'start', {values = start_values({dir = dir.value})}))
  local ui = F.new_worker(alice, before)
  expect(ui.parent).to_be('user')
  expect(F.draft(v.id)).to_be(nil)
  -- close_form: the form's view is gone.
  wait('the form closed', function()
    for _, w in ipairs(views()) do if w.view_id == v.id then return nil end end
    return true
  end, 10)
  expect(op.effects).not_to_be('failed')

  before = F.ids(alice)
  local r = alice:call('hub.spawn', {profile = 'logtail', cwd = F.sub, placement = {session = src.session}, key = 'tab-1'})
  expect(r.status).to_be('open')
  local tool = F.new_worker(alice, before)
  expect(tool.parent).to_be(alice.id)
  expect(F.same(tool)).to_equal(F.same(ui))
  expect(F.same(ui)).to_equal({profile = 'logtail', cwd = F.sub, session_id = src.session, title = 'Log tail'})
  -- placement.focus: the user's new tab is active and its pane has focus; an agent's tab is not.
  local _, view = F.blocks(src.session)
  local ui_block = F.spawn_blocks(src.session, ui.spawn_id)[1]
  expect(view.active_window_id).to_be(ui_block.window_id)
  for _, w in ipairs(view.windows) do
    if w.window_id == ui_block.window_id then expect(w.focused_block_id).to_be(ui_block.block_id) end
  end
  for _, w in ipairs({ui, tool}) do
    local blocks = F.spawn_blocks(src.session, w.spawn_id)
    expect(blocks).to_have_length(1)
    expect(blocks[1].window_id).not_to_be(src.window)
  end
end)

-- rect_of finds a block's rect [x, y, w, h] in a layout tree.
local function rect_of(node, id)
  if type(node) ~= 'table' then return nil end
  if node.block_id == id then return node.rect end
  if node.split then return rect_of(node.split.before, id) or rect_of(node.split.after, id) end
  return nil
end
-- right_of: block b is directly right of block a in their window (direction "right").
local function right_of(session, window, a, b)
  local _, view = F.blocks(session)
  for _, w in ipairs(view.windows) do
    if w.window_id == window then
      local ra, rb = rect_of(w.layers[1].layout, a), rect_of(w.layers[1].layout, b)
      return ra ~= nil and rb ~= nil and rb[1] >= ra[1] + ra[3] - 1e-9 and rb[2] == ra[2]
    end
  end
  return false
end

test('a split beside the source pane: the same on both paths', function()
  local src = F.source()
  local v, tree = F.form(src, 'start_accessory')
  local places = {}
  for _, o in ipairs(F.field(tree, 'placement').options) do places[#places + 1] = o.value end
  expect(places).to_equal({'tab', 'split'})
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = start_values({dir = F.field(tree, 'dir').value, placement = 'split'})}))
  local ui = F.new_worker(alice, before)

  before = F.ids(alice)
  alice:call('hub.spawn', {profile = 'logtail', cwd = F.sub, key = 'split-1',
    placement = {session = src.session, beside = src.block, direction = 'right'}})
  local tool = F.new_worker(alice, before)
  expect(F.same(tool)).to_equal(F.same(ui))
  local _, view = F.blocks(src.session)
  for _, w in ipairs(view.windows) do
    if w.window_id == src.window then expect(w.focused_block_id).to_be(F.spawn_blocks(src.session, ui.spawn_id)[1].block_id) end
  end
  for _, w in ipairs({ui, tool}) do
    local b = F.spawn_blocks(src.session, w.spawn_id)[1]
    expect(b.window_id).to_be(src.window)
    expect(right_of(src.session, src.window, src.block, b.block_id)).to_be(true)
  end
end)

test('a worktree choice and the profile default: the form sends the directory that an agent sends', function()
  local src = F.source()
  local v, tree = F.form(src, 'start_agent')
  local items = {}
  for _, i in ipairs(H.node(tree, 'dir_choices').items) do items[i.id] = i.label end
  expect(items['tree:' .. F.repo]).to_be('Worktree main (current)')
  expect(items['tree:' .. F.wt]).to_be('Worktree feature')
  expect(items.default).to_be_truthy()

  succeeded(v:action('dir_choices', 'choose', {item_id = 'tree:' .. F.wt}))
  tree = v:render()
  expect({F.field(tree, 'dir').value, F.field(tree, 'dir').rev}).to_equal({F.wt, 1})
  local r = H.node(tree, 'dir_choices').items
  local current
  for _, i in ipairs(r) do if i.label:find('(current)', 1, true) then current = i.id end end
  expect(current).to_be('tree:' .. F.wt)

  -- An explicit task on both paths.
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = start_values({dir = F.field(tree, 'dir').value, profile = 'fake_agent', ['arg/task'] = 'lab1'})}))
  local ui = F.new_worker(alice, before)
  before = F.ids(alice)
  alice:call('hub.spawn', {profile = 'fake_agent', cwd = F.wt, args = {task = 'lab1'}, placement = {session = src.session}, key = 'wt-1'})
  local tool = F.new_worker(alice, before)
  expect(F.same(ui).cwd).to_be(F.wt)
  -- An agent profile's worker is named after the profile and its new agent number.
  expect(ui.title).to_match('^Fake Agent %d+$')
  expect(tool.title).to_match('^Fake Agent %d+$')
  -- Each agent starts in its own new tab, labeled with its worker title.
  for _, w in ipairs({ui, tool}) do
    local blocks = F.spawn_blocks(src.session, w.spawn_id)
    expect(blocks).to_have_length(1)
    expect(blocks[1].window_id).not_to_be(src.window)
    expect(blocks[1].window_label).to_be(w.title)
  end
  expect(F.spawn_blocks(src.session, ui.spawn_id)[1].window_id).not_to_be(F.spawn_blocks(src.session, tool.spawn_id)[1].window_id)
  expect({ui.profile, ui.cwd, ui.session_id}).to_equal({tool.profile, tool.cwd, tool.session_id})
  expect(F.record(ui.agent_id).task).to_be('lab1')
  expect(F.record(tool.agent_id).task).to_be('lab1')
  expect(F.record(ui.agent_id).cwd).to_be(F.wt)
  expect(F.record(tool.agent_id).cwd).to_be(F.wt)

  -- The profile default: an empty Directory field and no cwd; an empty Task and no args.
  v, tree = F.form(src, 'start_agent')
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}))
  tree = v:render()
  expect({F.field(tree, 'dir').value, F.field(tree, 'dir').rev}).to_equal({'', 1})
  expect(F.field(tree, 'dir').label).to_match("each profile's own directory")
  before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = start_values({dir = '', profile = 'fake_agent'})}))
  ui = F.new_worker(alice, before)
  before = F.ids(alice)
  alice:call('hub.spawn', {profile = 'fake_agent', placement = {session = src.session}, key = 'default-1'})
  tool = F.new_worker(alice, before)
  expect({ui.cwd, tool.cwd}).to_equal({F.repo, F.repo})
  expect(F.record(ui.agent_id).task).to_be('alpha default')
  expect(F.record(tool.agent_id).task).to_be('alpha default')
end)

test('directory text: the form decodes editor text; an agent sends the raw absolute path', function()
  local dir = F.home .. '/My Dir'
  F.mkdir(dir)
  local src = F.source()
  local cases = {{'~/My\\ Dir/', dir}, {'~', F.home}, {"'" .. dir .. "/'", dir}, {F.sub .. '//', F.sub}}
  for i, c in ipairs(cases) do
    local v = F.form(src, 'start_accessory')
    local before = F.ids(alice)
    succeeded(v:action('start', 'start', {values = start_values({dir = c[1]})}))
    expect(F.new_worker(alice, before).cwd, c[1]).to_be(c[2])
    before = F.ids(alice)
    alice:call('hub.spawn', {profile = 'logtail', cwd = c[2], placement = {session = src.session}, key = 'text-' .. i})
    expect(F.new_worker(alice, before).cwd).to_be(c[2])
  end
  -- An agent's cwd is data: no decoding.
  expect_error(function() alice:call('hub.spawn', {profile = 'logtail', cwd = '~/My Dir', key = 'text-tilde'}) end, 'absolute')

  -- Invalid and missing directories, on both paths. Nothing starts.
  local before = F.ids(alice)
  for _, text in ipairs({'relative/path', F.sub .. '/trailing\\'}) do
    local v = F.form(src, 'start_accessory')
    local op = v:action('start', 'start', {values = start_values({dir = text})})
    expect(op.status, text).to_be('failed')
    expect(op.error.code).to_be('invalid_input')
  end
  expect_error(function() alice:call('hub.spawn', {profile = 'logtail', cwd = 'relative/path', key = 'text-rel'}) end, 'absolute')
  local missing = F.root .. '/missing'
  local v = F.form(src, 'start_accessory')
  local op = v:action('start', 'start', {values = start_values({dir = missing})})
  expect(op.status).to_be('failed')
  local agent_error = expect_error(function() alice:call('hub.spawn', {profile = 'logtail', cwd = missing, key = 'text-missing'}) end)
  expect(op.error.message).to_be(agent_error.message)
  expect(F.ids(alice)).to_equal(before)
end)

test('admission: only a joined agent or the user starts a profile; focus is the user\'s', function()
  local src = F.source()
  local stranger = agent('stranger', {report = false})
  expect_error(function() stranger:call('hub.spawn', {profile = 'logtail', key = 'adm-1'}) end, 'not a joined agent')
  -- The runner is outside every pane.
  expect_error(function() H.perform(H.resolve('lazyrex'), 'hub.spawn', {profile = 'logtail', key = 'adm-2'}) end, 'not a joined agent')
  expect_error(function() alice:call('hub.spawn', {profile = 'logtail', key = 'adm-3', ['for'] = 'user'}) end, 'only a registered plugin')
  expect_error(function() alice:call('hub.spawn', {profile = 'logtail', key = 'adm-4',
    placement = {session = src.session, focus = {source_window_id = src.window}}}) end, 'focus')
  -- Direct calls to the plugin, also with forged user and context fields.
  local forged = {route = '/forms/start-agent', user = 'user', view_id = 'forged', node_id = 'start', action = 'start',
    operation_key = 'forged-1', context = {session_id = src.session, source_block_id = src.block, window_id = src.window},
    input = {values = start_values({profile = 'fake_agent'})}}
  expect_error(function() alice:direct('view.action', forged) end, 'Only the hub')
  expect_error(function() user:plugin_view('action', forged) end, 'Only the hub')
  expect_error(function() alice:direct('view.render', forged) end, 'Only the hub')
end)

test('replay and conflicts: a key belongs to its caller; a changed request is refused', function()
  local src = F.source()
  local request = {profile = 'fake_agent', cwd = F.sub, args = {task = 'replay'}, title = 'Replay', placement = {session = src.session}, key = 'rp-1'}
  local first = alice:call('hub.spawn', request)
  local again = alice:call('hub.spawn', request)
  expect(again.spawn_id).to_be(first.spawn_id)
  expect(F.spawn_blocks(src.session, first.spawn_id)).to_have_length(1)
  local changes = {profile = 'beta', cwd = F.wt, args = {task = 'other'}, title = 'Other', placement = {session = src.session, beside = src.block}}
  for field, value in pairs(changes) do
    local changed = {}
    for k, x in pairs(request) do changed[k] = x end
    changed[field] = value
    expect_error(function() alice:call('hub.spawn', changed) end, 'different request')
  end
  -- The same key from bob is bob's own request.
  local theirs = bob:call('hub.spawn', request)
  expect(theirs.spawn_id).not_to_be(first.spawn_id)
  expect(F.worker(alice, theirs.spawn_id).parent).to_be(bob.id)

  -- The form: a view operation whose start request is already saved (another invocation saved it
  -- first) sends the saved request, not the new values, the new source directory or the new
  -- profile file.
  local v, tree = F.form(src, 'start_accessory')
  local key = 'ui-rp-1'
  local function part(x) return tostring(#x) .. ':' .. x end
  local saved = {['for'] = 'user', profile = 'logtail', key = 'profiles-start/' .. key, cwd = F.wt,
    placement = {session = src.session, focus = {source_window_id = src.window}}}
  sql_write('INSERT INTO starts (op_key, view_id, at, request, saved_values) VALUES (?, ?, ?, ?, ?)',
    {'start/' .. part(v.id) .. part(key), v.id, os.time(), rex.json.encode(saved), rex.json.encode(start_values({dir = F.wt}))})
  F.cd(src, F.deeper)
  local profiles = rex.json.decode(rex.json.encode(F.profiles))
  profiles.profiles[3].name = 'Renamed tail'
  write_profiles(profiles)
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = start_values({dir = F.field(tree, 'dir').value, placement = 'split'})}, key))
  local ui = F.new_worker(alice, before)
  expect({ui.cwd, ui.parent, ui.title}).to_equal({F.wt, 'user', 'Renamed tail'})
  expect(F.spawn_blocks(src.session, ui.spawn_id)[1].window_id).not_to_be(src.window)
  write_profiles(F.profiles)
end)

test('stop: any agent stops any worker; a repeated stop is safe; a pending start cannot be stopped', function()
  local src = F.source()
  local own_agent = alice:call('hub.spawn', {profile = 'fake_agent', placement = {session = src.session}, key = 'stop-a'})
  local own_acc = alice:call('hub.spawn', {profile = 'logtail', placement = {session = src.session}, key = 'stop-b'})
  local bobs_agent = bob:call('hub.spawn', {profile = 'fake_agent', placement = {session = src.session}, key = 'stop-c'})
  local bobs_acc = bob:call('hub.spawn', {profile = 'logtail', placement = {session = src.session}, key = 'stop-d'})
  local v, tree = F.form(src, 'start_accessory')
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = start_values({dir = F.field(tree, 'dir').value})}))
  local users_acc = F.new_worker(alice, before)
  v, tree = F.form(src, 'start_agent')
  before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = start_values({dir = F.field(tree, 'dir').value, profile = 'fake_agent'})}))
  local users_agent = F.new_worker(alice, before)
  -- The parent still names who started each worker; it does not limit stop.
  local cases = {{own_agent.spawn_id, alice.id}, {own_acc.spawn_id, alice.id}, {bobs_agent.spawn_id, bob.id},
    {bobs_acc.spawn_id, bob.id}, {users_acc.spawn_id, 'user'}, {users_agent.spawn_id, 'user'}}
  for _, c in ipairs(cases) do
    expect(F.worker(alice, c[1]).parent, c[1]).to_be(c[2])
    alice:call('hub.stop', {spawn_id = c[1]})
    expect(F.worker(alice, c[1]), c[1]).to_be(nil)
    expect(F.spawn_blocks(src.session, c[1]), c[1]).to_have_length(0)
    alice:call('hub.stop', {spawn_id = c[1]}) -- a repeated stop succeeds and changes nothing
  end
  -- A pending start with an unknown outcome cannot be stopped, also by its own starter.
  fault({point = 'spawn-create', mode = 'drop', op = 'stop-pending'})
  local pending = bob:call('hub.spawn', {profile = 'logtail', placement = {session = src.session}, key = 'stop-pending'})
  expect(pending.status).to_be('pending')
  for _, who in ipairs({alice, bob}) do
    expect_error(function() who:call('hub.stop', {spawn_id = pending.spawn_id}) end, 'cannot stop it')
  end
  -- Caller admission stays: a pane that is not a joined agent cannot stop a worker.
  local stranger = agent('stranger', {report = false})
  local target = alice:call('hub.spawn', {profile = 'logtail', placement = {session = src.session}, key = 'stop-e'})
  expect_error(function() stranger:call('hub.stop', {spawn_id = target.spawn_id}) end, 'not a joined agent')
  expect(F.worker(alice, target.spawn_id)).to_be_truthy()
end)
