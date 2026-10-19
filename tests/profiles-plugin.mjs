// Test plugins/profiles.lua in real Rex Lua with a controlled hub (an in-memory store and scripted
// hub.spawn results). Lab only: REX_SERVER must name an isolated lab socket, and PROFILES_LAB must
// hold the git fixture $PROFILES_LAB/repo (see tests/README.md, "Start forms").
// Checks: a pending start completes the view action (it does not stay unknown), hides Start, and
// refuses a second start; Check again sends the same saved request; open closes the form and
// removes the draft; failed shows the error and brings Start back. A replay of the start sends the
// saved request even after the values, the context or the directory changed. Cancel ($cancel) is
// handled by the renderer and the hub; it never reaches the plugin, so it cannot start anything. Shared arg fields start empty,
// and an empty field is not sent, so the chosen profile's own default applies.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import {labSocket, until} from '../../LazyRex/lab/lab.mjs';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const socket = await labSocket();
const LAB = process.env.PROFILES_LAB || '/tmp/rexlab-profiles-claude';
const hub = await connectControl(socket), control = await connectControl(socket);
let child, pluginId, session;
const records = new Map(), ops = new Map();
let rev = 0;
const spawns = [];
let spawnResult = {status: 'pending', spawn_id: 'spawn-1'};
let brokenProfiles = false;
const profiles = [
  {id: 'alpha', name: 'Alpha', kind: 'agent', cwd: '', args: [{name: 'task', label: 'Task', default: 'alpha default'}]},
  {id: 'beta', name: 'Beta', kind: 'agent', cwd: '', args: [{name: 'task', label: 'Goal', default: 'beta default'}]},
  {id: 'shell', name: 'Shell', kind: 'accessory', cwd: '', args: []}];
