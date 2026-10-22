-- The Start form on the real hub's view path: its tree, its draft, the Directory field's text,
-- draft expiry and a broken profile file. The pending start tests are in pending.lua.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
local alice = agent('alice')

local function values(over)
  local v = {dir = '', profile = 'logtail', title = '', placement = 'tab'}
  for k, x in pairs(over or {}) do v[k] = x end
  return v
end
local function succeeded(op)
  if op.status ~= 'succeeded' or op.effects == 'failed' then error('the operation did not succeed: ' .. show(op), 2) end
  return op
end
-- start_text submits the Directory field text from a new form and returns the hub's worker, or the
-- failed operation.
local src = F.source()
local function start_text(text)
  local v = F.form(src, 'start_accessory')
  local before = F.ids(alice)
  local op = v:action('start', 'start', {values = values({dir = text})})
  if op.status ~= 'succeeded' then return nil, op end
  return F.new_worker(alice, before)
end

test('shared arg fields start empty with every label; the Directory field offers the native browser', function()
  local v, tree = F.form(src, 'start_agent')
  local task = F.field(tree, 'arg/task')
  expect({task.value, task.kind}).to_equal({'', 'multiline'})
  expect(task.label).to_be("Task / Goal (empty: the profile's default)")
  local dir = F.field(tree, 'dir')
  expect({dir.value, dir.browse, dir.kind, dir.rev}).to_equal({F.sub, 'native', 'text', 0})
  -- A render only reads: the hub froze the source directory when it opened the form.
  expect(F.draft(v.id)).to_be(nil)
  local offered = {}
  for _, o in ipairs(F.field(tree, 'profile').options) do offered[#offered + 1] = o.value end
  expect(offered).to_equal({'fake_agent', 'beta'})
  expect(node(tree, 'cancel').action.name).to_be('$cancel')
  expect(v:get().status).to_equal({state = 'blocked', kind = 'question', msg = 'Waiting for input'})
end)

test('the first render freezes the source directory; an empty field starts there', function()
  local s = F.source()
  local v, tree = F.form(s, 'start_accessory')
  expect(F.field(tree, 'dir').value).to_be(F.sub)
  F.cd(s, F.deeper)
  tree = v:render()
  expect(F.field(tree, 'dir').value).to_be(F.sub)
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = values({dir = ''})}))
  expect(F.new_worker(alice, before).cwd).to_be(F.sub)
  -- A new form reads the source pane again.
  local _, again = F.form(s, 'start_accessory')
  expect(F.field(again, 'dir').value).to_be(F.deeper)
end)

test('a source pane that reports no directory: the form says why, and each profile uses its own', function()
  local s = F.source(nil, true)
  local v, tree = F.form(s, 'start_accessory')
  expect(node(tree, 'directory_note').text).to_match('no directory')
  local dir = F.field(tree, 'dir')
  expect({dir.value, dir.label}).to_equal({'', "Directory (empty: each profile's own directory)"})
  expect(node(tree, 'dir_choices')).to_be(nil)
  expect(F.draft(v.id)).to_be(nil)
end)

test('an ordinary render keeps the rev; each explicit choice increments it', function()
  local v, tree = F.form(src, 'start_accessory')
  expect(F.field(v:render(), 'dir').rev).to_be(0)
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}))
  succeeded(v:action('dir_choices', 'choose', {item_id = 'tree:' .. F.wt}))
  tree = v:render()
  expect({F.field(tree, 'dir').value, F.field(tree, 'dir').rev}).to_equal({F.wt, 2})
  -- A replay of a choice (the same operation key) changes nothing again.
  local d = F.draft(v.id)
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}, 'choice-replay'))
  local d1 = F.draft(v.id)
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}, 'choice-replay'))
  expect(F.draft(v.id)).to_equal(d1)
  expect(d1.dir_rev).to_be(d.dir_rev + 1)
end)

