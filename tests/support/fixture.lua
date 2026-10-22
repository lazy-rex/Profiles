-- Shared lab fixture for the Profiles tests (not a test file: the harness runs only tests/*.lua).
-- Load it with assert(loadfile(...))()(H). It returns a table of helpers and paths.
-- Everything lives in the lab directory. Profile commands are harmless shell lines that write one
-- record line to a file in the lab and then sleep.
return function(H)
  local F = {}
  F.plugin_dir = H.args.file:match('^(.*)/tests/[^/]*$')
  local git_env = {GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false, GIT_INDEX_FILE = false,
    GIT_CONFIG_COUNT = false, GIT_CONFIG_PARAMETERS = false}
  function F.run(argv, env)
    local r, err = rex.exec(argv, {env = env or git_env, timeout = 20})
    if not r then error('exec ' .. argv[1] .. ': ' .. tostring(err), 0) end
    if not r.ok then error(table.concat(argv, ' ') .. ': ' .. tostring(r.stderr), 0) end
    return r.stdout
  end
  function F.mkdir(path) F.run({'mkdir', '-p', path}) end
  -- real is the physical path (/tmp is /private/tmp on macOS), as the hub records a cwd.
  function F.real(path) return (F.run({'/bin/sh', '-c', 'cd "$1" && pwd -P', 'sh', path}):gsub('\n$', '')) end

  F.mkdir(H.args.lab .. '/fx')
  F.root = F.real(H.args.lab .. '/fx')
  F.home = F.real(os.getenv('HOME'))
  -- A Git repository on main with the folders sub/deeper, and a linked worktree on feature.
  F.repo, F.wt = F.root .. '/repo', F.root .. '/repo-wt'
  F.sub, F.deeper = F.repo .. '/sub', F.repo .. '/sub/deeper'
  F.mkdir(F.deeper)
  F.run({'git', 'init', '-q', '-b', 'main', F.repo})
  F.run({'git', '-C', F.repo, '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Fixture'})
  F.run({'git', '-C', F.repo, 'worktree', 'add', '-q', '-b', 'feature', F.wt})

  -- Each started profile appends "<kind>|<LAZYREX_AGENT>|<task>|<physical cwd>" to F.out.
  F.out = F.root .. '/out.log'
  local record = 'printf "%s|%s|%s|%s\\n" "$1" "$LAZYREX_AGENT" "$2" "$(pwd -P)" >> "$0"; exec sleep 100000'
  F.profiles = {profiles = {
    {id = 'fake_agent', name = 'Fake Agent', kind = 'agent', cwd = F.repo,
      command = {'/bin/sh', '-c', record, F.out, 'agent', '${task}'}, args = {{name = 'task', label = 'Task', default = 'alpha default'}}},
    {id = 'beta', name = 'Beta', kind = 'agent', cwd = F.repo,
      command = {'/bin/sh', '-c', record, F.out, 'beta', '${task}'}, args = {{name = 'task', label = 'Goal', default = 'beta default'}}},
    {id = 'logtail', name = 'Log tail', kind = 'accessory',
      command = {'/bin/sh', '-c', record, F.out, 'logtail', ''}}}}
  H.write_profiles(F.profiles)

  -- lines returns the records in F.out.
  function F.lines()
    local f = io.open(F.out, 'r')
    if not f then return {} end
    local list = {}
    for line in f:lines() do
      local kind, agent, task, cwd = line:match('^([^|]*)|([^|]*)|([^|]*)|(.*)$')
      list[#list + 1] = {kind = kind, agent = agent, task = task, cwd = cwd}
    end
    f:close()
    return list
  end
  -- record waits for the record line of an agent spawn (by its agent ID).
  function F.record(agent_id)
    return H.wait('the record of ' .. agent_id, function()
      for _, r in ipairs(F.lines()) do if r.agent == agent_id then return r end end
      return nil
    end, 15)
  end

  -- source makes a session whose one pane reports a directory with OSC 7. The pane reads paths on
  -- its input and reports each one, so F.cd changes the reported directory later. quiet = true: the
  -- pane reports no directory.
  local n = 0
  function F.source(dir, quiet)
    n = n + 1
    local script = quiet and 'exec sleep 100000' or 'stty -echo; report() { printf "\\033]7;file://localhost%s\\007" "$1"; }; report "$0"; while read -r p; do report "$p"; done'
    local s, err = rex.call('session.create', {label = 'profiles-source-' .. n, initial_windows = {{window_label = 'src',
      layout = {block = {flavor = 'com.superlogical.terminal.shell', label = 'src', options = {command = {'/bin/sh', '-c', script, dir or F.sub}, login = false}}}}}})
    if not s then error('session.create: ' .. H.show(err), 0) end
    rex.call('session.attach', {session_id = s.session_id, event_scope = 'session'})
    local src = {session = s.session_id, window = s.initial_windows[1].window_id, block = s.initial_windows[1].block_ids[1]}
    if not quiet then F.wait_pwd(src, dir or F.sub) end
    return src
  end
  function F.wait_pwd(src, dir)
    H.wait('the source pane reports ' .. dir, function()
      local r = rex.call('com.superlogical.terminal.pwd', {session_id = src.session, block_id = src.block, args = {}})
      return r and r.pwd == 'file://localhost' .. dir
    end, 10)
  end
  function F.cd(src, dir)
    rex.call('com.superlogical.terminal.write', {session_id = src.session, block_id = src.block, args = {data = dir .. '\n'}})
    F.wait_pwd(src, dir)
  end

  -- form runs a palette command from the source pane and returns the form view, rendered.
  local routes = {start_agent = '/forms/start-agent', start_accessory = '/forms/start-accessory'}
  function F.form(src, command)
    H.user:command(command, {session = src.session, block = src.block})
    local v = H.user:view(routes[command], nil, src.session)
    return v, v:render()
  end
  function F.field(tree, id)
    for _, f in ipairs(H.node(tree, 'start').fields) do if f.id == id then return f end end
    return nil
  end

  -- blocks lists the placed blocks of a session: {block_id, label, window_id}.
  function F.blocks(session)
    local view = rex.call('session.view', {session_id = session})
    local list = {}
    for _, w in ipairs(view.windows or {}) do
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do list[#list + 1] = {block_id = b.block_id, label = b.label, window_id = w.window_id, window_label = w.label} end
      end
    end
    return list, view
  end
  function F.spawn_blocks(session, spawn_id)
    local found = {}
    for _, b in ipairs(F.blocks(session)) do if b.label == 'lazyrex-spawn:' .. spawn_id then found[#found + 1] = b end end
    return found
  end
  -- worker returns the hub's worker entry of a spawn (hub.workers, as an agent sees it).
  function F.worker(as, spawn_id)
    for _, w in ipairs(as:call('hub.workers', {}).workers or {}) do if w.spawn_id == spawn_id then return w end end
    return nil
  end
  -- new_worker returns the one worker that is not in before (a set of spawn IDs).
  function F.ids(as)
    local set = {}
    for _, w in ipairs(as:call('hub.workers', {}).workers or {}) do set[w.spawn_id] = true end
    return set
  end
  function F.new_worker(as, before)
    local found
    for _, w in ipairs(as:call('hub.workers', {}).workers or {}) do
      if not before[w.spawn_id] then
        if found then error('more than one new worker', 0) end
        found = w
      end
    end
    if not found then error('no new worker', 0) end
    return found
  end
  -- draft returns the form's draft row (the plugin's SQL table drafts), or nil.
  function F.draft(view_id) return H.sql('SELECT * FROM drafts WHERE view_id = ?', {view_id})[1] end
  -- same keeps the fields that a UI start and an agent start must share.
  function F.same(w) return {profile = w.profile, cwd = w.cwd, session_id = w.session_id, title = w.title} end
  return F
end
