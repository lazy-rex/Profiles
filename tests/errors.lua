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