function store(action, args) {
  if (action === 'hub.store.get') return {records: Object.fromEntries(args.keys.map(k => [k, records.get(k) ?? {rev: '0'}]))};
  if (action === 'hub.store.op') { const o = ops.get(args.key); return o ? {found: true, ...o} : {found: false}; }
  if (action === 'hub.store.scan') return {records: Object.fromEntries([...records].filter(([k]) => k.startsWith(args.prefix ?? '')))};
  if (action === 'hub.store.batch') {
    if (args.op && ops.has(args.op.key)) return {op_exists: ops.get(args.op.key)};
    for (const o of Array.isArray(args.ops) ? args.ops : []) {
      const cur = records.get(o.key)?.rev ?? '0';
      if (o.if_rev !== undefined && o.if_rev !== cur) return {conflict: {kind: 'revision', key: o.key, rev: cur}};
    }
    const revs = {};
    for (const o of Array.isArray(args.ops) ? args.ops : []) {
      if (o.delete) { records.delete(o.key); revs[o.key] = '0'; } else { records.set(o.key, {rev: String(++rev), value: o.value}); revs[o.key] = String(rev); }
    }
    if (args.op) ops.set(args.op.key, {fingerprint: args.op.fingerprint, result: args.op.result});
    return {revs};
  }
}
try {
  const label = 'profiles-plugin-test-' + process.pid;
  await hub.call('client.set_label', {label});
  const hubId = (await control.call('client.list')).clients.find(c => c.info?.label === label).client_id;
  const names = ['register', 'profiles', 'workers', 'spawn', 'ui.invalidate', 'store.get', 'store.batch', 'store.op', 'store.scan'];
  await hub.call('client.keymap', {actions: names.map(n => ({name: 'hub.' + n, kind: 'client', title: n}))});
  hub.events.on('event', async frame => {
    if (frame.payload?.type !== 'client_perform_requested') return;
    const ev = frame.payload.payload;
    try {
      let result = store(ev.action, ev.args ?? {});
      if (result) {}
      else if (ev.action === 'hub.register') { pluginId = ev.requester.client_id; result = {generation: '1'}; }
      else if (ev.action === 'hub.profiles') { if (brokenProfiles) throw new Error('profiles.json: invalid'); result = {profiles}; }
      else if (ev.action === 'hub.workers') result = {workers: [{spawn_id: 'spawn-1', state: 'starting', error: 'outcome unknown: no pane found'}]};
      else if (ev.action === 'hub.spawn') { spawns.push(ev.args); result = spawnResult; }
      else result = {status: 'accepted'};
      await hub.call('client.reply', {call_id: ev.call_id, result});
    } catch (error) { await hub.call('client.reply', {call_id: ev.call_id, error: {code: 'internal', message: error.message}}); }
  });
  // A real source pane, so the directory helper reads a real terminal.pwd.
  const dir = `${LAB}/repo`;
  session = (await control.call('session.create', {label: 'profiles-plugin-' + Date.now(), initial_windows: [{window_label: 'src', layout: {block: {flavor: 'com.superlogical.terminal.shell', label: 'src',
    options: {command: ['/bin/sh', '-c', `printf '\\033]7;file://localhost${dir}\\007'; exec sleep 120`], login: false}}}}]})).session_id;
  await control.call('session.attach', {session_id: session, event_scope: 'session'});
  const view0 = await control.call('session.view', {session_id: session});
  const context = {session_id: session, window_id: view0.windows[0].window_id, source_block_id: view0.windows[0].focused_block_id, source_view_id: '', source_route: ''};
  await new Promise(r => setTimeout(r, 500));
  child = spawn('rex', ['-S', 'unix://' + socket, '--autostart=false', 'do', fileURLToPath(new URL('../../Profiles/profiles.lua', import.meta.url)), '-s', session, `hub_client_id=${hubId}`, 'instance_id=profiles-test'],
    {env: {...process.env, REX_SERVER: 'unix://' + socket, REX_SESSION: '', REX_BLOCK: '', REX_CLIENT: ''}});
  child.stdout.pipe(process.stdout); child.stderr.pipe(process.stderr);
  await until(async () => (await control.call('client.list')).clients.some(c => c.client_id === pluginId && c.info?.label === 'lazyrex-plugin:profiles'), 'profiles registration');
  const call = async (action, args) => (await hub.call('client.perform', {client_id: pluginId, action, args: {route: '/forms/start-agent', user: 'user', context, ...args}, timeout_ms: 10000})).result;
  const fails = async (action, args) => { try { await call(action, args); return ''; } catch (e) { return String(e.message ?? e); } };
  const render = async view_id => (await call('view.render', {view_id})).tree;
  const node = (tree, id) => tree.nodes.find(n => n.id === id);

  // Shared arg fields: one empty field, both labels, the default policy in the label.
  let tree = await render('v1');
  const task = node(tree, 'start').fields.find(f => f.id === 'arg/task');
  assert.equal(task.value, '', 'a shared arg field starts empty');
  assert.equal(task.label, "Task / Goal (empty: the profile's default)");
  assert.equal(records.get('draft/v1').value.dir, dir, 'the first render records the source directory');
  const dirField = node(tree, 'start').fields.find(f => f.id === 'dir');
  assert.deepEqual([dirField.value, dirField.browse, dirField.kind], [dir, 'native', 'text'], 'the Directory field offers the native browser');

  // A pending start completes the action and records the pending start.
  const values = {profile: 'beta', 'arg/task': '', title: '', placement: 'tab'};
  const r1 = await call('view.action', {view_id: 'v1', node_id: 'start', action: 'start', operation_key: 'op-1', input: {values}});
  assert.deepEqual(r1, {}, 'a pending start succeeds with no effect: ' + JSON.stringify(r1));
  assert.equal(spawns.length, 1);
  assert.equal(spawns[0].args, undefined, 'an empty shared field is not sent: the profile default applies');
  assert.deepEqual(spawns[0].placement, {session, focus: {source_window_id: context.window_id}});
  assert.equal(spawns[0].cwd, dir);
  // The same operation again (a hub replay) sends the same request and changes nothing, also when
  // the values, the source context and the directory changed since.
  records.get('draft/v1').value.dir = '/elsewhere';
  assert.deepEqual(await call('view.action', {view_id: 'v1', node_id: 'start', action: 'start', operation_key: 'op-1',
    context: {...context, window_id: 'window:other', source_block_id: 'block:other'}, input: {values: {...values, profile: 'alpha', placement: 'split'}}}), {});
  assert.deepEqual(spawns[1], spawns[0], 'a replay sends the saved request, not the new values');
  tree = await render('v1');
  assert(!node(tree, 'start'), 'Start is hidden while a start is pending');
  assert.match(node(tree, 'pending').text, /Starting beta… The outcome is not known yet \(outcome unknown: no pane found\)/);
  assert.match(await fails('view.action', {view_id: 'v1', node_id: 'start', action: 'start', operation_key: 'op-2', input: {values}}), /still pending/);
  assert.equal(spawns.length, 2, 'no second start');
  // Another form keeps working.
  assert.deepEqual(await call('view.action', {view_id: 'v2', node_id: 'dir_choices', action: 'default', operation_key: 'op-v2', input: {item_id: 'default'}}), {});

  // A pending form still renders and checks when the profiles file is broken.
  brokenProfiles = true;
  assert(node(await render('v1'), 'pending_actions'), 'the pending view renders without profiles');
  // Check again: still pending, then open.
  assert.deepEqual(await call('view.action', {view_id: 'v1', node_id: 'pending_actions', action: 'check', operation_key: 'op-3', input: {item_id: 'check'}}), {});
  spawnResult = {status: 'open', spawn_id: 'spawn-1', block_id: 'block:x', window_id: 'window:x'};
  // (the profiles file is still broken here: Check again needs only the saved request)
  assert.deepEqual(await call('view.action', {view_id: 'v1', node_id: 'pending_actions', action: 'check', operation_key: 'op-4', input: {item_id: 'check'}}), {close_form: true});
  assert(spawns.slice(2).every(s => JSON.stringify(s) === JSON.stringify(spawns[0])), 'Check again sends the same request');
  assert(!records.has('draft/v1'), 'the draft is gone after the start');

  brokenProfiles = false;
  // Failed: the error shows and Start returns.
  spawnResult = {status: 'pending', spawn_id: 'spawn-2'};
  await render('v3');
  await call('view.action', {view_id: 'v3', node_id: 'start', action: 'start', operation_key: 'op-5', input: {values: {...values, 'arg/task': 'explicit', title: 'Mine', placement: 'split'}}});
  assert.deepEqual(spawns.at(-1).args, {task: 'explicit'}, 'a typed value is sent');
  spawnResult = {status: 'failed', spawn_id: 'spawn-2', error: 'command not found'};
  assert.deepEqual(await call('view.action', {view_id: 'v3', node_id: 'pending_actions', action: 'check', operation_key: 'op-6', input: {item_id: 'check'}}), {});
  tree = await render('v3');
  assert(node(tree, 'start'), 'Start returns after a failed start');
  const back = Object.fromEntries(node(tree, 'start').fields.map(f => [f.id, f.value]));
  assert.deepEqual(back, {dir, profile: 'beta', 'arg/task': 'explicit', title: 'Mine', placement: 'split'}, 'the submitted values come back');
  assert.equal(node(tree, 'start_error').text, 'The last start failed: command not found');
  // An explicit directory choice after a failed start: the field takes the choice (its rev changes,
  // so the renderer replaces even edited text), the other restored values stay, and Start sends it.
  const dirOf = t => node(t, 'start').fields.find(f => f.id === 'dir');
  const rev0 = dirOf(tree).rev;
  assert.equal(rev0, 0, 'no explicit choice yet');
  assert.equal(dirOf(await render('v3')).rev, rev0, 'an ordinary render keeps the rev');
  const other = node(tree, 'dir_choices').items.find(i => i.id.startsWith('tree:') && !i.label.includes('(current)'));
  assert(other, 'another worktree is offered: ' + JSON.stringify(node(tree, 'dir_choices').items));
  await call('view.action', {view_id: 'v3', node_id: 'dir_choices', action: 'default', operation_key: 'op-c1', input: {item_id: 'default'}});
  tree = await render('v3');
  assert.deepEqual([dirOf(tree).value, dirOf(tree).rev], ['', rev0 + 1], 'the profile default empties the field');
  await call('view.action', {view_id: 'v3', node_id: 'dir_choices', action: 'choose', operation_key: 'op-c2', input: {item_id: other.id}});
  tree = await render('v3');
  const chosen = other.id.slice('tree:'.length);
  const after = Object.fromEntries(node(tree, 'start').fields.map(f => [f.id, f.value]));
  assert.deepEqual(after, {dir: chosen, profile: 'beta', 'arg/task': 'explicit', title: 'Mine', placement: 'split'}, 'the choice replaces only the directory');
  assert.equal(dirOf(tree).rev, rev0 + 2);
  spawnResult = {status: 'open', spawn_id: 'spawn-c', block_id: 'block:c', window_id: 'window:c'};
  assert.deepEqual(await call('view.action', {view_id: 'v3', node_id: 'start', action: 'start', operation_key: 'op-c3', input: {values: after}}), {close_form: true});
  assert.equal(spawns.at(-1).cwd, chosen, 'Start sends the chosen worktree');
  // The in-form list browser is gone: no Browse item, no browser node. A draft stored by the older
  // plugin with browse and prefix still loads, and the old browser actions are refused.
  await render('u1');
  const old = records.get('draft/u1').value;
  old.browse = `${dir}/sub`;
  old.prefix = 'de';
  tree = await render('u1');
  assert.deepEqual(node(tree, 'dir_choices').items.map(i => i.id).filter(i => !i.startsWith('tree:')), ['default'], 'only worktrees and the profile default');
  assert(!['browse', 'browse_error', 'browse_more', 'filter'].some(id => node(tree, id)), 'no in-form browser');
  assert.deepEqual([dirOf(tree).value, dirOf(tree).rev], [dir, 0], 'an old draft shows its directory');
  for (const [node_id, act, item_id] of [['dir_choices', 'browse', 'browse'], ['browse', 'use', 'use'], ['browse', 'open', 'up'], ['filter', 'filter', '']]) {
    assert.match(await fails('view.action', {view_id: 'u1', node_id, action: act, operation_key: `op-old-${node_id}-${act}`, input: {item_id}}), /Unknown action/, `refused: ${node_id} ${act}`);
  }
  spawnResult = {status: 'open', spawn_id: 'spawn-u1', block_id: 'block:u1', window_id: 'window:u1'};
  await call('view.action', {view_id: 'u1', node_id: 'start', action: 'start', operation_key: 'op-u1', input: {values: {...values, dir: dirOf(tree).value}}});
  assert.equal(spawns.at(-1).cwd, dir, 'an old draft starts in its directory, not in the old browse folder');
  // The Directory field's text, as data: escapes, ~, trailing /, no trim, no shell.
  spawnResult = {status: 'open', spawn_id: 'spawn-n', block_id: 'block:n', window_id: 'window:n'};
  const HOME = process.env.HOME;
  let n = 0;
  const startWith = async text => {
    const view_id = 'n' + (++n);
    await render(view_id);
    await call('view.action', {view_id, node_id: 'start', action: 'start', operation_key: 'op-n' + n, input: {values: {...values, dir: text}}});
    return spawns.at(-1).cwd;
  };
  const cases = [
    ['~/Projects/', `${HOME}/Projects`], ['~', HOME], ['/', '/'], ['/a/b//', '/a/b'],
    ['~/Calibre\\ Library/', `${HOME}/Calibre Library`], ['/x/ lead and trail ', '/x/ lead and trail '],
    ['/x/\\ /', '/x/ '], ['/x/a\\\\b', '/x/a\\b'], ["/x/it's", "/x/it's"], ["'/x/quoted dir/'", '/x/quoted dir'],
    ['/x/new\nline', '/x/new\nline'], ['', dir]];
  for (const [text, want] of cases) assert.equal(await startWith(text), want, `directory text ${JSON.stringify(text)}`);
  for (const bad of ['relative/path', '/x/trailing\\', '~user/x']) {
    const view_id = 'bad' + (++n);
    await render(view_id);
    assert.match(await fails('view.action', {view_id, node_id: 'start', action: 'start', operation_key: 'op-bad' + n, input: {values: {...values, dir: bad}}}),
      /absolute path|lone backslash/, `refused: ${JSON.stringify(bad)}`);
  }
  // Round trip: a raw path with a backslash and a space is escaped once in the field; an untouched
  // submit keeps it. render -> submit (fails) -> render -> submit keeps it too: the restored field
  // holds the submitted editor text, which is never decoded into the editor.
  const RAW = '/x/back\\slash and space';
  await render('rt');
  records.get('draft/rt').value.dir = RAW;
  const rtField = node(await render('rt'), 'start').fields.find(f => f.id === 'dir');
  assert.equal(rtField.value, '/x/back\\\\slash and space', 'the field escapes the backslash once');
  assert.equal(node(await render('rt'), 'start').fields.find(f => f.id === 'dir').value, rtField.value, 'a second render escapes once');
  spawnResult = {status: 'pending', spawn_id: 'spawn-rt'};
  await call('view.action', {view_id: 'rt', node_id: 'start', action: 'start', operation_key: 'op-rt1', input: {values: {...values, dir: rtField.value}}});
  assert.equal(spawns.at(-1).cwd, RAW, 'an untouched submit keeps the raw path');
  spawnResult = {status: 'failed', spawn_id: 'spawn-rt', error: 'lab failure'};
  await call('view.action', {view_id: 'rt', node_id: 'pending_actions', action: 'check', operation_key: 'op-rt2', input: {item_id: 'check'}});
  const again = node(await render('rt'), 'start').fields.find(f => f.id === 'dir');
  assert.equal(again.value, rtField.value, 'the restored field holds the same editor text');
  spawnResult = {status: 'open', spawn_id: 'spawn-rt3', block_id: 'block:rt', window_id: 'window:rt'};
  await call('view.action', {view_id: 'rt', node_id: 'start', action: 'start', operation_key: 'op-rt3', input: {values: {...values, dir: again.value}}});
  assert.equal(spawns.at(-1).cwd, RAW, 'a second submit keeps the same raw path');
  console.log('profiles-plugin: pass');
} catch (e) {
  console.error(e);
  process.exitCode = 1;
} finally {
  child?.kill();
  if (session) await control.call('session.destroy', {session_id: session}).catch(() => {});
  process.exit(process.exitCode ?? 0);
}
