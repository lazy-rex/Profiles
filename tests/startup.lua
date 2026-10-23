-- The start order of the plugin in a sandbox: the real SDK (H.args.sdk) and the real profiles.lua,
-- with a fake rex. The fake hub refuses hub.sql before hub.register, as the hub does. Rex can run two
-- timers of the same delay in either order (observed once in a lab), so the sandbox runs the zero
-- timers that the plugin made before the zero timer of the SDK.

local plugin_dir = H.args.file:match('^(.*)/tests/[^/]*$')

-- start loads the plugin in a new environment and runs its zero timers, the last one made first,
-- also the timers that a timer makes. opts.fail(action, sql): true makes the fake hub fail that call
-- after the first commit (the migration). start answers the hub calls in their order, the hub.sql
-- calls that the fake hub refused, the printed lines, and the calls that it failed.
local function start(opts)
  opts = opts or {}
  local calls, refused, failed, timers, printed = {}, {}, {}, {}, {}
  local registered, migrated = false, false
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
      if migrated and opts.fail and opts.fail(a.action, a.args.sql or '') then
        failed[#failed + 1] = a.action
        return nil, {code = 'internal', message = 'disk I/O error'}
      end
      if a.action == 'hub.sql.commit' then migrated = true end
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
  local ran = {}
  while true do
    local next
    for i = #timers, 1, -1 do
      if timers[i].seconds == 0 and not ran[i] then next = i; break end
    end
    if not next then break end
    ran[next] = true
    local ok, err = pcall(timers[next].fn)
    if not ok then printed[#printed + 1] = tostring(err) end
  end
  return calls, refused, printed, failed
end

-- first answers the index of the first call that matches action (and the SQL pattern).
local function first(calls, action, pattern)
  for i, c in ipairs(calls) do
    if c.action == action and (not pattern or (c.sql and c.sql:match(pattern))) then return i end
  end
end

test('the startup expiry runs after the registration, also when the plugin timer runs first', function()
  local calls, refused, printed = start()
  local register, expiry = first(calls, 'hub.register'), first(calls, 'hub.sql.exec', '^DELETE FROM drafts')
  expect(refused, table.concat(printed, '\n')).to_equal({})
  expect(register).to_be_truthy()
  expect(expiry, 'the startup expiry did not run').to_be_truthy()
  expect(expiry > register).to_be(true)
end)

-- The expiry is cleanup: a failure of its transaction (begin, a DELETE or the commit) is logged, and
-- the plugin start completes (coordinator ruling, 2026-10-22).
local faults = {
  begin = function(action) return action == 'hub.sql.begin' end,
  delete = function(action, sql) return action == 'hub.sql.exec' and sql:match('^DELETE FROM drafts') ~= nil end,
  commit = function(action) return action == 'hub.sql.commit' end,
}
for _, name in ipairs({'begin', 'delete', 'commit'}) do
  test('a failed startup expiry (' .. name .. ') is logged, and the plugin start completes', function()
    local calls, refused, printed, failed = start({fail = faults[name]})
    local log = table.concat(printed, '\n')
    expect(refused, log).to_equal({})
    expect(first(calls, 'hub.register')).to_be_truthy()
    expect(log:find('os.exit', 1, true), log).to_be(nil)
    expect(log:find('the start of profiles failed', 1, true), log).to_be(nil)
    expect(log).to_match('lazyrex: timer failed: disk I/O error')
    -- The fault fired, so the expiry ran in the timer that the start function made.
    expect(#failed > 0, log).to_be(true)
  end)
end
