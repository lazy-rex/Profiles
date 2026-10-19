// Start an isolated server first: spikes/lab/server.sh /tmp/rexlab-profiles-codex
// Run: node spikes/03-ui-framework/tests/profiles-directories-lab.mjs
// This tests the helper in Rex Lua with real terminal methods and real Git worktrees.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';

const lab = process.env.PROFILES_LAB || '/tmp/rexlab-profiles-codex';
assert.match(lab, /^\/(?:private\/)?tmp\/rexlab-profiles-[^/]+$/, 'Use an isolated Profiles lab');
const socket = `unix://${lab}/rex.sock`;
const helper = fileURLToPath(new URL('../../Profiles/profiles_directories.lua', import.meta.url));
const fixture = fs.mkdtempSync(`${lab}/directories-`);
const env = {...process.env, REX_SERVER: socket};
for (const key of ['REX_SESSION', 'REX_BLOCK', 'REX_CLIENT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR',
  'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS']) delete env[key];
const rex = (...args) => execFileSync('rex', ['-S', socket, '--autostart=false', ...args], {env, encoding: 'utf8'});
const version = JSON.parse(rex('whoami', '--json')).rex_version;
const control = await connectControl(`${lab}/rex.sock`);
let session;
let runnerSession;
let passed = 0;
const check = (name, fn) => { fn(); passed++; console.log(`PASS ${name}`); };
const git = (...args) => execFileSync('git', args, {env, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe']});
const lua = `${fixture}/runner.lua`;
fs.writeFileSync(lua, `
local request = rex.json.decode(assert(io.open(rex.args.request)):read('*a'))
local dirs = assert(loadfile(request.helper))()
if request.mock_pwd ~= nil then
  local call = rex.call
  rex.call = function(method, args)
    if method == 'com.superlogical.terminal.pwd' then return {pwd = request.mock_pwd} end
    return call(method, args)
  end
end
local ok, result = pcall(function()
  if request.method == 'source_directory' then return dirs.source_directory(request.context, request.profile_cwd) end
  if request.method == 'worktrees' then return dirs.worktrees(request.path) end
  error('Unknown test method')
end)
print(rex.json.encode({ok = ok, result = result, absent = result == nil}))
`);
try {
  const source = `${fixture}/source + %20 ü`;
  fs.mkdirSync(source);
  const script = `process.stdout.write(${JSON.stringify(`\x1b]7;${pathToFileURL(source).href}\x07`)}); setInterval(() => {}, 1000);`;
  const created = await control.call('session.create', {label: 'profiles-directories-test', initial_windows: [{layout: {
    block: {flavor: 'com.superlogical.terminal.shell', options: {command: [process.execPath, '-e', script], login: false, cwd: source}}
  }}]});
  session = created.session_id;
  runnerSession = (await control.call('session.create', {label: 'profiles-helper-caller'})).session_id;
  await control.call('session.attach', {session_id: runnerSession, event_scope: 'session'});
  await control.call('session.attach', {session_id: session, event_scope: 'session'});
  const block = created.initial_windows[0].block_ids[0];
  const context = {session_id: session, source_block_id: block};
  const requestFile = `${fixture}/request.json`;
  function invoke(method, args = {}, extraEnv = {}) {
    fs.writeFileSync(requestFile, JSON.stringify({helper, method, context, ...args}));
    return JSON.parse(execFileSync('rex', ['-S', socket, '--autostart=false', 'do', lua, '-s', runnerSession, `request=${requestFile}`],
      {env: {...env, ...extraEnv}, encoding: 'utf8'}));
  }
  function result(method, args, extraEnv) {
    const response = invoke(method, args, extraEnv);
    assert.equal(response.ok, true, JSON.stringify(response));
    return response.absent ? null : response.result;
  }
  for (let i = 0; i < 50; i++) {
    const response = await control.call('com.superlogical.terminal.pwd', {session_id: session, block_id: block, args: {}});
    if (response.pwd) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  check('loadfile and foreign-session OSC directory, percent decoding exactly once', () => {
    assert.deepEqual(result('source_directory', {profile_cwd: '/unused'}), {path: source, source: 'pwd'});
  });
  check('local hostname and localhost file URIs', () => {
    for (const host of [os.hostname(), 'localhost']) {
      assert.equal(result('source_directory', {mock_pwd: `file://${host}${pathToFileURL(source).pathname}`}).path, source);
    }
  });
  check('missing, remote, malformed and NUL reports use the explicit profile fallback', () => {
    for (const mock_pwd of ['', 'file://remote.invalid/tmp', 'file:///bad%xx', 'file:///bad%00', 'file:///tmp?query']) {
      assert.deepEqual(result('source_directory', {mock_pwd, profile_cwd: source}), {path: source, source: 'profile'});
    }
    assert.equal(result('source_directory', {context: {}}), null);
  });
  check('a stale source block fails instead of silently changing directory', () => {
    assert.equal(invoke('source_directory', {context: {...context, source_block_id: 'block:missing'}, profile_cwd: source}).ok, false);
  });

  const repo = `${fixture}/repo + space`;
  const linked = `${fixture}/linked\nworktree`;
  const detached = `${fixture}/detached % tree`;
  git('init', '-b', 'main', repo);
  git('-C', repo, '-c', 'user.name=Lab', '-c', 'user.email=lab@example.invalid', 'commit', '--allow-empty', '-m', 'Fixture');
  git('-C', repo, 'worktree', 'add', '-b', 'feature', linked);
  git('-C', repo, 'worktree', 'add', '--detach', detached);
  fs.mkdirSync(`${linked}/subdir`);
  check('worktree lookup preserves newline paths, branches, detached state, and current root', () => {
    const trees = result('worktrees', {path: `${linked}/subdir`});
    assert.equal(trees.repo, fs.realpathSync(repo));
    assert.equal(trees.current, fs.realpathSync(linked));
    const byPath = (a, b) => a.path.localeCompare(b.path);
    assert.deepEqual(trees.list.sort(byPath), [
      {path: fs.realpathSync(repo), branch: 'main', detached: false},
      {path: fs.realpathSync(detached), detached: true},
      {path: fs.realpathSync(linked), branch: 'feature', detached: false}
    ].sort(byPath));
  });
  check('worktree lookup clears inherited Git overrides', () => {
    assert.equal(result('worktrees', {path: repo}, {GIT_DIR: '/missing', GIT_WORK_TREE: '/missing', GIT_CONFIG_COUNT: '1',
      GIT_CONFIG_KEY_0: 'core.bare', GIT_CONFIG_VALUE_0: 'true'}).current, fs.realpathSync(repo));
  });
  check('non-repositories return nil; invalid directories remain errors', () => {
    assert.equal(result('worktrees', {path: source}), null);
    assert.equal(invoke('worktrees', {path: `${fixture}/missing`}).ok, false);
    assert.equal(invoke('worktrees', {path: 'relative'}).ok, false);
  });
  const bare = `${fixture}/bare.git`, bareTree = `${fixture}/bare-tree`;
  git('clone', '--bare', repo, bare);
  git('-C', bare, 'worktree', 'add', bareTree, 'main');
  check('bare root is not selectable; linked worktrees of a bare repo are', () => {
    assert.equal(result('worktrees', {path: bare}), null);
    const trees = result('worktrees', {path: bareTree});
    assert.equal(trees.repo, fs.realpathSync(bare));
    assert.deepEqual(trees.list, [{path: fs.realpathSync(bareTree), branch: 'main', detached: false}]);
  });
  console.log(`PASS ${passed} checks on Rex ${version}. Fixture: ${fixture}`);
} finally {
  if (session) await control.call('session.destroy', {session_id: session});
  if (runnerSession) await control.call('session.destroy', {session_id: runnerSession});
  control.close();
}
