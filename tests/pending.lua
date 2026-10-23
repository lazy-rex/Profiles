-- Pending and failed starts on the real hub, with the hub's spawn-create faults (docs/testing.md,
-- "Faults"). A UI start's hub.spawn key is "profiles-start/<view operation key>", so each fault
-- names the operation key that the test chooses.
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
  -- After the first-request window (15 s) the hub reports why the outcome is unknown. The worker
  -- is not in SQL: the plugin's worker listener renders the form again (an invalidate), and the
  -- shown snapshot updates with no forced render.
  local function invalidates()
    for _, r in ipairs(renders('profiles')) do if r.view_id == v.id then return r.causes.invalidate or 0 end end
    return 0
  end
  local base = invalidates()
  wait('the unknown outcome in the form', function()
    local snap = v:get()
    local shown = snap and snap.tree and node(snap.tree, 'pending')
    return shown and shown.text:find('(outcome unknown: no pane found)', 1, true) ~= nil and invalidates() > base
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
  local joined = wait('the agent joins', function()
    local w = F.worker(alice, spawn.spawn_id)
    return w and w.state ~= 'starting' and w or nil
  end, 20)
  expect(joined.state).to_be('running')
  local op = succeeded(v:action('pending_actions', 'check', {item_id = 'check'}))
  expect(op.result).to_equal({close_form = true})
  wait('the form closed', function()
    for _, w in ipairs(views()) do if w.view_id == v.id then return nil end end
    return true
  end, 10)
  expect(F.draft(v.id)).to_be(nil)
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

-- Dismiss forgets a pending start in the form only. The hub's spawn stays (a pane may still
-- appear), so the form warns first and after.
local warning = 'Dismiss this pending start? A pane may still appear. Starting again can create a duplicate.'
-- The note after a dismiss claims no worker state: the start can open or stay unknown later.
local function dismissed_note(profile)
  return 'You dismissed the pending start of ' .. profile .. '. Dismiss does not stop or remove the worker. ' ..
    'A pane may still appear. Starting again can create a duplicate.'
end
local function dismiss(v, spawn_id, key)
  return succeeded(v:action('dismiss_actions', 'dismiss', {item_id = 'dismiss:' .. spawn_id}, key))
end

