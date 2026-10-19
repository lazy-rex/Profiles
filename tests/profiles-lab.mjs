// Lab: Start Agent… and Start Accessory… (plugins/profiles.lua). Lab only: PROFILES_LAB (default
// /tmp/rexlab-profiles-claude), server started with LAB_CONFIG=$LAB/init.lua (one line:
// pcall(require, "lazyrex_palette")), hub on $LAB/hub.json with the plugins lazyrex and profiles,
// palette_lua $LAB/lazyrex_palette.lua and profiles $LAB/profiles.json:
//   fake_claude (agent, arg task; prints "agent task=<task>" and its directory), logtail
//   (accessory; prints its directory). The built-in shell is the other accessory.
// Fixture: $LAB/repo (git, main) with the linked worktree $LAB/repo-wt (feature) and the folders
// repo/sub/deeper. The source pane reports repo/sub with OSC 7.
// Checks: the form shows the source pane's directory and the worktrees; a worktree choice
// re-renders the form and keeps typed text; Start opens a new tab in the source session, in the
// chosen worktree, with the task; the form closes and its draft is gone. The accessory form lists
// only accessories; a directory typed into the Directory field is used; Split starts the accessory beside the
// source pane. Both starts focus the new pane (placement.focus). "~" typed into the Directory field
// starts in the home directory. A broken profiles file shows its error instead of Loading.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const LAB = process.env.PROFILES_LAB || '/tmp/rexlab-profiles-claude', SOCK = `unix://${LAB}/rex.sock`;
const c = await connectControl(`${LAB}/rex.sock`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const waitFor = async (what, f, ms = 10000) => { for (let t = 0; t < ms; t += 100) { const v = await f(); if (v) return v; await sleep(100); } assert.fail(`timed out: ${what}`); };
const rex = (...a) => execFileSync('env', ['-u', 'REX_SESSION', '-u', 'REX_BLOCK', 'rex', '-S', SOCK, '--autostart=false', ...a], {encoding: 'utf8'});
const db = sql => execFileSync('sqlite3', ['-readonly', `${LAB}/int/hub.db`, sql], {encoding: 'utf8'}).trim();
const screen = (s, b) => { try { return rex('capture', '-s', s, '-b', b); } catch { return ''; } };
// The renderer wraps long text: compare with all whitespace removed.
const shows = (s, b, text) => screen(s, b).replace(/\s+/g, '').includes(text.replace(/\s+/g, ''));
const real = p => fs.realpathSync(p);

const SUB = `${LAB}/repo/sub`, DEEPER = `${SUB}/deeper`, WT = real(`${LAB}/repo-wt`);
const sessions = [];
async function source(label) {
  const S = (await c.call('session.create', {label: `${label}-${Date.now()}`, initial_windows: [{window_label: 'src', layout: {block: {flavor: 'com.superlogical.terminal.shell', label: 'src',
    options: {command: ['/bin/sh', '-c', `printf '\\033]7;file://localhost${SUB}\\007'; exec sleep 600`], login: false}}}}]})).session_id;
  sessions.push(S);
  await c.call('session.attach', {session_id: S, event_scope: 'session'});
  const w = (await c.call('session.view', {session_id: S})).windows[0];
  await sleep(500); // the pane reports its directory
  return {S, window: w.window_id, src: w.focused_block_id};
}
const blocksOf = async S => (await c.call('session.view', {session_id: S})).windows.flatMap(w => w.layers.flatMap(l => l.blocks.map(b => ({...b, window_id: w.window_id, window_label: w.label}))));
async function openForm(src, command) {
  await c.call('client.action', {action: command, origin: 'palette', session_id: src.S, block_id: src.src});
  const form = await waitFor('form pane', async () => (await blocksOf(src.S)).find(b => b.label?.startsWith('lazyrex-form:')));
  const view = form.label.slice('lazyrex-form:'.length);
  // A tall grid shows the whole form in one capture. Only the owner's size applies (the hub created
  // the pane), so the test takes the pane first. Lab only: no app shows this session.
  await c.call('session.own_block', {session_id: src.S, block_ids: [form.block_id], mode: 'take'});
  await c.call('com.superlogical.terminal.resize', {session_id: src.S, block_id: form.block_id, args: {columns: 90, rows: 80}});
  const key = (...k) => rex('send-key', '-s', src.S, '-b', form.block_id, ...k);
  // Keys right after a re-render can be lost (roadmap, known defects): pause between keys.
  const keys = async (...ks) => { for (const k of ks) { key(...k.split(',')); await sleep(250); } };
  // send-key has no key for some characters, such as ~: send writes the text itself.
  const type = async text => { rex('send', '-s', src.S, '-b', form.block_id, text); await sleep(250); };
  const pick = async label => {
    await keys('enter');
    await waitFor('select opens', () => shows(src.S, form.block_id, '✓'));
    await type(label);
    await keys('enter');
    await waitFor(`${label} chosen in the closed field`, () => shows(src.S, form.block_id, `${label} ▾`) && !shows(src.S, form.block_id, '✓'));
  };
  return {...form, view, keys, type, pick, shows: text => shows(src.S, form.block_id, text)};
}

try {
  // 1. Start Agent… from a pane in repo/sub.
  const a = await source('profiles-agent');
  const f1 = await openForm(a, 'lazyrex_profiles_start_agent');
  await waitFor('the source directory', () => f1.shows('Directory (from the source pane)') && f1.shows(`│ ${SUB}`));
  assert(f1.shows('Worktree main (current)') && f1.shows('Worktree feature'), 'the worktrees are listed');
  assert(!f1.shows('Log tail'), 'the agent form lists no accessory');
  // Focus order (the first item has focus): main, feature, profile default, Browse… (native),
  // Directory, Profile, Task, Title, Placement, Start.
  await f1.keys('tab', 'tab', 'tab', 'tab', 'tab', 'tab');
  await sleep(300);
  await f1.keys('l', 'a', 'b', '1');
  await waitFor('typed task', () => f1.shows('│ lab1'));
  await f1.keys('shift+tab', 'shift+tab', 'shift+tab', 'shift+tab', 'shift+tab', 'enter');
  await waitFor('the worktree is chosen', () => f1.shows('Worktree feature (current)'));
  // The directory line has scrolled out of the viewport: read the draft.
  assert.equal(db(`SELECT json_extract(value, '$.dir') FROM records WHERE ns = 'profiles' AND key = 'draft/${f1.view}'`), WT, 'the directory is the worktree')
  assert(f1.shows('│ lab1'), 'the typed task survives the re-render');
  assert.equal(db(`SELECT COUNT(*) FROM records WHERE ns = 'profiles' AND key = 'draft/${f1.view}'`), '1', 'the form has a draft');
  await sleep(300);
  // The Directory field takes the new directory (the renderer replaces an unedited field's value),
  // and Start sends the field.
  await f1.keys('tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'enter'); // from feature to Start
  const agentPane = await waitFor('the agent tab', async () => (await blocksOf(a.S)).find(b => b.label?.startsWith('lazyrex-spawn:')));
  assert.notEqual(agentPane.window_id, a.window, 'a new tab');
  assert.match(agentPane.window_label, /^Fake Claude \d+$/);
  await waitFor('the agent output', () => shows(a.S, agentPane.block_id, 'agent task=lab1') && shows(a.S, agentPane.block_id, WT));
  await waitFor('the form closed', async () => !(await blocksOf(a.S)).some(b => b.label === f1.label));
  const va = await c.call('session.view', {session_id: a.S});
  assert.equal(va.active_window_id, agentPane.window_id, 'placement.focus: the new tab is active');
  assert.equal(va.windows.find(w => w.window_id === agentPane.window_id).focused_block_id, agentPane.block_id, 'the agent pane has focus');
  assert.equal(db(`SELECT COUNT(*) FROM records WHERE ns = 'profiles' AND key = 'draft/${f1.view}'`), '0', 'the draft is gone');
  const spawn = agentPane.label.slice('lazyrex-spawn:'.length);
  assert.equal(db(`SELECT status || '|' || session_id || '|' || cwd FROM spawns WHERE spawn_id = '${spawn}'`), `open|${a.S}|${WT}`);

  // 2. Start Accessory…: repo/sub/deeper typed into Directory, Log tail, Split.
  const b = await source('profiles-accessory');
  const f2 = await openForm(b, 'lazyrex_profiles_start_accessory');
  await waitFor('the accessory form', () => f2.shows(`│ ${SUB}`));
  assert(f2.shows('Shell') && !f2.shows('Fake Claude'), 'the accessory form lists accessories only: ' + screen(b.S, f2.block_id));
  // Focus order: main (current), feature, profile default, Browse… (native), Directory, Profile,
  // Title, Placement, Start.
  await sleep(300);
  await f2.keys('tab', 'tab', 'tab', 'tab', 'ctrl+u'); // Directory: clear, type the folder
  await f2.type(DEEPER);
  await waitFor('typed deeper', () => f2.shows(`│ ${DEEPER}`));
  await f2.keys('tab'); // Profile
  await f2.pick('Log tail');
  await f2.keys('tab', 'tab'); // Placement
  await f2.pick('Split beside the source pane');
  await f2.keys('tab', 'enter'); // Start
  const tail = await waitFor('the accessory pane', async () => (await blocksOf(b.S)).find(bl => bl.label?.startsWith('lazyrex-spawn:')));
  assert.equal(tail.window_id, b.window, 'the split is in the source tab');
  await waitFor('the accessory directory', () => shows(b.S, tail.block_id, real(DEEPER)));
  await waitFor('the accessory form closed', async () => !(await blocksOf(b.S)).some(bl => bl.label === f2.label));
  const vb = await c.call('session.view', {session_id: b.S});
  assert.equal(vb.windows.find(w => w.window_id === b.window).focused_block_id, tail.block_id, 'placement.focus: the split has focus');
  const layout = JSON.stringify((await c.call('session.view', {session_id: b.S})).windows.find(w => w.window_id === b.window).layers[0].layout);
  assert(layout.indexOf(b.src) >= 0 && layout.indexOf(b.src) < layout.indexOf(tail.block_id), 'the accessory is right of the source pane: ' + layout);

  // 3. Text typed into the Directory field: "~" is the home directory (the native browser types the
  // same kind of text; no app runs in the lab).
  const e = await source('profiles-typed');
  const f4 = await openForm(e, 'lazyrex_profiles_start_accessory');
  await waitFor('the typed-directory form', () => f4.shows('Browse…') && f4.shows('Worktree feature'));
  await sleep(300);
  await f4.keys('tab', 'tab', 'tab', 'tab', 'ctrl+u'); // Directory: clear, type ~
  await f4.type('~');
  await waitFor('typed ~', () => f4.shows('│ ~'));
  await f4.keys('tab');
  await f4.pick('Log tail');
  await f4.keys('tab', 'tab', 'tab', 'enter'); // Start (new tab)
  const homePane = await waitFor('the accessory in the home directory', async () => (await blocksOf(e.S)).find(bl => bl.label?.startsWith('lazyrex-spawn:')));
  await waitFor('the home directory', () => shows(e.S, homePane.block_id, real(process.env.HOME)));

  // 4. Typed text, then an explicit list choice: the choice replaces the edited text (the field's rev
  // changes) and Start sends the choice.
  const g = await source('profiles-typed-choice');
  const f5 = await openForm(g, 'lazyrex_profiles_start_accessory');
  await waitFor('the typed-choice form', () => f5.shows(`│ ${SUB}`) && f5.shows('Worktree feature'));
  await sleep(300);
  await f5.keys('tab', 'tab', 'tab', 'tab', 'ctrl+u'); // Directory: clear, type /nowhere
  await f5.type('/nowhere');
  await waitFor('typed /nowhere', () => f5.shows('│ /nowhere'));
  await f5.keys('shift+tab', 'shift+tab', 'shift+tab', 'enter'); // Worktree feature
  await waitFor('the choice replaces the typed text', () => f5.shows('Worktree feature (current)') && f5.shows(`│ ${WT}`) && !f5.shows('│ /nowhere'));
  await sleep(300);
  await f5.keys('tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'tab', 'enter'); // from feature to Start (Shell, new tab)
  const chosenPane = await waitFor('the accessory in the chosen worktree', async () => (await blocksOf(g.S)).find(bl => bl.label?.startsWith('lazyrex-spawn:')));
  assert.equal(db(`SELECT cwd FROM spawns WHERE spawn_id = '${chosenPane.label.slice('lazyrex-spawn:'.length)}'`), WT, 'Start sends the list choice');

  // 5. A broken profiles file shows its error.
  const good = fs.readFileSync(`${LAB}/profiles.json`, 'utf8');
  fs.writeFileSync(`${LAB}/profiles.json`, good.replace('"fake_claude"', '"Bad-ID"'));
  try {
    const d = await source('profiles-broken');
    const f3 = await openForm(d, 'lazyrex_profiles_start_agent');
    await waitFor('the profiles error', () => f3.shows('Profiles could not be loaded'));
    await f3.keys('ctrl+q');
    await waitFor('Ctrl+Q closes the form', async () => !(await blocksOf(d.S)).some(bl => bl.label === f3.label));
  } finally {
    fs.writeFileSync(`${LAB}/profiles.json`, good);
  }
  console.log('profiles-lab: pass');
} catch (e) {
  console.error(e);
  process.exitCode = 1;
} finally {
  for (const S of sessions) await c.call('session.destroy', {session_id: S}).catch(e => console.error('destroy', S, e.message));
  process.exit(process.exitCode ?? 0);
}
