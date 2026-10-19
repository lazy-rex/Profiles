-- Pending and failed starts on the real hub, with the hub's spawn-create faults (docs/testing.md,
-- "Faults"). A UI start's hub.spawn key is "profiles-start/<view operation key>", so each fault
-- names the operation key that the test chooses. Ported from the pending parts of
-- profiles-plugin.mjs, which scripted these outcomes with a mock hub.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
local alice = agent('alice')

-- joiner: an agent profile whose process joins the hub only after the gate file exists, so a test
-- sees the pending state first. The joining process is the harness test agent (a copy in the lab).
local bin = F.root .. '/bin/lazyrex-hub'
F.mkdir(F.root .. '/bin')
F.run({'cp', H.args.hub_bin, bin})
local gate = F.root .. '/join-gate'
local profiles = rex.json.decode(rex.json.encode(F.profiles))
profiles.profiles[#profiles.profiles + 1] = {id = 'joiner', name = 'Joiner', kind = 'agent', cwd = F.repo, command = {'/bin/sh', '-c',
  'while [ ! -e "$0" ]; do sleep 0.1; done; exec "$1" testagent -id "$LAZYREX_AGENT" -join "$LAZYREX_AGENT"', gate, bin}}
write_profiles(profiles)

local function values(over)
  local v = {dir = F.sub, profile = 'logtail', title = '', placement = 'tab'}
  for k, x in pairs(over or {}) do v[k] = x end
  return v
end
local function succeeded(op)
  if op.status ~= 'succeeded' or op.effects == 'failed' then error('the operation did not succeed: ' .. show(op), 2) end
  return op
