-- Ported from the Node test profiles-plugin.mjs (the parts without a pending start): the Start
-- form's tree, its draft, the Directory field's text, old drafts and a broken profile file, on
-- the real hub's view path. The pending start tests need the hub's spawn-create fault point.
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
  expect(store('draft/' .. v.id).value.dir).to_be(F.sub)
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

test('an ordinary render keeps the rev; each explicit choice increments it', function()
  local v, tree = F.form(src, 'start_accessory')
  expect(F.field(v:render(), 'dir').rev).to_be(0)
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}))
  succeeded(v:action('dir_choices', 'choose', {item_id = 'tree:' .. F.wt}))
  tree = v:render()
  expect({F.field(tree, 'dir').value, F.field(tree, 'dir').rev}).to_equal({F.wt, 2})
  -- A replay of a choice (the same operation key) changes nothing again.
  local d = store('draft/' .. v.id)
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}, 'choice-replay'))
  local d1 = store('draft/' .. v.id)
  succeeded(v:action('dir_choices', 'default', {item_id = 'default'}, 'choice-replay'))
  expect(store('draft/' .. v.id).rev).to_be(d1.rev)
  expect(d1.rev).not_to_be(d.rev)
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

test('a draft from the older in-form browser still loads; its browser actions are refused', function()
  local v, tree = F.form(src, 'start_accessory')
  local d = store('draft/' .. v.id)
  local old = d.value
  old.browse, old.prefix = F.sub .. '/deeper', 'de'
  write({{key = 'draft/' .. v.id, value = old}})
  tree = v:render()
  local ids = {}
  for _, i in ipairs(node(tree, 'dir_choices').items) do if i.id:sub(1, 5) ~= 'tree:' then ids[#ids + 1] = i.id end end
  expect(ids).to_equal({'default'})
  for _, id in ipairs({'browse', 'browse_error', 'browse_more', 'filter'}) do expect(node(tree, id), id).to_be(nil) end
  expect({F.field(tree, 'dir').value, F.field(tree, 'dir').rev}).to_equal({F.sub, 0})
  for _, a in ipairs({{'dir_choices', 'browse', 'browse'}, {'browse', 'use', 'use'}, {'browse', 'open', 'up'}, {'filter', 'filter', ''}}) do
    local op = v:action(a[1], a[2], {item_id = a[3]})
    expect(op.status, a[1] .. ' ' .. a[2]).to_be('failed')
    expect(op.error.message).to_match('Unknown action')
  end
  local before = F.ids(alice)
  succeeded(v:action('start', 'start', {values = values({dir = F.field(tree, 'dir').value})}))
  expect(F.new_worker(alice, before).cwd).to_be(F.sub)
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

test('the plugin expires old drafts when it starts, after its main chunk', function()
  write({{key = 'draft/stale-at-start', value = {at = os.time() - 2 * 24 * 3600, dir = F.sub}}})
  hub:restart()
  wait('the stale draft expires at start', function() return store('draft/stale-at-start').rev == '0' end, 15)
end)

test('a draft whose form never ended expires after a day', function()
  write({{key = 'draft/stale-view', value = {at = os.time() - 2 * 24 * 3600, dir = F.sub}},
    {key = 'draft/fresh-view', value = {at = os.time() - 3600, dir = F.sub}}})
  F.form(src, 'start_accessory') -- a first render writes a draft and expires old ones
  expect(store('draft/stale-view').rev).to_be('0')
  expect(store('draft/fresh-view').rev).not_to_be('0')
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
