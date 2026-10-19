-- The plugin contract on the real hub: the client label, no exports of its own (agents use the
-- hub's hub.profiles and hub.spawn), and a new render request when a worker changes.
local alice = agent('alice')

local function client(label)
  local r = rex.call('target.resolve', {kinds = {'client'}, queries = {label}})
  local x = r and r.results and r.results[1]
  if not x or x.status ~= 'resolved' then error('cannot resolve client ' .. label, 0) end
  return x.target.client_id
end

test('the plugin has its label and exports nothing; the agent face lists the hub tools', function()
  local own = {}
  for _, a in ipairs(rex.call('client.inspect', {client_id = client('lazyrex-plugin:profiles')}).actions) do own[a.name] = true end
  expect(own['view.render'] and own['view.action'] and own['hub.changed']).to_be(true)
  expect(own['hub.forward']).to_be(nil)
  local face = {}
  for _, a in ipairs(rex.call('client.inspect', {client_id = client('lazyrex')}).actions) do face[a.name] = true end
  for _, name in ipairs({'hub.profiles', 'hub.spawn', 'hub.workers', 'hub.stop'}) do expect(face[name], name).to_be(true) end
  for name in pairs(face) do expect(name:sub(1, 9), name).not_to_be('profiles.') end
  expect_error(function() alice:call('view.render', {route = '/forms/start-agent', user = 'user'}) end, 'view.render')
end)

test('a worker change asks the hub for a new render', function()
  local before = invalidates()
  alice:call('hub.spawn', {profile = 'logtail', key = 'contract-1'})
  wait('a hub.ui.invalidate call', function() return invalidates() > before end, 10)
end)