test('Dismiss: the form forgets the pending start, keeps the values, and the hub keeps the spawn', function()
  local src = F.source()
  local v = F.form(src, 'start_accessory')
  fault({point = 'spawn-create', mode = 'drop', op = 'profiles-start/dismiss-1'})
  local submitted = values({title = 'Mine'})
  succeeded(v:action('start', 'start', {values = submitted}, 'dismiss-1'))
  local pending = workers_of(src.session, 'logtail')
  expect(pending).to_have_length(1)
  local spawn_id = pending[1].spawn_id

  -- The full warning is its own widget, just before the action. The action is UI state.
  local tree = v:render()
  local ids = {}
  for _, n in ipairs(tree.nodes) do ids[#ids + 1] = n.id end
  expect(ids).to_equal({'pending', 'pending_actions', 'dismiss_warning', 'dismiss_actions', 'cancel'})
  expect(node(tree, 'dismiss_warning').text).to_be(warning)
  local item = node(tree, 'dismiss_actions').items[1]
  expect({item.id, item.label, item.action.label}).to_equal({'dismiss:' .. spawn_id, 'Dismiss pending start', 'Dismiss pending start'})
  expect(item.action.user_only).to_be('draft is UI state')
  expect(item.action.tool).to_be(nil)

  -- The dismiss write commits, then its reply is lost: the hub runs the action again, which finds
  -- no matching pending start and changes nothing. A replay with the same arguments returns the
  -- recorded result.
  local lost = inject({match = {sql_commit_writes = 'drafts'}, fail = 'lost reply', fail_code = 'client_unavailable', after = true})
  dismiss(v, spawn_id, 'dismiss-op-1')
  expect(injection(lost).consumed).to_be(1)
  local d = F.draft(v.id)
  dismiss(v, spawn_id, 'dismiss-op-1')
  expect(F.draft(v.id)).to_equal(d)
  tree = v:render()
  expect(node(tree, 'pending')).to_be(nil)
  expect(node(tree, 'dismissed').text).to_be(dismissed_note('logtail'))
  local shown = {}
  for _, f in ipairs(node(tree, 'start').fields) do shown[f.id] = f.value end
  expect(shown).to_equal(submitted)
  -- The hub's spawn is unchanged: still starting, no pane.
  local after = workers_of(src.session, 'logtail')
  expect(after).to_have_length(1)
  expect({after[1].spawn_id, after[1].state}).to_equal({spawn_id, 'starting'})
  expect(F.spawn_blocks(src.session, spawn_id)).to_have_length(0)

  -- Start runs again with a new key: a second worker, as the warning says. The note goes away.
  local op = succeeded(v:action('start', 'start', {values = submitted}, 'dismiss-2'))
  expect(op.result).to_equal({close_form = true})
  local both = workers_of(src.session, 'logtail')
  expect(both).to_have_length(2)
end)

test('Dismiss after the agent joined: the running worker and its pane stay; the note claims no state', function()
  local src = F.source()
  local v = F.form(src, 'start_agent')
  fault({point = 'spawn-create', mode = 'lose-answer', op = 'profiles-start/dismiss-join'})
  succeeded(v:action('start', 'start', {values = values({profile = 'joiner'})}, 'dismiss-join'))
  local spawn_id = workers_of(src.session, 'joiner')[1].spawn_id
  expect(node(v:render(), 'dismiss_actions').items[1].id).to_be('dismiss:' .. spawn_id)
  -- The agent joins, but the form does not know yet (no Check again).
  F.run({'touch', gate})
  local ok, err = pcall(function()
    wait('the agent joins', function()
      local w = F.worker(alice, spawn_id)
      return w and w.state == 'running' or nil
    end, 20)
    dismiss(v, spawn_id, 'dismiss-join-op')
    expect(node(v:render(), 'dismissed').text).to_be(dismissed_note('joiner'))
    local w = F.worker(alice, spawn_id)
    expect({w.state, w.parent}).to_equal({'running', 'user'})
    expect(F.spawn_blocks(src.session, spawn_id)).to_have_length(1)
    expect(workers_of(src.session, 'joiner')).to_have_length(1)
  end)
  F.run({'rm', gate})
  if not ok then error(err, 0) end
end)

test('Dismiss: a stale or absent target changes nothing and writes nothing', function()
  local src = F.source()
  local v = F.form(src, 'start_accessory')
  -- Absent: no pending start.
  local d = F.draft(v.id)
  dismiss(v, 'spawn-none', 'stale-0')
  expect(F.draft(v.id)).to_equal(d)

  fault({point = 'spawn-create', mode = 'drop', op = 'profiles-start/stale-1'})
  succeeded(v:action('start', 'start', {values = values()}, 'stale-1'))
  local first = workers_of(src.session, 'logtail')[1].spawn_id
  dismiss(v, first, 'stale-op-1')
  -- A newer pending start in the same form.
  fault({point = 'spawn-create', mode = 'drop', op = 'profiles-start/stale-2'})
  succeeded(v:action('start', 'start', {values = values()}, 'stale-2'))
  local second
  for _, w in ipairs(workers_of(src.session, 'logtail')) do if w.spawn_id ~= first then second = w.spawn_id end end
  expect(second).to_be_truthy()
  d = F.draft(v.id)
  -- A Dismiss of the old target (a new key, as from a stale tree) leaves the newer start pending.
  dismiss(v, first, 'stale-op-2')
  expect(F.draft(v.id)).to_equal(d)
  local tree = v:render()
  expect(node(tree, 'pending')).to_be_truthy()
  expect(node(tree, 'dismiss_actions').items[1].id).to_be('dismiss:' .. second)
  expect(workers_of(src.session, 'logtail')).to_have_length(2)
end)

-- client_unavailable is not final: the hub retries the view operation (viewsvc.go, definiteFailure).
-- The retry must send the saved request with the same key, so a spawn whose reply was lost
-- starts one worker, not two. Limit: the fault is an injected error reply, not a real dropped
-- connection (docs/testing.md, "Faults").
test('a lost hub.spawn reply (client_unavailable): the retry returns the same spawn', function()
  local src = F.source()
  local v = F.form(src, 'start_accessory')
  local f = fault({point = 'action', action = 'hub.spawn', when = 'after', mode = 'fail', fail_code = 'client_unavailable'})
  local op = succeeded(v:action('start', 'start', {values = values()}, 'lost-reply'))
  expect(fault_fired(f)).to_be(true)
  expect(op.result).to_equal({close_form = true})
  local list = workers_of(src.session, 'logtail')
  expect(list).to_have_length(1)
  expect(list[1].state).to_be('running')
  expect(F.spawn_blocks(src.session, list[1].spawn_id)).to_have_length(1)
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

  -- lose-answer with the gated joiner: pending with one pane; after the join a replay of the same
  -- key returns the same spawn, open, alice's, with one pane.
  local s3 = session('pending-target-3')
  fault({point = 'spawn-create', mode = 'lose-answer', op = 'agent-join'})
  local join = {profile = 'joiner', cwd = F.sub, placement = {session = s3}, key = 'agent-join'}
  local j = alice:call('hub.spawn', join)
  expect(j.status).to_be('pending')
  expect(alice:call('hub.spawn', join).status).to_be('pending')
  expect(F.spawn_blocks(s3, j.spawn_id)).to_have_length(1)
  F.run({'touch', gate})
  local opened = wait('the agent joins', function()
    local x = alice:call('hub.spawn', join)
    return x.status == 'open' and x or nil
  end, 20)
  F.run({'rm', gate})
  expect(opened.spawn_id).to_be(j.spawn_id)
  expect(F.spawn_blocks(s3, j.spawn_id)).to_have_length(1)
  local jw = F.worker(alice, j.spawn_id)
  expect({jw.parent, jw.cwd}).to_equal({alice.id, F.sub})

  -- refuse: the spawn fails at once.
  fault({point = 'spawn-create', mode = 'refuse', op = 'agent-refuse'})
  local refused = alice:call('hub.spawn', {profile = 'logtail', cwd = F.sub, placement = {session = s2}, key = 'agent-refuse'})
  expect(refused.status).to_be('failed')
  expect(F.spawn_blocks(s2, refused.spawn_id)).to_have_length(0)
end)
