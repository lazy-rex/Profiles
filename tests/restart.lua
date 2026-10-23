-- A pending start survives a hub restart (a stop and a crash), on both paths: the form's draft
-- (with its reference to the saved start request) and the hub's spawn row stay, Check again on the
-- same form sends the saved request, and a replay of an agent's key returns the same spawn.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
local alice = agent('alice')

local bin = F.root .. '/bin/lazyrex-hub'
F.mkdir(F.root .. '/bin')
F.run({'cp', H.args.hub_bin, bin})
local gate = F.root .. '/join-gate'
local profiles = rex.json.decode(rex.json.encode(F.profiles))
profiles.profiles[#profiles.profiles + 1] = {id = 'joiner', name = 'Joiner', kind = 'agent', cwd = F.repo, command = {'/bin/sh', '-c', [[
while [ ! -e "$0" ]; do sleep 0.1; done
"$1" testagent report "$(printf '{"kind":"codex","conversation_id":"joiner-%s","source":"startup"}' $$)"
exec sleep 100000]], gate, bin}}
write_profiles(profiles)

local function succeeded(op)
  if op.status ~= 'succeeded' or op.effects == 'failed' then error('the operation did not succeed: ' .. show(op), 2) end
  return op
end
local function workers_of(session, profile)
  local list = {}
  for _, w in ipairs(alice:call('hub.workers', {}).workers or {}) do
    if w.session_id == session and w.profile == profile then list[#list + 1] = w end
  end
  return list
end

-- After hub:restart the form's pane and the hub's view record stay, and the test renderer attaches
-- again (LazyRex 9dc56f6). Check again then runs on the same view: it reads the draft's pending
-- start, resolves its reference to the saved start request, and sends that request.
for _, mode in ipairs({{name = 'a stop', opts = nil}, {name = 'a crash', opts = {crash = true}}}) do
  test('a pending UI start survives ' .. mode.name .. ' of the hub; Check again on the same form opens it', function()
    local src = F.source()
    local v = F.form(src, 'start_agent')
    local key = 'restart-ui-' .. (mode.opts and 'kill' or 'term')
    fault({point = 'spawn-create', mode = 'lose-answer', op = 'profiles-start/' .. key})
    succeeded(v:action('start', 'start', {values = {dir = F.sub, profile = 'joiner', title = '', placement = 'tab'}}, key))
    local spawn = workers_of(src.session, 'joiner')[1]
    expect(spawn.state).to_be('starting')
    local draft = F.draft(v.id)

    local status = hub:restart(mode.opts)
    expect(status.pid).to_be_truthy()
    expect(F.draft(v.id)).to_equal(draft)
    expect(draft.pending_spawn_id).to_be(spawn.spawn_id)
    local list = workers_of(src.session, 'joiner')
    expect(list).to_have_length(1)
    expect({list[1].spawn_id, list[1].state, list[1].parent}).to_equal({spawn.spawn_id, 'starting', 'user'})

    -- The same form, attached again: it still shows the pending start, and Check again sends the
    -- saved request (the same spawn, no second one).
    local id = v.id
    v = user:view('/forms/start-agent', nil, src.session)
    expect(v.id).to_be(id)
    expect(node(v:render(), 'pending')).to_be_truthy()
    succeeded(v:action('pending_actions', 'check', {item_id = 'check'}))
    expect(node(v:render(), 'pending')).to_be_truthy()
    expect(workers_of(src.session, 'joiner')).to_have_length(1)

    F.run({'touch', gate})
    local joined = wait('the agent reports', function()
      local w = F.worker(alice, spawn.spawn_id)
      return w and w.state ~= 'starting' and w or nil
    end, 20)
    expect(joined.state).to_be('running')
    F.run({'rm', gate})
    expect(succeeded(v:action('pending_actions', 'check', {item_id = 'check'})).result).to_equal({close_form = true})
    expect(F.draft(v.id)).to_be(nil)
    expect(F.spawn_blocks(src.session, spawn.spawn_id)).to_have_length(1)
    expect(F.worker(alice, spawn.spawn_id).parent).to_be('user')
  end)
end

test('a pending agent start survives a hub crash: the same key returns the same spawn', function()
  local target = session('restart-target')
  fault({point = 'spawn-create', mode = 'drop', op = 'restart-agent'})
  local request = {profile = 'logtail', cwd = F.sub, placement = {session = target}, key = 'restart-agent'}
  local first = alice:call('hub.spawn', request)
  expect(first.status).to_be('pending')
  hub:restart({crash = true})
  local again = alice:call('hub.spawn', request)
  expect({again.spawn_id, again.status}).to_equal({first.spawn_id, 'pending'})
  expect(F.spawn_blocks(target, first.spawn_id)).to_have_length(0)
end)
