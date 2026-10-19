-- Ported from the Node test profiles-directories-lab.mjs: the directory helper
-- (profiles_directories.lua) in Rex Lua, with a real source pane (OSC 7), real terminal.pwd and
-- real Git worktrees. The runner loads the helper as the plugin does: loadfile by absolute path.

local plugin_dir = H.args.file:match('^(.*)/tests/[^/]*$')
local dirs = assert(loadfile(plugin_dir .. '/profiles_directories.lua'))()
local root = H.args.lab .. '/directories'

-- Git without the variables that the helper also clears: the fixture must not depend on them.
local git_env = {GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false, GIT_INDEX_FILE = false,
  GIT_CONFIG_COUNT = false, GIT_CONFIG_PARAMETERS = false}
local function run(argv, env)
  local r, err = rex.exec(argv, {env = env or git_env, timeout = 20})
  if not r then error('exec ' .. argv[1] .. ': ' .. tostring(err), 0) end
  if not r.ok then error(table.concat(argv, ' ') .. ': ' .. tostring(r.stderr), 0) end
  return r.stdout
end
local function git(...) return run({'git', ...}) end
local function mkdir(path) run({'mkdir', '-p', path}) end
-- real is the physical path (/tmp is /private/tmp on macOS), as Git reports it.
local function real(path) return (run({'/bin/sh', '-c', 'cd "$1" && pwd -P', 'sh', path}):gsub('\n$', '')) end
-- file_uri percent-encodes a path the way a shell's OSC 7 report does (Node pathToFileURL).
local function file_uri(host, path)
  return 'file://' .. host .. path:gsub('[^%w/%-%._~]', function(c) return string.format('%%%02X', c:byte()) end)
end

mkdir(root)
local source = real(root) .. '/source + %20 ü'
mkdir(source)

-- A source pane that reports its directory with OSC 7, in its own session.
local osc = '\27]7;' .. file_uri('', source) .. '\7'
local created, err = rex.call('session.create', {label = 'profiles-directories', initial_windows = {{layout = {block = {
  flavor = 'com.superlogical.terminal.shell', options = {command = {'/bin/sh', '-c', 'printf "%s" "$1"; exec sleep 100000', 'sh', osc},
  login = false, cwd = source}}}}}})
if not created then error('session.create: ' .. show(err), 0) end
local context = {session_id = created.session_id, source_block_id = created.initial_windows[1].block_ids[1]}
rex.call('session.attach', {session_id = context.session_id, event_scope = 'session'})
wait('the source pane reports its directory', function()
  local r = rex.call('com.superlogical.terminal.pwd', {session_id = context.session_id, block_id = context.source_block_id, args = {}})
  return r and r.pwd and r.pwd ~= ''
end)

-- with_pwd runs fn while terminal.pwd answers report (the pane's report is fixed).
local function with_pwd(report, fn)
  local call = rex.call
  rex.call = function(method, args)
    if method == 'com.superlogical.terminal.pwd' then return {pwd = report} end
    return call(method, args)
  end
  local ok, result = pcall(fn)
  rex.call = call
  if not ok then error(result, 0) end
  return result
end

test('the source directory: OSC 7 from a foreign session, percent decoding exactly once', function()
  expect(dirs.source_directory(context, '/unused')).to_equal({path = source, source = 'pwd'})
end)

test('local hostname and localhost file URIs', function()
  local host = run({'hostname'}):gsub('[\r\n]+$', '')
  for _, h in ipairs({host, 'localhost'}) do
    expect(with_pwd(file_uri(h, source), function() return dirs.source_directory(context, nil) end).path).to_be(source)
  end
end)

test('missing, remote, malformed and NUL reports use the explicit profile fallback', function()
  for _, report in ipairs({'', 'file://remote.invalid/tmp', 'file:///bad%xx', 'file:///bad%00', 'file:///tmp?query'}) do
    expect(with_pwd(report, function() return dirs.source_directory(context, source) end), report).to_equal({path = source, source = 'profile'})
  end
  expect(dirs.source_directory({}, nil)).to_be(nil)
end)

test('a stale source block fails instead of silently changing directory', function()
  expect_error(function()
    dirs.source_directory({session_id = context.session_id, source_block_id = 'block:missing'}, source)
  end)
end)

local base = real(root)
local repo, linked, detached = base .. '/repo + space', base .. '/linked\nworktree', base .. '/detached % tree'
git('init', '-q', '-b', 'main', repo)
git('-C', repo, '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Fixture')
git('-C', repo, 'worktree', 'add', '-q', '-b', 'feature', linked)
git('-C', repo, 'worktree', 'add', '-q', '--detach', detached)
mkdir(linked .. '/subdir')

local function by_path(list)
  table.sort(list, function(a, b) return a.path < b.path end)
  return list
end

test('worktrees: newline paths, branches, detached state and the current root', function()
  local trees = dirs.worktrees(linked .. '/subdir')
  expect(trees.repo).to_be(repo)
  expect(trees.current).to_be(linked)
  expect(by_path(trees.list)).to_equal(by_path({
    {path = repo, branch = 'main', detached = false},
    {path = detached, detached = true},
    {path = linked, branch = 'feature', detached = false}}))
end)

test('worktrees ignore inherited Git overrides', function()
  -- A child rex do with the overrides in its environment, as an agent's shell could have them.
  local script = root .. '/inherited.lua'
  local f = assert(io.open(script, 'w'))
  f:write('local dirs = assert(loadfile(rex.args.helper))()\n',
    'print(dirs.worktrees(rex.args.path).current)\n')
  f:close()
  local out = run({'rex', '-S', 'unix://' .. H.args.lab .. '/rex.sock', '--autostart=false', 'do', script, '-s', H.args.tests_session,
    'helper=' .. plugin_dir .. '/profiles_directories.lua', 'path=' .. repo},
    {GIT_DIR = root .. '/missing', GIT_WORK_TREE = root .. '/missing', GIT_CONFIG_COUNT = '1',
      GIT_CONFIG_KEY_0 = 'core.bare', GIT_CONFIG_VALUE_0 = 'true'})
  expect(out).to_be(repo .. '\n')
end)

test('a folder outside Git has no worktrees; invalid directories are errors', function()
  expect(dirs.worktrees(source)).to_be(nil)
  expect_error(function() dirs.worktrees(base .. '/missing') end)
  expect_error(function() dirs.worktrees('relative') end, 'invalid_input')
end)

test('a bare root is not a worktree; the linked worktrees of a bare repository are', function()
  local bare, tree = base .. '/bare.git', base .. '/bare-tree'
  git('clone', '-q', '--bare', repo, bare)
  git('-C', bare, 'worktree', 'add', '-q', tree, 'main')
  expect(dirs.worktrees(bare)).to_be(nil)
  local trees = dirs.worktrees(tree)
  expect(trees.repo).to_be(bare)
  expect(trees.list).to_equal({{path = tree, branch = 'main', detached = false}})
end)
