// Exercise the production worker with isolated browser API mocks.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const calls = [];
const event = { addListener() {} };
const data = {};
const storage = {
  async get(key) { return { [key]: data[key] }; },
  async set(values) { Object.assign(data, structuredClone(values)); },
  async remove(key) { delete data[key]; }
};
const tabs = new Map([[1, { id: 1, windowId: 5, active: true, url: 'https://personal.test' }]]);
let next = 10, denyAttach = false, denyCreate = false;
const chrome = {
  storage: { session: storage, local: storage },
  runtime: { onStartup: event, onInstalled: event },
  alarms: { create() {}, onAlarm: event },
  tabs: {
    onRemoved: event,
    async query() { return [...tabs.values()].filter(t => t.active); },
    async get(id) { if (!tabs.has(id)) throw Error('closed'); return tabs.get(id); },
    async create(args) { calls.push(['create', args]); if (denyCreate) throw Error('create acknowledgement lost'); const t = { id: next++, windowId: 5, ...args }; tabs.set(t.id, t); return t; },
    async update(id, args) { calls.push(['update', id, args]); Object.assign(tabs.get(id), args); return tabs.get(id); },
    async remove(id) { calls.push(['remove', id]); tabs.delete(id); },
    async group(args) { calls.push(['group', args]); return 8; }
  },
  tabGroups: { async query() { return []; }, async update() {} },
  windows: { async get() { return { focused: false }; }, async update(...args) { calls.push(['focusWindow', ...args]); } },
  debugger: {
    onDetach: event, onEvent: event,
    async attach(target) { calls.push(['attach', target.tabId]); if (denyAttach) throw Error('debugger denied'); },
    async detach(target) { calls.push(['detach', target.tabId]); },
    async sendCommand(target, method, params) { calls.push([method, target.tabId, params]); return { data: 'PNG' }; }
  }
};
class WebSocket { constructor() { this.readyState = 0; } }
const context = vm.createContext({ chrome, WebSocket, URL, navigator: {}, setTimeout, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), context);
const first = await context.serializedHandle({ cmd: 'clinqyTab', url: 'https://task.test', width: 1280, height: 900 });
assert.equal(first.id, 10);
assert.equal(calls.find(c => c[0] === 'create')[1].active, false);
assert.equal(tabs.get(1).active, true);
assert(calls.some(c => c[0] === 'Emulation.setFocusEmulationEnabled' && c[2].enabled));
assert(calls.some(c => c[0] === 'Page.setInterceptFileChooserDialog' && c[2].enabled));
assert(calls.some(c => c[0] === 'Emulation.setDeviceMetricsOverride' && c[2].width === 1280));
const list = await context.handle({ cmd: 'tabs', workOnly: true });
assert.deepEqual(Array.from(list.tabs, t => t.id), [10]);
for (const cmd of ['snapshot', 'navigate', 'closeTab', 'switchTab', 'captureTask']) {
  await assert.rejects(context.handle({ cmd, workOnly: true, tabId: 1 }), /does not belong/);
  await assert.rejects(context.handle({ cmd, workOnly: true }), /does not belong/);
}
await assert.rejects(context.handle({ cmd: 'newTab', workOnly: true, tabId: 10 }), /inactive task tab/);
await context.handle({ cmd: 'switchTab', workOnly: true, tabId: 10 });
await context.handle({ cmd: 'navigate', workOnly: true, tabId: 10, url: 'https://task.test/next' });
assert.equal(tabs.get(1).url, 'https://personal.test');
assert(!calls.some(c => c[0] === 'focusWindow' || (c[0] === 'update' && c[2].active)));
assert.equal((await context.handle({ cmd: 'captureTask', workOnly: true, tabId: 10 })).image, 'PNG');
const second = await context.handle({ cmd: 'clinqyTab', url: 'https://task2.test' });
await context.handle({ cmd: 'clinqyDone', tabIds: [10] });
assert(calls.some(c => c[0] === 'detach' && c[1] === 10));
assert(!calls.some(c => c[0] === 'detach' && c[1] === second.id));
tabs.get(10).audible = true; // Upstream Windows fix: playing tabs survive even when inactive.
await context.handle({ cmd: 'clinqyClear' });
assert(tabs.has(1));
assert(tabs.has(10));
assert(!tabs.has(second.id));
assert(!data.opened.includes(10));
assert.equal(data.workTabs.length, 0);
await assert.rejects(context.handle({ cmd: 'captureTask', tabId: 10 }), /wasn't opened/);
denyAttach = true;
await assert.rejects(context.handle({ cmd: 'clinqyTab', url: 'https://fail.test' }), /debugger denied/);
assert(!tabs.has(12));
assert(!data.opened.includes(12));
assert.equal(data.workTabs.length, 0);
denyAttach = false;
chrome.tabGroups.query = () => new Promise(() => {});
const arcTab = await Promise.race([
  context.handle({ cmd: 'clinqyTab', url: 'https://arc.test' }),
  new Promise((_, reject) => { const timer = setTimeout(() => reject(Error('Tab grouping blocked task creation')), 1000); timer.unref(); })
]);
assert(tabs.has(arcTab.id));
await context.handle({ cmd: 'clinqyDone' });
console.log('PASS Arc tab creation continues when tab-group APIs never resolve');
console.log('PASS inactive task tabs, emulated focus, own-tab targeting, screenshots and navigation');
console.log('PASS personal tabs rejected; task switching never activates tabs or windows');
console.log('PASS scoped detach, active result handover, stale tab cleanup and denied debugger cleanup');

const before = calls.filter(c => c[0] === 'create').length;
const originalTabQuery = chrome.tabs.query;
chrome.tabs.query = async () => { throw Error('No active-tab observation available'); };
const foreground = await context.handle({ cmd: 'newTab', url: 'https://www.example.test/', operationID: 'run:example', activity: true });
const retry = await context.handle({ cmd: 'newTab', url: 'https://example.test', operationID: 'run:example', activity: true });
assert.equal(retry.id, foreground.id);
assert.equal(calls.filter(c => c[0] === 'create').length - before, 1);
// A suspended/restarted service worker retains its request -> tab association.
const restarted = vm.createContext({ chrome, WebSocket, URL, navigator: {}, setTimeout, clearTimeout, setInterval() {}, console });
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), restarted);
assert.equal((await restarted.handle({ cmd: 'newTab', url: 'https://example.test/', operationID: 'run:example', activity: true })).id, foreground.id);
assert.equal(calls.filter(c => c[0] === 'create').length - before, 1);
await assert.rejects(context.handle({ cmd: 'newTab', url: 'https://example.test/different', operationID: 'run:example' }), /unknown outcome/);
await context.handle({ cmd: 'clinqyDone', tabIds: [], operationIDs: ['run:example'] });
assert(!data.activityTabs.includes(foreground.id));
// Looking at a completed result never reactivates its working marker.
await context.handle({ cmd: 'tabInfo', tabId: arcTab.id });
assert(!data.activityTabs.includes(arcTab.id));
tabs.delete(foreground.id);
await assert.rejects(context.handle({ cmd: 'newTab', url: 'https://example.test/', operationID: 'run:example' }), /closed/);
denyCreate = true;
await assert.rejects(context.handle({ cmd: 'newTab', url: 'https://fail.test', operationID: 'run:uncertain' }), /acknowledgement lost/);
const attempts = calls.filter(c => c[0] === 'create').length;
await assert.rejects(context.handle({ cmd: 'newTab', url: 'https://fail.test', operationID: 'run:uncertain' }), /unknown outcome/);
assert.equal(calls.filter(c => c[0] === 'create').length, attempts);
chrome.tabs.query = originalTabQuery;
console.log('PASS exactly one foreground tab across retries, equivalent URLs, stale active-tab state and worker restart');
console.log('PASS uncertain opens are not repeated, closed tabs are not recreated, completed feedback stays off');