end
-- workers_of lists the workers of a profile in a session.
local function workers_of(session, profile)
  local list = {}
  for _, w in ipairs(alice:call('hub.workers', {}).workers or {}) do
    if w.session_id == session and w.profile == profile then list[#list + 1] = w end
  end
  return list
end

test('a lost create: the form shows the pending start, refuses a second start, and Check again keeps it', function()
  local src = F.source()
  local v = F.form(src, 'start_accessory')
  local f = fault({point = 'spawn-create', mode = 'drop', op = 'profiles-start/pend-drop'})
  expect(succeeded(v:action('start', 'start', {values = values()}, 'pend-drop')).result).to_equal({})
  expect(fault_fired(f)).to_be(true)
  local tree = v:render()
  expect(node(tree, 'start')).to_be(nil)
  expect(node(tree, 'pending').text).to_match('^Starting logtail… The outcome is not known yet')
  expect(node(tree, 'pending_actions').items[1].action.tool).to_be('hub.spawn')
  expect(v:get().status).to_equal({state = 'working', msg = 'Starting'})
  local pending = workers_of(src.session, 'logtail')
  expect(pending).to_have_length(1)
  expect(pending[1].state).to_be('starting')
  expect(F.spawn_blocks(src.session, pending[1].spawn_id)).to_have_length(0)

  -- A second start (a new key) is a conflict; nothing new starts.
  local second = v:action('start', 'start', {values = values()}, 'pend-drop-2')
  expect(second.status).to_be('failed')
  expect(second.error.code).to_be('conflict')
  expect(second.error.message).to_match('still pending')
  -- Another form keeps working. (A window has one side slot: another form in the source window
  -- would replace this one, so it opens from another source.)
  local other = F.form(F.source(), 'start_accessory')
  succeeded(other:action('dir_choices', 'default', {item_id = 'default'}))

  -- Check again sends the saved request: the same spawn, also after the source pane changed
  -- directory and the profile file broke.
  F.cd(src, F.deeper)
  write_profiles('{"profiles": [')
  local ok, err = pcall(function()
    expect(node(v:render(), 'pending_actions')).to_be_truthy()
    succeeded(v:action('pending_actions', 'check', {item_id = 'check'}))
  end)
  write_profiles(profiles)
  if not ok then error(err, 0) end
  local after = workers_of(src.session, 'logtail')
  expect(after).to_have_length(1)
  expect(after[1].spawn_id).to_be(pending[1].spawn_id)
  -- After the first-request window (15 s) the hub reports why the outcome is unknown.
  wait('the unknown outcome in the form', function()
    return node(v:render(), 'pending').text:find('(outcome unknown: no pane found)', 1, true) ~= nil
  end, 30)
end)

test('a lost answer for an agent: pending until the agent joins, then Check again opens it', function()
  local src = F.source()
  local v = F.form(src, 'start_agent')
  local f = fault({point = 'spawn-create', mode = 'lose-answer', op = 'profiles-start/pend-join'})
  succeeded(v:action('start', 'start', {values = values({profile = 'joiner'})}, 'pend-join'))
  expect(fault_fired(f)).to_be(true)
  local list = workers_of(src.session, 'joiner')
  expect(list).to_have_length(1)
  local spawn = list[1]
  expect(spawn.state).to_be('starting')
  expect(F.spawn_blocks(src.session, spawn.spawn_id)).to_have_length(1)
  succeeded(v:action('pending_actions', 'check', {item_id = 'check'}))
  expect(node(v:render(), 'pending')).to_be_truthy()

  F.run({'touch', gate})
  wait('the agent joins', function()
    local w = F.worker(alice, spawn.spawn_id)
    return w and w.state ~= 'starting'
  end, 20)
  local op = succeeded(v:action('pending_actions', 'check', {item_id = 'check'}))
  expect(op.result).to_equal({close_form = true})
  wait('the form closed', function()
    for _, w in ipairs(views()) do if w.view_id == v.id then return nil end end
    return true
  end, 10)
  expect(store('draft/' .. v.id).rev).to_be('0')
  local w = F.worker(alice, spawn.spawn_id)
  expect({w.parent, w.cwd}).to_equal({'user', F.sub})
  expect(F.spawn_blocks(src.session, spawn.spawn_id)).to_have_length(1)
  F.run({'rm', gate})
end)

test('a refused create: the form shows the error and Start returns', function()
  local src = F.source()
  local v = F.form(src, 'start_accessory')
  fault({point = 'spawn-create', mode = 'refuse', op = 'profiles-start/refuse-1'})
  local submitted = values({dir = F.wt, title = 'Mine', placement = 'split'})
  succeeded(v:action('start', 'start', {values = submitted}, 'refuse-1'))
  local tree = v:render()
  -- A failed start keeps what the user submitted: a new render shows the submitted values.
  local shown = {}
  for _, f in ipairs(node(tree, 'start').fields) do shown[f.id] = f.value end
  expect(shown).to_equal(submitted)
  expect(node(tree, 'start')).to_be_truthy()
  expect(node(tree, 'start_error').text).to_be('The last start failed: refused: injected fault: Rex refused the create')
  -- The failed spawn is listed as failed, with no pane.
  local list = workers_of(src.session, 'logtail')
  expect(list).to_have_length(1)
  expect({list[1].state, list[1].title}).to_equal({'failed', 'Mine'})
  expect(F.spawn_blocks(src.session, list[1].spawn_id)).to_have_length(0)
end)

test('hub.spawn as an agent: pending, replay and session gone; a refused create fails', function()
  local target = session('pending-target')
  -- drop: pending with no pane; a replay returns the same spawn; the session closes; the same key
  -- then reports failed.
  local f = fault({point = 'spawn-create', mode = 'drop', op = 'agent-drop'})
  local request = {profile = 'logtail', cwd = F.sub, placement = {session = target}, key = 'agent-drop'}
  local first = alice:call('hub.spawn', request)
  expect(first.status).to_be('pending')
  expect(fault_fired(f)).to_be(true)
  expect(alice:call('hub.spawn', request).spawn_id).to_be(first.spawn_id)
  expect(F.spawn_blocks(target, first.spawn_id)).to_have_length(0)
  close_session(target)
  local gone = wait('the pending spawn fails', function()
    local r = alice:call('hub.spawn', request)
    return r.status == 'failed' and r or nil
  end, 15)
  expect(gone.spawn_id).to_be(first.spawn_id)
  expect(gone.error).to_match('session gone')

  -- lose-answer: an accessory pane exists, the spawn stays pending, a replay creates no pane.
  local s2 = session('pending-target-2')
  fault({point = 'spawn-create', mode = 'lose-answer', op = 'agent-lose'})
  local lose = {profile = 'logtail', cwd = F.sub, placement = {session = s2}, key = 'agent-lose'}
  local r = alice:call('hub.spawn', lose)
  expect(r.status).to_be('pending')
  expect(alice:call('hub.spawn', lose).spawn_id).to_be(r.spawn_id)
  expect(F.spawn_blocks(s2, r.spawn_id)).to_have_length(1)
  expect_error(function() alice:call('hub.stop', {spawn_id = r.spawn_id}) end, 'cannot stop it')

  -- refuse: the spawn fails at once.
  fault({point = 'spawn-create', mode = 'refuse', op = 'agent-refuse'})
  local refused = alice:call('hub.spawn', {profile = 'logtail', cwd = F.sub, placement = {session = s2}, key = 'agent-refuse'})
  expect(refused.status).to_be('failed')
  expect(F.spawn_blocks(s2, refused.spawn_id)).to_have_length(0)
end)
