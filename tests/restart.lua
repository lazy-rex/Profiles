-- A pending start survives a hub restart (a stop and a crash), on both paths. The saved start
-- request and the hub's spawn row are durable: Check again after the restart sends the same
-- request, and a replay of the same key returns the same spawn.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
local alice = agent('alice')

local bin = F.root .. '/bin/lazyrex-hub'
F.mkdir(F.root .. '/bin')
F.run({'cp', H.args.hub_bin, bin})
local gate = F.root .. '/join-gate'
local profiles = rex.json.decode(rex.json.encode(F.profiles))
profiles.profiles[#profiles.profiles + 1] = {id = 'joiner', name = 'Joiner', kind = 'agent', cwd = F.repo, command = {'/bin/sh', '-c',
  'while [ ! -e "$0" ]; do sleep 0.1; done; exec "$1" testagent -id "$LAZYREX_AGENT" -join "$LAZYREX_AGENT"', gate, bin}}
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

-- Measured on LazyRex 045b5c7 (lab): after hub:restart the form's pane and the hub's view record
-- stay, but the test renderer does not attach again within 12 s, so no view action can run on
-- the old form. This test therefore checks the durable state that Check again reads (the draft
-- with its pending start, and the hub's spawn row), and that the pending spawn still opens when
-- its agent joins after the restart. Check again itself after a restart is not tested.
for _, mode in ipairs({{name = 'a stop', opts = nil}, {name = 'a crash', opts = {crash = true}}}) do
  test('a pending UI start survives ' .. mode.name .. ' of the hub: the draft, the saved request and the spawn', function()
    local src = F.source()
    local v = F.form(src, 'start_agent')
    local key = 'restart-ui-' .. (mode.opts and 'kill' or 'term')
    fault({point = 'spawn-create', mode = 'lose-answer', op = 'profiles-start/' .. key})
    succeeded(v:action('start', 'start', {values = {dir = F.sub, profile = 'joiner', title = '', placement = 'tab'}}, key))
    local spawn = workers_of(src.session, 'joiner')[1]
    expect(spawn.state).to_be('starting')
    local draft = store('draft/' .. v.id)

    local status = hub:restart(mode.opts)
    expect(status.pid).to_be_truthy()
    expect(store('draft/' .. v.id)).to_equal(draft)
    expect(draft.value.pending.spawn_id).to_be(spawn.spawn_id)
    local list = workers_of(src.session, 'joiner')
    expect(list).to_have_length(1)
    expect({list[1].spawn_id, list[1].state, list[1].parent}).to_equal({spawn.spawn_id, 'starting', 'user'})

    F.run({'touch', gate})
    wait('the agent joins', function()
      local w = F.worker(alice, spawn.spawn_id)
      return w and w.state ~= 'starting'
    end, 20)
    F.run({'rm', gate})
    expect(F.spawn_blocks(src.session, spawn.spawn_id)).to_have_length(1)
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