test('the Directory field text is data: escapes, ~, trailing slashes, quotes; no trim, no shell', function()
  local base = F.root .. '/n'
  -- A missing directory names the decoded path in the hub's refusal, so most cases need no folder.
  -- The plugin expands ~ with its HOME as text; the hub records an existing cwd as a physical path.
  local function decoded(text)
    local w, op = start_text(text)
    if w then return w.cwd end
    local m = op.error and op.error.message or ''
    return m:match('^(.*) is not an existing directory$') or m:match('^test mode: cwd "(.*)" is outside the lab and plugin directories$') or show(op)
  end
  local cases = {
    {'~/Projects/', os.getenv('HOME') .. '/Projects'}, {'~', F.home}, {'/', '/'}, {base .. '/a/b//', base .. '/a/b'},
    {'~/Calibre\\ Library/', os.getenv('HOME') .. '/Calibre Library'}, {base .. '/ lead and trail ', base .. '/ lead and trail '},
    {base .. '/\\ /', base .. '/ '}, {base .. '/a\\\\b', base .. '/a\\b'}, {base .. "/it's", base .. "/it's"},
    {"'" .. base .. "/quoted dir/'", base .. '/quoted dir'}, {base .. '/new\nline', base .. '/new\nline'}, {'', F.sub}}
  for _, c in ipairs(cases) do expect(decoded(c[1]), c[1]).to_be(c[2]) end
  for _, bad in ipairs({{'relative/path', 'must be an absolute path'}, {base .. '/trailing\\', 'lone backslash'}, {'~user/x', 'must be an absolute path'}}) do
    local w, op = start_text(bad[1])
    expect(w, bad[1]).to_be(nil)
    expect(op.error.code).to_be('invalid_input')
    expect(op.error.message).to_match(bad[2])
  end
end)

-- Rex Lua table.concat fails with "registry overflow" above 2559 items (LazyRex docs/rex-protocol.md,
-- observed on Rex 0.0.1792158932-g88fd41). The decoder must not join one item per character.
test('a Directory field text of 4500 characters decodes', function()
  local base = F.root .. '/n/'
  local w, op = start_text(base .. string.rep('a\\ ', 1500))
  expect(w).to_be(nil)
  -- The hub refuses the decoded path (3000 characters after the base), and its message names it.
  expect(op.error.code, op.error.message:sub(1, 160)).to_be('refused')
  expect(op.error.message:find(base .. string.rep('a ', 1500), 1, true) ~= nil, op.error.message:sub(1, 120)).to_be(true)
end)

test('a raw path with a backslash and a space round-trips through the field', function()
  local raw = F.root .. '/back\\slash and space'
  F.mkdir(raw)
  local s = F.source(raw)
  local v, tree = F.form(s, 'start_accessory')
  local text = F.field(tree, 'dir').value
  expect(text).to_be((raw:gsub('\\', '\\\\')))
  expect(F.field(v:render(), 'dir').value).to_be(text)
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = values({dir = text})}))
  expect(F.new_worker(alice, before).cwd).to_be(raw)
end)

test('an unknown action is refused', function()
  local v = F.form(src, 'start_accessory')
  local op = v:action('dir_choices', 'unknown', {item_id = 'x'})
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('Unknown action')
end)

test('a broken profile file shows its error; a kind with no profiles says so', function()
  write_profiles('{"profiles": [')
  local v, tree = F.form(src, 'start_agent')
  expect(node(tree, 'profiles_error').text).to_match('^Profiles could not be loaded: ')
  expect(node(tree, 'start')).to_be(nil)
  expect(node(tree, 'cancel').action.name).to_be('$cancel')
  write_profiles({profiles = {F.profiles.profiles[3]}})
  tree = v:render()
  expect(node(tree, 'no_profiles').text).to_be('No agent profiles are configured.')
  expect(node(tree, 'start')).to_be(nil)
  write_profiles(F.profiles)
  expect(node(v:render(), 'start')).to_be_truthy()
end)

-- stale writes a draft that is two days old, as a form that never ended leaves it.
local function stale(id) sql_write('INSERT INTO drafts (view_id, at, dir) VALUES (?, ?, ?)', {id, os.time() - 2 * 24 * 3600, F.sub}) end

