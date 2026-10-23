-- The start order of the plugin in a sandbox: the real SDK (H.args.sdk) and the real profiles.lua,
-- with a fake rex. The fake hub refuses hub.sql before hub.register, as the hub does. Rex can run two
-- timers of the same delay in either order (observed once in a lab), so the sandbox runs the zero
-- timers that the plugin made before the zero timer of the SDK.

local plugin_dir = H.args.file:match('^(.*)/tests/[^/]*$')

-- start loads the plugin in a new environment and runs its zero timers, the last one made first.
-- It answers the hub calls in their order, and the hub.sql calls that the fake hub refused.
local function start()
  local calls, refused, timers, printed = {}, {}, {}, {}
  local registered = false
  local results = {
    ['hub.register'] = {generation = '1', limits = {inline_max = 60000, part_bytes = 30000, max_total = 1000000}},
    ['hub.sql.begin'] = {tx = 'tx-1'},
    ['hub.sql.query'] = {columns = {'user_version'}, rows = {{1}}},
  }
  local fake = {
    args = {hub_client_id = 'client:hub', instance_id = 'profiles-1', main = plugin_dir .. '/profiles.lua'},
    session_id = 'session:sandbox', json = rex.json,
    on = function() end,
    after = function(seconds, fn) timers[#timers + 1] = {seconds = seconds, fn = fn} end,
    call = function(method, a)
      if method ~= 'client.perform' then return {} end
      if a.action:sub(1, 8) == 'hub.sql.' and not registered then
        refused[#refused + 1] = a.action
        return nil, {code = 'refused', message = 'only a registered plugin instance may call ' .. a.action}
      end
      if a.action == 'hub.register' then registered = true end
      calls[#calls + 1] = {action = a.action, sql = a.args.sql}
      return {result = results[a.action] or {}}
    end,
  }
  local env = setmetatable({rex = fake, print = function(text) printed[#printed + 1] = text end,
    io = setmetatable({}, {__index = io}),
    os = setmetatable({exit = function(code) error('os.exit ' .. tostring(code), 0) end}, {__index = os})}, {__index = _G})
  env._G = env
  local loaded = {}
  env.require = function(name)
    if loaded[name] == nil then
      local dir = name == 'lazyrex' and H.args.sdk or plugin_dir
      local chunk = assert(loadfile(dir .. '/' .. name .. '.lua'))
      setfenv(chunk, env)
      loaded[name] = chunk(name) or true
    end
    return loaded[name]
  end
  local main = assert(loadfile(plugin_dir .. '/profiles.lua'))
  setfenv(main, env)
  main()
  for i = #timers, 1, -1 do
    if timers[i].seconds == 0 then
      local ok, err = pcall(timers[i].fn)
      if not ok then printed[#printed + 1] = tostring(err) end
    end
  end
  return calls, refused, printed
end

test('the startup expiry runs after the registration, also when the plugin timer runs first', function()
  local calls, refused, printed = start()
  local register, expiry
  for i, c in ipairs(calls) do
    if c.action == 'hub.register' then register = register or i end
    if c.action == 'hub.sql.exec' and c.sql and c.sql:match('^DELETE FROM drafts') then expiry = expiry or i end
  end
  expect(refused, table.concat(printed, '\n')).to_equal({})
  expect(register).to_be_truthy()
  expect(expiry, 'the startup expiry did not run').to_be_truthy()
  expect(expiry > register).to_be(true)
end)
