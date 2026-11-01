// Transport ownership, cancellation, page-event reporting and frame association in the production worker,
// driven through isolated browser API mocks (no browser, no network).
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';

const event = { addListener() {} };
const data = {};
const storage = {
  async get(key) { return { [key]: data[key] }; },
  async set(values) { Object.assign(data, structuredClone(values)); },
  async remove(key) { delete data[key]; }
};
const debuggerEvents = [];
const commands = [];
const tabs = new Map([[1, { id: 1, windowId: 5, active: true, url: 'https://a.test/' }]]);
// Frame table: what each frame's page helper would answer.
const viewport = { w: 1280, h: 900 };
const frames = new Map();
const box = (over) => ({ nodeToken: 1, frameId: null, src: '', x: 0, y: 0, w: 400, h: 300, sx: 1, sy: 1, rotated: false, ...over });
const el = (i, x, y) => ({ i, key: 'k' + i, role: 'button', text: 'b' + i, x, y, w: 40, h: 20 });
const page = (url, documentID, elements, boxes = [], vp = { w: 400, h: 300 }) => ({
  url, documentID, snapshotID: 'snap-' + documentID, elements, frames: boxes, viewport: vp, messages: [], text: '', above: 0, below: 0 });
const reply = (id, name, args) => {
  const f = frames.get(id);
  if (name === 'snapshot') return args[0]?.excludeTop && id === 0 ? { __error: 'top frame already observed' } : { __ok: f.snapshot };
  if (name === 'frameBoxes') return { __ok: { frames: f.snapshot.frames } };
  if (name === 'check') return { __ok: { ok: true } };
  if (name === 'readText') return { __ok: { url: f.snapshot.url, title: '', text: 'text of ' + f.snapshot.url } };
  return { __error: 'unmocked ' + name };
};
const chrome = {
  storage: { session: storage, local: storage },
  runtime: { onStartup: event, onInstalled: event, getManifest: () => ({ version: 't' }) },
  alarms: { create() {}, onAlarm: event },
  tabs: { onRemoved: event, onUpdated: event,
    async query() { return [...tabs.values()].filter(t => t.active); },
    async get(id) { if (!tabs.has(id)) throw Error('closed'); return tabs.get(id); } },
  tabGroups: {},
  windows: { async get() { return { focused: true }; } },
  scripting: {
    async executeScript({ target, func, args }) {
      if (!func) return [];
      if (target.allFrames) return [...frames.keys()].filter(id => !frames.get(id).blocked).map(id => ({ frameId: id, result: reply(id, args[0], args[1]) }));
      return [{ frameId: target.frameIds[0], result: reply(target.frameIds[0], args[0], args[1]) }];
    }
  },
  debugger: {
    onDetach: event, onEvent: { addListener(fn) { debuggerEvents.push(fn); } },
    async attach() {}, async detach() {},
    async sendCommand(target, method, params) { commands.push([method, target.tabId, params]); return {}; }
  }
};
const sockets = [];
class WebSocket {
  static OPEN = 1; static CONNECTING = 0;
  constructor() { this.readyState = 0; this.sent = []; sockets.push(this); }
  send(s) { this.sent.push(JSON.parse(s)); }
}
const context = vm.createContext({ chrome, WebSocket, URL, navigator: {}, crypto: { randomUUID: () => 'snap-' + Math.random() },
                                   setTimeout: (f, ms) => 0, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);
const open = (ws) => { ws.readyState = 1; ws.onopen(); };
const settle = () => new Promise(r => setImmediate(r));

// ---- 1. A retired request's result never leaves on a replacement socket (reliability-transport-probe) ----
const realHandle = vm.runInContext('handle', context);
let gateOpen;
const gated = new Promise(r => { gateOpen = r; });
vm.runInContext('globalThis.__gate = null', context);
// Replace the command body with one the test controls; serializedHandle/dispatch rules stay production code.
vm.runInContext(`handle = async function (msg) { if (msg.cmd === 'old-delayed') { await globalThis.__gate; return { from: 'old' }; } return { from: 'new-' + msg.cmd }; }`, context);
context.__gate = gated;
{
  const old = sockets[0]; open(old);
  const oldCompletion = old.onmessage({ data: JSON.stringify({ id: 'r1', cmd: 'old-delayed', tabId: 1 }) });
  await settle();
  old.readyState = 3; old.onclose();
  vm.runInContext('connect()', context);
  const fresh = sockets[1]; open(fresh);
  gateOpen(); await oldCompletion;
  assert.deepEqual(fresh.sent.filter(m => m.id), [], 'delayed result of the old request was emitted on the replacement socket');
  assert.deepEqual(old.sent.filter(m => m.id), [], 'a closed socket cannot carry a reply either');
  // The replacement connection still works, including for the same numeric id the new process reuses.
  await fresh.onmessage({ data: JSON.stringify({ id: 'r1', cmd: 'fresh', tabId: 2 }) });
  assert.deepEqual(fresh.sent.filter(m => m.id), [{ id: 'r1', ok: true, result: { from: 'new-fresh' } }]);
  console.log('PASS delayed result from a retired socket is dropped; the replacement socket answers only its own requests');
}

// ---- 2. Cancel-before-dispatch and expiry: abandoned queued work never runs ----
{
  const ran = [];
  let release; const hold = new Promise(r => { release = r; });
  vm.runInContext(`handle = async function (msg) { globalThis.__ran.push(msg.cmd); if (msg.cmd === 'slow') await globalThis.__hold; return { ok: msg.cmd }; }`, context);
  context.__ran = ran; context.__hold = hold;
  const fresh = sockets[1];
  const slow = fresh.onmessage({ data: JSON.stringify({ id: 'a1', cmd: 'slow', tabId: 7 }) });
  const cancelled = fresh.onmessage({ data: JSON.stringify({ id: 'a2', cmd: 'click-cancelled', tabId: 7 }) });
  const expiring = fresh.onmessage({ data: JSON.stringify({ id: 'a3', cmd: 'click-expired', tabId: 7, ttlMs: 5 }) });
  const survivor = fresh.onmessage({ data: JSON.stringify({ id: 'a4', cmd: 'click-live', tabId: 7, ttlMs: 60000 }) });
  await settle();
  fresh.onmessage({ data: JSON.stringify({ type: 'cancel', id: 'a2' }) });
  fresh.onmessage({ data: JSON.stringify({ type: 'cancel', id: 'a1' }) });   // already running: cannot be undone
  await new Promise(r => globalThis.setTimeout(r, 30));   // outlive a3's ttl while it waits behind a1
  release();
  await Promise.all([slow, cancelled, expiring, survivor]);
  assert.deepEqual(ran, ['slow', 'click-live'], 'cancelled or expired work reached the page');
  const byId = Object.fromEntries(fresh.sent.filter(m => m.id && m.id.startsWith('a')).map(m => [m.id, m]));
  assert.equal(byId.a1.ok, true);
  assert.match(byId.a2.error, /cancelled before dispatch/);
  assert.match(byId.a3.error, /expired while queued/);
  assert.equal(byId.a4.ok, true);
  console.log('PASS queued commands cancelled or expired before dispatch never run; running commands are not undone');
}

// ---- 3. Work queued on a connection that was replaced never dispatches ----
{
  const ran = [];
  let release; const hold = new Promise(r => { release = r; });
  vm.runInContext(`handle = async function (msg) { globalThis.__ran.push(msg.cmd); if (msg.cmd === 'slow') await globalThis.__hold; return {}; }`, context);
  context.__ran = ran; context.__hold = hold;
  const cur = sockets[sockets.length - 1];
  const first = cur.onmessage({ data: JSON.stringify({ id: 'b1', cmd: 'slow', tabId: 9 }) });
  const queued = cur.onmessage({ data: JSON.stringify({ id: 'b2', cmd: 'type-after-restart', tabId: 9 }) });
  await settle();
  cur.readyState = 3; cur.onclose(); vm.runInContext('connect()', context);
  release(); await Promise.all([first, queued]);
  assert.deepEqual(ran, ['slow']);
  console.log('PASS commands queued behind a replaced connection are not dispatched');
}

// ---- 4. JS dialog decisions are explicit and reported ----
context.realHandleForTests = realHandle;
vm.runInContext('handle = realHandleForTests', context);
{
  const onEvent = debuggerEvents[0];
  commands.length = 0;
  onEvent({ tabId: 1 }, 'Page.javascriptDialogOpening', { type: 'confirm', message: 'Delete everything?', url: 'https://a.test/' });
  onEvent({ tabId: 1 }, 'Page.javascriptDialogOpening', { type: 'alert', message: 'Saved', url: 'https://a.test/' });
  const answers = commands.filter(c => c[0] === 'Page.handleJavaScriptDialog').map(c => c[2].accept);
  assert.deepEqual(answers, [false, true], 'confirm must not be accepted by default; alert has only one answer');
  const policy = await context.handle({ cmd: 'dialogPolicy', tabId: 1, accept: true });
  onEvent({ tabId: 1 }, 'Page.javascriptDialogOpening', { type: 'confirm', message: 'Proceed?', url: 'https://a.test/' });
  assert.equal(commands.filter(c => c[0] === 'Page.handleJavaScriptDialog').pop()[2].accept, true);
  onEvent({ tabId: 1 }, 'Page.javascriptDialogOpening', { type: 'confirm', message: 'Again?', url: 'https://a.test/' });
  assert.equal(commands.filter(c => c[0] === 'Page.handleJavaScriptDialog').pop()[2].accept, false, 'an explicit decision applies once');
  // Downloads and chooser requests are reported with the dialogs.
  onEvent({ tabId: 1 }, 'Page.downloadWillBegin', { guid: 'g1', url: 'https://a.test/r.pdf', suggestedFilename: 'r.pdf' });
  onEvent({ tabId: 1 }, 'Page.downloadProgress', { guid: 'g1', state: 'completed', receivedBytes: 10, totalBytes: 10 });
  onEvent({ tabId: 1 }, 'Page.fileChooserOpened', { mode: 'selectSingle' });
  const status = await context.handle({ cmd: 'downloadStatus', tabId: 1 });
  assert.equal(status.downloads[0].state, 'completed');
  const reported = [...policy.events, ...status.events];   // the result of any tab command carries what happened since the last one
  const kinds = reported.map(e => e.kind + ':' + (e.decision || e.phase || e.state));
  assert.deepEqual(kinds, ['dialog:dismissed', 'dialog:accepted', 'dialog:accepted', 'dialog:dismissed',
                           'download:started', 'download:completed', 'fileChooser:intercepted; not fulfilled']);
  assert.equal(reported[0].message, 'Delete everything?');
  assert.equal(reported[5].filename, 'r.pdf');
  assert.equal(reported[5].guid, 'g1');
  assert.equal((await context.handle({ cmd: 'tabInfo', tabId: 1 })).events, undefined, 'events are delivered once');
  console.log('PASS dialog decisions are explicit (confirm never auto-accepted), downloads keep their identity, and all are reported');
}

// ---- 5. Frames: deterministic identity, nesting, scale, rotation, and explicit coverage of what was not read ----
{
  frames.set(0, { snapshot: page('https://a.test/', 'doc0', [el(0, 10, 10)], [
    box({ nodeToken: 1, frameId: 5, src: 'https://lab.b.test:8081/redirected', x: 100, y: 200, w: 800, h: 600 }),   // src differs from the final URL: only identity can place it
    box({ nodeToken: 2, frameId: 6, src: 'https://c.test/', x: 0, y: 0, w: 200, h: 100, sx: 0.5, sy: 0.5 }),
    box({ nodeToken: 3, frameId: 7, src: 'https://blocked.test/', x: 0, y: 700, w: 200, h: 100 }),                  // no script could run there
    box({ nodeToken: 4, frameId: 8, src: 'https://tilt.test/', x: 500, y: 0, w: 200, h: 100, rotated: true }),
  ], viewport) });
  frames.set(5, { snapshot: page('https://lab.b.test:8081/ide', 'doc5', [el(0, 20, 30)], [
    box({ nodeToken: 1, frameId: 9, src: 'https://deep.test/', x: 50, y: 60, w: 300, h: 200 })], { w: 800, h: 600 }) });
  frames.set(9, { snapshot: page('https://deep.test/', 'doc9', [el(0, 5, 6)], [], { w: 300, h: 200 }) });
  frames.set(6, { snapshot: page('https://c.test/', 'doc6', [el(0, 40, 20)], [], { w: 400, h: 200 }) });
  frames.set(7, { blocked: true, snapshot: page('https://blocked.test/', 'doc7', [], [], { w: 200, h: 100 }) });
  frames.set(8, { snapshot: page('https://tilt.test/', 'doc8', [el(0, 1, 1)], [], { w: 200, h: 100 }) });
  const snap = await context.handle({ cmd: 'snapshot', tabId: 1 });
  const at = (frame) => snap.elements.find(e => e.frame === frame);
  assert.deepEqual([at('lab.b.test').x, at('lab.b.test').y], [120, 230], 'cross-origin frame placed by identity');
  assert.deepEqual([at('deep.test').x, at('deep.test').y], [100 + 50 + 5, 200 + 60 + 6], 'nested frame composes its parent offset');
  assert.deepEqual([at('c.test').x, at('c.test').y, at('c.test').w], [20, 10, 20], 'CSS scale applies to position and size');
  assert.ok(!snap.elements.some(e => e.frame === 'tilt.test'), 'a rotated frame is not placed with translation-only math');
  const reasons = Object.fromEntries(snap.frameCoverage.map(c => [c.frame, c.reason]));
  assert.match(reasons['blocked.test'], /could not run/);
  assert.match(reasons['tilt.test'], /rotated/);
  assert.match(snap.text, /frames not read: .*blocked\.test.*tilt\.test/);
  const read = await context.handle({ cmd: 'read', tabId: 1, documentID: snap.documentID, snapshotID: snap.snapshotID });
  assert.match(read.text, /text of https:\/\/deep\.test\//);
  assert.ok(read.unreadFrames.length === 2 && /frames not read/.test(read.text));
  console.log('PASS cross-origin/nested/scaled frames are placed deterministically; unreadable and rotated frames are reported, not dropped');
}