test('a draft whose form never ended expires after a day, when the plugin starts', function()
  stale('stale-view')
  sql_write('INSERT INTO drafts (view_id, at, dir) VALUES (?, ?, ?)', {'fresh-view', os.time() - 3600, F.sub})
  hub:restart()
  wait('the stale draft expires at start', function() return F.draft('stale-view') == nil end, 15)
  expect(F.draft('fresh-view')).to_be_truthy()
end)

local function columns()
  local list = {}
  for _, c in ipairs(sql("SELECT name FROM pragma_table_info('drafts')")) do list[#list + 1] = c.name end
  return table.concat(list, ',')
end
local current = 'view_id,at,dir,dir_rev,error,dismissed,saved_values,pending_key,pending_profile,pending_spawn_id'

test('a fresh database has schema 2; a version-1 database upgrades and keeps its rows', function()
  expect(sql('PRAGMA user_version')[1].user_version).to_be(2)
  expect(columns()).to_be(current)
  -- A version-1 database with a draft and a start, as the live plugin left it.
  for _, statement in ipairs({'DROP TABLE drafts',
    'CREATE TABLE drafts (view_id TEXT PRIMARY KEY, at INTEGER NOT NULL, dir TEXT, dir_source TEXT, dir_rev INTEGER NOT NULL DEFAULT 0, ' ..
      'error TEXT, dismissed TEXT, saved_values TEXT, pending_key TEXT, pending_profile TEXT, pending_spawn_id TEXT)',
    'CREATE INDEX drafts_at ON drafts (at)', 'PRAGMA user_version = 1'}) do sql_write(statement) end
  sql_write('INSERT INTO drafts (view_id, at, dir, dir_source, dir_rev, error, saved_values, pending_key, pending_profile, pending_spawn_id) ' ..
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {'v1-view', os.time(), F.wt, 'worktree', 2, 'it failed', '{"title":"Mine"}', 'v1-key', 'logtail', 'spawn-1'})
  sql_write('INSERT INTO starts (op_key, view_id, at, request) VALUES (?, ?, ?, ?)', {'v1-key', 'v1-view', os.time(), '{"profile":"logtail"}'})
  hub:restart()
  -- The SDK runs the migrations after the plugin registers, so hub:restart can return first.
  wait('the upgrade', function() return sql('PRAGMA user_version')[1].user_version == 2 end, 15)
  expect(columns()).to_be(current)
  local d = F.draft('v1-view')
  expect({d.dir, d.dir_rev, d.error, d.saved_values, d.pending_key, d.pending_profile, d.pending_spawn_id})
    .to_equal({F.wt, 2, 'it failed', '{"title":"Mine"}', 'v1-key', 'logtail', 'spawn-1'})
  expect(sql('SELECT request FROM starts WHERE op_key = ?', {'v1-key'})[1].request).to_be('{"profile":"logtail"}')
end)

test('an explicit title reaches the worker, the same as an agent title', function()
  local v = F.form(src, 'start_accessory')
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = values({dir = F.sub, title = 'Mine'})}))
  local ui = F.new_worker(alice, before)
  before = F.ids(alice)
  alice:call('hub.spawn', {profile = 'logtail', cwd = F.sub, title = 'Mine', placement = {session = src.session}, key = 'title-1'})
  local tool = F.new_worker(alice, before)
  expect(F.same(ui)).to_equal(F.same(tool))
  expect(ui.title).to_be('Mine')
end)

test('after a failed start, a directory choice replaces only the directory in the saved values', function()
  local v = F.form(src, 'start_agent')
  fault({point = 'spawn-create', mode = 'refuse', op = 'profiles-start/saved-values'})
  local submitted = {dir = F.deeper, profile = 'beta', ['arg/task'] = 'explicit', title = 'Mine', placement = 'split'}
  succeeded(v:action('start', 'start', {values = submitted}, 'saved-values'))
  local function shown(t)
    local out = {}
    for _, f in ipairs(node(t, 'start').fields) do out[f.id] = f.value end
    return out
  end
  expect(shown(v:render())).to_equal(submitted)
  succeeded(v:action('dir_choices', 'choose', {item_id = 'tree:' .. F.wt}))
  expect(shown(v:render())).to_equal({dir = F.wt, profile = 'beta', ['arg/task'] = 'explicit', title = 'Mine', placement = 'split'})
end)