// One tab's pending capture must not block other tabs, while commands on that same tab stay ordered.
denyCreate = false;
const parallelCallsStart = calls.length;
chrome.tabGroups.query = async () => [];
const parallelA = await context.serializedHandle({ cmd: 'clinqyTab', url: 'https://parallel-a.test' });
const parallelB = await context.serializedHandle({ cmd: 'clinqyTab', url: 'https://parallel-b.test' });
const originalSend = chrome.debugger.sendCommand;
let releaseCapture, capturesA = 0, capturesB = 0;
const pendingCapture = new Promise(resolve => { releaseCapture = resolve; });
chrome.debugger.sendCommand = async (target, method, params) => {
  if (method === 'Page.captureScreenshot' && target.tabId === parallelA.id) {
    capturesA++;
    if (capturesA === 1) await pendingCapture;
  }
  if (method === 'Page.captureScreenshot' && target.tabId === parallelB.id) capturesB++;
  return originalSend(target, method, params);
};
const firstCapture = context.serializedHandle({ cmd: 'captureTask', tabId: parallelA.id });
const orderedCapture = context.serializedHandle({ cmd: 'captureTask', tabId: parallelA.id });
await new Promise(resolve => setTimeout(resolve, 10));
const independentCapture = context.serializedHandle({ cmd: 'captureTask', tabId: parallelB.id });
await Promise.race([independentCapture, new Promise((_, reject) => { const t = setTimeout(() => reject(Error('another tab was blocked by the first task')), 500); t.unref(); })]);
assert.equal(capturesA, 1, 'same-tab second request waits');
assert.equal(capturesB, 1, 'other task proceeds while first is waiting');
releaseCapture();
await Promise.all([firstCapture, orderedCapture]);
assert.equal(capturesA, 2);
await context.serializedHandle({ cmd: 'clinqyDone', tabIds: [parallelB.id] });
assert(data.workTabs.includes(parallelA.id), 'finishing one job preserves another job ownership');
assert(calls.some(c => c[0] === 'detach' && c[1] === parallelB.id));
assert(!calls.some(c => c[0] === 'detach' && c[1] === parallelA.id));
assert(!calls.slice(parallelCallsStart).some(c => c[0] === 'focusWindow' || (c[0] === 'update' && c[2].active)), 'parallel background work never takes foreground focus');
chrome.debugger.sendCommand = originalSend;
await context.serializedHandle({ cmd: 'clinqyDone', tabIds: [parallelA.id] });
console.log('PASS parallel cross-tab commands, ordered same-tab commands, per-task cleanup and no foreground activation');

const longAssignmentURL='https://course.test/learn/programming/assignment/lab?path='+encodeURIComponent('/?folder=/home/coder/project')+'&context='+'x'.repeat(260);
tabs.get(1).url=longAssignmentURL;
const metadataBefore=calls.length;
const metadata=await context.serializedHandle({cmd:'tabs'});
assert.equal(metadata.tabs.find(tab=>tab.id===1).url,longAssignmentURL);
assert(!calls.slice(metadataBefore).some(call=>['attach','update','focusWindow','create','remove'].includes(call[0])));
await assert.rejects(context.handle({cmd:'snapshot',workOnly:true,tabId:1}),/does not belong/);
console.log('PASS existing-tab metadata preserves full lab URLs without granting page access, attaching, focusing or modifying tabs');
