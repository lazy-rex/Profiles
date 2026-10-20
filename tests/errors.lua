-- A hub refusal of a start is a final failure of the view operation, with the hub's code and
-- message. It must not become "unavailable": the hub retries such an operation, and an operation
-- that never ends holds every later operation of this plugin in the hub's queue.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)

test('a refused start fails with the hub code and message; the next start runs', function()
  local src = F.source()
  local missing = F.root .. '/missing'
  local v = F.form(src, 'start_accessory')
  local op = v:settle(select(2, v:admit('action', {node_id = 'start', action = 'start',
    input = {values = {dir = missing, profile = 'logtail', title = '', placement = 'tab'}}})), 10)
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('refused')
  expect(op.error.message).to_be(missing .. ' is not an existing directory')

  local w, tree = F.form(src, 'start_accessory')
  local next_op = w:action('start', 'start', {values = {dir = F.field(tree, 'dir').value, profile = 'logtail', title = '', placement = 'tab'}})
  expect(next_op.status).to_be('succeeded')
end)

-- A start whose directory does not exist cannot succeed. On every path it must fail at once with
-- the hub's refusal, and start nothing. (On an older hub, such a start was retried thousands of
-- times as "outcome unknown: unavailable", and the form never ended.)
local alice = agent('alice')
local function values(over)
  local v = {dir = '', profile = 'logtail', title = '', placement = 'tab'}
  for k, x in pairs(over or {}) do v[k] = x end
  return v
end
-- refused_at_once checks one final refusal (a form operation or an agent error) and no new worker.
local function refused_at_once(failure, dir, before)
  expect(failure.code).to_be('refused')
  expect(failure.message).to_be(dir .. ' is not an existing directory')
  expect(F.ids(alice)).to_equal(before)
end

-- An explicit missing directory on both paths: start.lua ('directory text').
test("a missing profile directory: the form and hub.spawn fail at once with the same refusal", function()
  local gone = F.root .. '/gone-profile'
  local profiles = {profiles = {F.profiles.profiles[3],
    {id = 'gone', name = 'Gone', kind = 'accessory', cwd = gone, command = {'/bin/sh', '-c', 'exec sleep 100000'}}}}
  write_profiles(profiles)
  local before = F.ids(alice)
  local src = F.source()
  local v = F.form(src, 'start_accessory')
  v:action('dir_choices', 'default', {item_id = 'default'})
  expect(F.field(v:render(), 'dir').value).to_be('')
  local op = v:action('start', 'start', {values = values({profile = 'gone'})})
  expect(op.status).to_be('failed')
  refused_at_once(op.error, gone, before)

  local e = expect_error(function() alice:call('hub.spawn', {profile = 'gone', key = 'gone-1'}) end, 'refused')
  refused_at_once(e, gone, before)
  -- The form stays usable: a start of another profile runs.
  local next_op = v:action('start', 'start', {values = values({dir = F.sub})})
  expect(next_op.status).to_be('succeeded')
  write_profiles(F.profiles)
end)

test('the shown directory removed before Start, and ~ text for a missing folder: the form fails at once', function()
  local vanish = F.root .. '/vanish'
  F.mkdir(vanish)
  local src = F.source(vanish)
  local v, tree = F.form(src, 'start_accessory')
  expect(F.field(tree, 'dir').value).to_be(vanish)
  F.run({'rmdir', vanish})
  local before = F.ids(alice)
  -- An empty field starts in the shown directory (form.lua).
  local op = v:action('start', 'start', {values = values()})
  expect(op.status).to_be('failed')
  refused_at_once(op.error, vanish, before)

  local w = F.form(F.source(), 'start_accessory')
  op = w:action('start', 'start', {values = values({dir = '~/Projects/does-not-exist'})})
  expect(op.status).to_be('failed')
  refused_at_once(op.error, os.getenv('HOME') .. '/Projects/does-not-exist', before)
end)
