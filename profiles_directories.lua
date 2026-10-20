-- Read-only directory helpers for the Profiles form. Load this file by absolute path.
-- Rex owns directory resolution. Git owns the worktree list. No helper changes either.
local M = {}
local function fail(code, message) error({code = code, message = message}) end
local function text(value, name)
  if type(value) ~= 'string' or value:find('%z') then
    fail('invalid_input', name .. ' must be text without NUL')
  end
  return value
end
local function block_call(context, method, args)
  if type(context) ~= 'table' or type(context.session_id) ~= 'string' or context.session_id == ''
    or type(context.source_block_id) ~= 'string' or context.source_block_id == '' then
    fail('source_unavailable', 'The source pane is unavailable. Open Start from a terminal pane.')
  end
  -- A Lua plugin can use this source session even when its own pane is in another session.
  local attached, err = rex.call('session.attach', {session_id = context.session_id, event_scope = 'session'})
  if not attached then
    fail(type(err) == 'table' and err.code or 'unavailable',
      type(err) == 'table' and err.message or tostring(err or 'Could not attach the source session'))
  end
  local result, call_error = rex.call('com.superlogical.terminal.' .. method,
    {session_id = context.session_id, block_id = context.source_block_id, args = args or {}})
  if type(result) ~= 'table' then
    fail(type(call_error) == 'table' and call_error.code or 'unavailable',
      type(call_error) == 'table' and call_error.message or tostring(call_error or 'Could not read the source pane'))
  end
  return result
end

local hostname
local function local_host(host)
  host = host:lower()
  if host == '' or host == 'localhost' then return true end
  if hostname == nil then
    local result = rex.exec({'hostname'}, {timeout = 5})
    hostname = result and result.ok and result.stdout:gsub('[\r\n]+$', ''):lower() or ''
  end
  return hostname ~= '' and host == hostname
end
local function pwd_path(uri)
  if type(uri) ~= 'string' then return nil end
  local host, path = uri:match('^file://([^/]*)(/.*)$')
  if not host or not local_host(host) or path:find('[?#]') then return nil end
  -- Decode once. A literal plus is a plus, and %2520 names the literal text %20.
  if path:gsub('%%[%da-fA-F][%da-fA-F]', ''):find('%%') then return nil end
  path = path:gsub('%%([%da-fA-F][%da-fA-F])', function(hex) return string.char(tonumber(hex, 16)) end)
  if path:find('%z') then return nil end
  return path
end

-- No source report: use the selected profile's cwd. Nil leaves the default to hub.spawn.
-- An RPC failure is an error, not permission to silently choose a different directory.
function M.source_directory(context, profile_cwd)
  if type(context) == 'table' and type(context.source_block_id) == 'string' and context.source_block_id ~= '' then
    local path = pwd_path(block_call(context, 'pwd').pwd)
    if path then return {path = path, source = 'pwd'} end
  end
  if profile_cwd ~= nil and profile_cwd ~= '' then
    text(profile_cwd, 'Profile directory')
    if profile_cwd:sub(1, 1) ~= '/' then fail('invalid_input', 'Profile directory must be absolute') end
    return {path = profile_cwd, source = 'profile'}
  end
  return nil
end

-- Do not inherit a surrounding agent's Git repository or injected Git configuration.
local git_env = {GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false,
  GIT_INDEX_FILE = false, GIT_CONFIG_COUNT = false, GIT_CONFIG_PARAMETERS = false, LC_ALL = 'C'}
local function git(path, args)
  local argv = {'git', '-C', path}
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  local result, err = rex.exec(argv, {env = git_env, timeout = 5})
  if not result then fail('unavailable', tostring(err or 'Git did not start')) end
  if result.timed_out then fail('unavailable', 'Git directory lookup timed out. Try again.') end
  return result
end
local function git_ok(path, args)
  local result = git(path, args)
  if not result.ok then fail('git_error', result.stderr ~= '' and result.stderr or 'Git lookup failed') end
  return result.stdout
end

function M.worktrees(path)
  text(path, 'Directory')
  if path:sub(1, 1) ~= '/' then fail('invalid_input', 'Directory must be absolute') end
  local inside = git(path, {'rev-parse', '--is-inside-work-tree'})
  if not inside.ok then
    if inside.stderr:find('not a git repository', 1, true) then return nil end
    fail('git_error', inside.stderr ~= '' and inside.stderr or 'Git lookup failed')
  end
  if inside.stdout ~= 'true\n' then return nil end
  -- Remove exactly the output terminator. Newlines inside a directory name are valid.
  local current = git_ok(path, {'rev-parse', '--show-toplevel'}):gsub('\n$', '')
  local raw = git_ok(path, {'worktree', 'list', '--porcelain', '-z'})
  local rows, row, repo = {}, nil, nil
  -- finish takes row as an argument and writes no captured local. Rex Lua can lose a closure's
  -- write to a captured local after a pcall catches (observed on Rex 0.0.1792158932-g88fd41).
  local function finish(r)
    if r and not r.bare then rows[#rows + 1] = r end
  end
  for field in raw:gmatch('([^%z]*)%z') do
    if field == '' then finish(row); row = nil
    elseif field:sub(1, 9) == 'worktree ' then
      finish(row)
      row = {path = field:sub(10), detached = false}
      repo = repo or row.path
    elseif row and field:sub(1, 7) == 'branch ' then row.branch = field:sub(8):gsub('^refs/heads/', '')
    elseif row and field == 'detached' then row.detached = true
    elseif row and field == 'bare' then row.bare = true end
  end
  finish(row)
  return {repo = repo, current = current, list = rows}
end

return M
