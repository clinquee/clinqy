// Connects to the Clinqy app on this Mac and runs its requests against the active tab — including the pages
// embedded in it (Greenhouse/Lever job forms, payment boxes), whose elements are listed with the rest.
const URL_ = "ws://127.0.0.1:47823";
// This script's own version, kept equal to manifest.json's. Chrome can keep running an older copy of the worker after
// a reload (the manifest is re-read, the script isn't), so the app checks this one, not the manifest's.
const SCRIPT_VERSION = "1.9.16";
let socket = null;
let retry = 1000;
// A snapshot must not overwrite index maps while an earlier action is resolving its target.
const commandQueues = new Map();
// Every connection to the app gets an epoch. Work received on one is answered on that same socket only, and work
// still queued when it closes never dispatches: a replacement socket must not carry a retired request's result.
let connectionEpoch = 0;
// Requests the app gave up on (timeout/cancel) before they started running. Bounded; entries are tiny.
const cancelledIDs = new Set();
const runningIDs = new Set();
const NOT_DISPATCHED = "cancelled before dispatch";
function markCancelled(id) {
  if (typeof id !== "string" || runningIDs.has(id)) return false;   // already running: its outcome is reported, never undone
  cancelledIDs.add(id);
  if (cancelledIDs.size > 500) cancelledIDs.delete(cancelledIDs.values().next().value);
  return true;
}
function serializedHandle(msg, origin = {}) {
  // Snapshot/index mutations serialize within a tab. Different tabs can wait/read/act concurrently.
  // Creation and shared extension lifecycle/storage operations retain their own management lane.
  const tabScoped = msg.tabId != null && !["clinqyDone", "clinqyClear", "newTab", "clinqyTab", "reload"].includes(msg.cmd);
  const key = tabScoped ? `tab:${msg.tabId}` : "management";
  const previous = commandQueues.get(key) || Promise.resolve();
  const receivedAt = Date.now();
  const ttl = Number(msg.ttlMs) > 0 ? Number(msg.ttlMs) : null;
  const next = previous.then(() => {
    // The decision to run happens here, at dispatch, not at receipt: time spent behind earlier commands counts.
    if (msg.id != null && cancelledIDs.delete(msg.id)) throw new Error(NOT_DISPATCHED + ": the app stopped waiting for it");
    if (origin.epoch != null && origin.epoch !== connectionEpoch) throw new Error(NOT_DISPATCHED + ": its connection was replaced");
    if (ttl != null && Date.now() - receivedAt > ttl) throw new Error(NOT_DISPATCHED + ": it expired while queued");
    if (msg.id != null) runningIDs.add(msg.id);
    return handle(msg).finally(() => { if (msg.id != null) runningIDs.delete(msg.id); });
  });
  const tail = next.catch(() => {});
  commandQueues.set(key, tail);
  void tail.then(() => { if (commandQueues.get(key) === tail) commandQueues.delete(key); });
  return next;
}

function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  let ws;
  try { ws = new WebSocket(URL_); } catch { return; }
  socket = ws;
  const epoch = ++connectionEpoch;
  // Replies go out on the socket the request arrived on, and only while it is still the current connection.
  const reply = (obj) => { if (ws === socket && epoch === connectionEpoch && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); };
  ws.onopen = () => {
    retry = 1000;
    reply({ type: "hello", agent: navigator.userAgent, version: SCRIPT_VERSION, manifest: chrome.runtime.getManifest().version });
  };
  ws.onmessage = async (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch { return; }
    if (msg.type === "cancel") { markCancelled(msg.id); return; }
    if (!msg.id) return;
    try {
      reply({ id: msg.id, ok: true, result: await serializedHandle(msg, { epoch }) });
    } catch (err) {
      reply({ id: msg.id, ok: false, error: String(err && err.message || err) });
    }
  };
  // Back quickly when the app restarts or Chrome wakes the worker (1 s, doubling to 10 s).
  ws.onclose = () => {
    if (ws === socket) { socket = null; queueActivity(() => clinqyDone()); setTimeout(connect, retry); retry = Math.min(retry * 2, 10000); }
  };
  ws.onerror = () => {};
}

function send(obj) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab) throw new Error("no active tab");
  return tab;
}

// ---- running page.js functions in frames ----

// Runs window.__clinqy[name](...args) in a frame; errors come back as values, so one frame never sinks the rest.
// Async so a page function may return a promise (waitText); executeScript waits for it.
const runner = async (n, a, expected = null) => {
  try {
    const f = window.__clinqy && window.__clinqy[n];
    if (!f) return { __error: "no page function " + n };
    if (n === "snapshot" && a[0] && a[0].excludeTop && window === window.top) return { __error: "top frame already observed" };
    if (n === "snapshot" || n === "selection" || n === "focusStatus") return { __ok: await f(...a) };
    if (!expected) throw new Error("missing browser observation tokens; take a new look");
    const token = expected.documentID ? expected : expected[window.__clinqy.documentID];
    return { __ok: await window.__clinqy.invoke(n, a, token) };
  } catch (e) { return { __error: String(e && e.message || e) }; }
};

// Runs in the page's own world (scripts there create and click file inputs, which the extension's world can't
// intercept): clicks the element page.js marked, catching the file input it asks for, and gives it the file.
const pickerUpload = async (name, type, b64) => {
  const el = document.querySelector("[data-clinqy-up]");
  if (!el) return { ok: false, why: "the upload button is gone" };
  el.removeAttribute("data-clinqy-up");
  const proto = HTMLInputElement.prototype;
  const click = proto.click, picker = proto.showPicker;
  let caught = null;
  proto.click = function (...a) { if (this.type === "file") { caught = this; return; } return click.apply(this, a); };
  if (picker) proto.showPicker = function (...a) { if (this.type === "file") { caught = this; return; } return picker.apply(this, a); };
  // A label or real click reaching a file input opens the picker by default: catch that too.
  const onClick = (e) => { const t = e.composedPath ? e.composedPath()[0] : e.target; if (t && t.tagName === "INPUT" && t.type === "file") { caught = t; e.preventDefault(); } };
  document.addEventListener("click", onClick, true);
  try {
    el.click();
    for (let k = 0; k < 30 && !caught; k++) await new Promise((r) => setTimeout(r, 50));
  } finally {
    proto.click = click;
    if (picker) proto.showPicker = picker;
    document.removeEventListener("click", onClick, true);
  }
  if (!caught) return { ok: false, why: "clicking it didn't ask for a file" };
  const bin = atob(b64), bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const dt = new DataTransfer();
  if (caught.multiple) for (const f of caught.files || []) dt.items.add(f);
  dt.items.add(new File([bytes], name, { type: type || "application/octet-stream", lastModified: Date.now() }));
  caught.files = dt.files;
  caught.dispatchEvent(new Event("input", { bubbles: true }));
  caught.dispatchEvent(new Event("change", { bubbles: true }));
  return { ok: caught.files.length > 0, files: [...caught.files].map((f) => f.name) };
};

async function inject(target) {
  try { await chrome.scripting.executeScript({ target, files: ["page.js"] }); } catch {}
}

async function call(tabId, frameId, name, args = []) {
  const target = { tabId, frameIds: [frameId] };
  await inject(target);
  let res;
  const token = (await mapFor(tabId)).frameTokens?.[frameId] || null;
  try { [res] = await chrome.scripting.executeScript({ target, func: runner, args: [name, args, token] }); }
  catch (e) { throw new Error("the page can't be scripted: " + String(e && e.message || e)); }
  const out = res && res.result;
  if (!out) throw new Error("the page didn't answer");
  if (out.__error) throw new Error(out.__error);
  return out.__ok;
}

// Every frame's answer that worked: [{frameId, result}].
async function callAll(tabId, name, args = []) {
  const target = { tabId, allFrames: true };
  await inject(target);
  let res = [];
  const frameTokens = (await mapFor(tabId)).frameTokens || {};
  const tokens = Object.fromEntries(Object.values(frameTokens).map((t) => [t.documentID, t]));
  try { res = await chrome.scripting.executeScript({ target, func: runner, args: [name, args, tokens] }); } catch {}
  return res.filter((r) => r && r.result && !r.result.__error).map((r) => ({ frameId: r.frameId, result: r.result.__ok }));
}

// ---- element ids across frames ----
// A snapshot lists the top page's elements first, then each visible frame's; commands with an id are routed to
// the frame (and that frame's own index) the id came from. Ids are stable on a page: an element keeps its w-id
// from look to look (matched by page.js's key), so a form that shifts by one field doesn't renumber everything
// and an old id never silently means a different element. A new page (address) starts again from 0. Kept in
// session storage too, so a restarted worker still knows.

const maps = new Map();   // tabId → { items: {id: [frameId, local]}, offsets: {frameId: {x, y}}, page, keys: {key: id}, next }
const focusFrames = new Map();   // tabId → frame that had the caret at the last activeValue

async function saveMap(tabId, map) {
  maps.set(tabId, map);
  try { await chrome.storage.session.set({ ["map" + tabId]: map }); } catch {}
}

async function mapFor(tabId) {
  if (maps.has(tabId)) return maps.get(tabId);
  try {
    const s = await chrome.storage.session.get("map" + tabId);
    if (s["map" + tabId]) { maps.set(tabId, s["map" + tabId]); return s["map" + tabId]; }
  } catch {}
  return { items: [], offsets: {} };
}

async function route(tabId, index) {
  const it = ((await mapFor(tabId)).items || {})[index];
  if (!it) throw new Error("element w" + index + " isn't on the page now; take a new look");
  return { frameId: it[0], local: it[1] };
}

const pageOf = (url) => { try { const u = new URL(url); return u.origin + u.pathname; } catch { return url || ""; } };

// Gives each listed element its w-id: the one its key had on this page before, else the next unused number.
// Keys seen earlier on the page are remembered (scrolled away and back = same id); ids are never reused for
// another key, so they only grow (renumbered from 0 on a new page, or if they ever pass 999).
function assignIds(prev, url, list) {
  const page = pageOf(url);
  const same = prev && prev.page === page && prev.keys && (prev.next || 0) < 1000;
  const keys = same ? { ...prev.keys } : {};
  let next = same ? prev.next || 0 : 0;
  const used = new Set(), items = {};
  for (const { key, frameId, local, e } of list) {
    let id = key != null ? keys[key] : undefined;
    if (id === undefined || used.has(id)) { id = next++; if (key != null && keys[key] === undefined) keys[key] = id; }
    used.add(id);
    items[id] = [frameId, local];
    e.i = id;
  }
  // Remember a bounded number of keys (oldest dropped first).
  const all = Object.keys(keys);
  if (all.length > 1500) for (const k of all.slice(0, all.length - 1500)) delete keys[k];
  return { items, page, keys, next };
}

const samePage = (a, b) => {
  try { const x = new URL(a), y = new URL(b); return x.origin === y.origin && x.pathname === y.pathname; } catch { return false; }
};

// Local coordinates of a frame → the top page's, through the frame's accumulated placement (offset and CSS scale).
const toTop = (o, x, y) => ({ x: o.x + x * (o.sx || 1), y: o.y + y * (o.sy || 1) });

// Which frame is behind each visible <iframe> box. Deterministic when the browser names it (runtime.getFrameId, the
// box's frameId); URL/size matching is only the fallback for boxes without one, and only when it is unambiguous.
function associateFrames(boxes, subs, claimed) {
  const matches = [];
  const free = [];
  for (const box of boxes) {
    const sub = box.frameId != null ? subs.get(box.frameId) : null;
    if (sub && !claimed.has(box.frameId)) { claimed.add(box.frameId); matches.push({ box, frameId: box.frameId, sub }); }
    else free.push(box);
  }
  const unplaced = free.filter((b) => b.frameId == null);
  for (const [frameId, sub] of subs) {
    if (claimed.has(frameId) || !unplaced.length) continue;
    const addressed = unplaced.filter((f) => f.src && samePage(f.src, sub.url));
    let box = addressed.length === 1 ? addressed[0] : null;
    if (!box) {
      const sized = unplaced.filter((f) => Math.abs(f.w - sub.viewport.w) <= 2 && Math.abs(f.h - sub.viewport.h) <= 2);
      if (sized.length === 1) box = sized[0];
    }
    if (!box) continue;
    unplaced.splice(unplaced.indexOf(box), 1);
    free.splice(free.indexOf(box), 1);
    claimed.add(frameId);
    matches.push({ box, frameId, sub });
  }
  return { matches, unmatched: free };
}

async function snapshot(tab) {
  const top = await call(tab.id, 0, "snapshot");
  const list = top.elements.map((e) => ({ key: e.key, frameId: 0, local: e.i, e }));
  if (!top.documentID || !top.snapshotID) throw new Error("update browser page helpers before acting");
  const frameBoxes = {};
  const frameTokens = { 0: { documentID: top.documentID, snapshotID: top.snapshotID } };
  const offsets = { 0: { x: 0, y: 0, sx: 1, sy: 1 } };
  const coverage = [];   // frames that exist on the page but are not part of this observation, and why
  const elements = top.elements;
  const extraText = [];
  if (top.frames && top.frames.length) {
    const subs = new Map((await callAll(tab.id, "snapshot", [{ excludeTop: true }]))
      .filter((s) => s.frameId !== 0 && /^https?:/.test(s.result.url || "")).map((s) => [s.frameId, s.result]));
    const claimed = new Set();
    const queue = [{ parent: 0, boxes: top.frames, origin: offsets[0], depth: 1 }];
    while (queue.length) {
      const { parent, boxes, origin, depth } = queue.shift();
      const { matches, unmatched } = associateFrames(boxes, subs, claimed);
      for (const box of unmatched) {
        let host = "frame"; try { host = new URL(box.src).hostname || host; } catch {}
        coverage.push({ frame: host, src: box.src || "", status: "unreadable",
                        reason: box.src && !/^https?:/.test(box.src) ? "not an http(s) page" : "the extension could not run in it or could not tell which page it shows" });
      }
      for (const { box, frameId, sub } of matches) {
        let host = "frame";
        try { host = new URL(sub.url).hostname; } catch {}
        if (!sub.documentID || !sub.snapshotID) { coverage.push({ frame: host, src: sub.url, status: "unreadable", reason: "its page helper is out of date" }); continue; }
        if (box.rotated) { coverage.push({ frame: host, src: sub.url, status: "unreadable", reason: "the frame is rotated or skewed by CSS, so its coordinates cannot be placed" }); continue; }
        if (depth > 4) { coverage.push({ frame: host, src: sub.url, status: "unreadable", reason: "nested too deeply" }); continue; }
        const sx = origin.sx * (box.sx || 1), sy = origin.sy * (box.sy || 1);
        const placed = toTop(origin, box.x, box.y);
        const here = { x: placed.x, y: placed.y, sx, sy };
        frameTokens[frameId] = { documentID: sub.documentID, snapshotID: sub.snapshotID };
        frameBoxes[frameId] = { ...box, parent };   // raw, in the parent's own coordinates: re-checked live before input
        offsets[frameId] = here;
        for (const e of sub.elements) {
          const p = toTop(here, e.x, e.y), w = e.w * sx, h = e.h * sy;
          if (p.y + h < 0 || p.y > top.viewport.h || p.x + w < 0 || p.x > top.viewport.w) continue;
          const moved = { ...e, x: p.x, y: p.y, w, h, frame: host };
          elements.push(moved);
          list.push({ key: e.key != null ? frameId + "|" + sub.documentID + "|" + e.key : null, frameId, local: e.i, e: moved });
        }
        top.messages = (top.messages || []).concat(sub.messages || []);
        if (sub.text) extraText.push(`[${host}] ${sub.text}`);
        top.below = (top.below || 0) + (sub.below || 0);
        top.above = (top.above || 0) + (sub.above || 0);
        if (sub.panes && sub.panes.length) top.panes = (top.panes || []).concat(sub.panes.map((p) => ({ ...p, frame: host })));
        if (sub.frames && sub.frames.length) queue.push({ parent: frameId, boxes: sub.frames, origin: here, depth: depth + 1 });
      }
    }
  }
  const previous = await mapFor(tab.id);
  const snapshotID = crypto.randomUUID();
  await saveMap(tab.id, { ...assignIds(previous.documentID === top.documentID ? previous : null, top.url, list),
    documentID: top.documentID, snapshotID, frameTokens, frameBoxes, offsets, coverage });
  if (coverage.length) extraText.push("[frames not read: " + coverage.map((c) => `${c.frame} (${c.reason})`).join("; ") + "]");
  if (extraText.length) top.text = [top.text, ...extraText].filter(Boolean).join(" · ").slice(0, 2400);
  return { ...top, snapshotID, elements, tabId: tab.id, active: !!tab.active, frameCoverage: coverage };
}

// A frame's box, and every ancestor's, must still be where the observation saw it: same node, same geometry.
async function frameChainStable(tabId, map, frameId) {
  for (let f = frameId, guard = 0; f !== 0 && guard < 8; guard++) {
    const observed = map.frameBoxes && map.frameBoxes[f];
    if (!observed) return false;
    const live = (await call(tabId, observed.parent ?? 0, "frameBoxes")).frames || [];
    const current = live.find((box) => box.nodeToken === observed.nodeToken);
    if (!current || ["x", "y", "w", "h"].some((key) => Math.abs(current[key] - observed[key]) > 0.5)
        || Math.abs((current.sx || 1) - (observed.sx || 1)) > 0.01 || Math.abs((current.sy || 1) - (observed.sy || 1)) > 0.01 || current.rotated) return false;
    f = observed.parent ?? 0;
    if (f === 0) return true;
  }
  return frameId === 0;
}

// The frame that has the caret: the top page, or a frame inside it when the top page's focus is on an <iframe>
// (at any depth: only the frame that holds the caret reports focus without pointing at a frame of its own).
// Blank/srcdoc frames count too — rich-text editors (TinyMCE, CKEditor) type into one.
async function focusedFrame(tabId) {
  const top = await call(tabId, 0, "activeValue");
  if (!top.frame) return { frameId: 0, info: top };
  const frames = (await callAll(tabId, "activeValue")).filter(({ frameId, result }) =>
    frameId !== 0 && /^(https?:|about:|file:)/.test(result.url || "") && !result.frame);
  const hit = frames.find(({ result }) => result.hasFocus && result.editable) || frames.find(({ result }) => result.hasFocus);
  if (hit) return { frameId: hit.frameId, info: { ...hit.result, inFrame: true } };
  return { frameId: 0, info: top };   // e.g. Google Docs' own typing frame: keys land there, the app pastes
}

// ---- tabs ----
// Tabs Clinqy opened (only those may be closed by it), kept across worker restarts.
async function openedTabs() {
  try { return new Set((await chrome.storage.session.get("opened")).opened || []); } catch { return new Set(); }
}
async function setOpened(set) {
  try { await chrome.storage.session.set({ opened: [...set] }); } catch {}
}

// Cosmetic feedback is independent of the action protocol: failure to draw it never retries input.
async function activityTabs() {
  try { return (await chrome.storage.session.get("activityTabs")).activityTabs || []; } catch { return []; }
}
async function renderActivity(tabId, state) {
  try {
    const target = { tabId, frameIds: [0] };
    if (state.active !== false) await chrome.scripting.executeScript({ target, files: ["activity.js"] });
    await chrome.scripting.executeScript({ target, func: state => window.__clinqyActivity?.update(state), args: [state] });
  } catch {} // restricted pages and navigating documents may refuse scripts
}
let activityUpdates = Promise.resolve();
function updateActivity(operation) {
  const next = activityUpdates.then(operation);
  activityUpdates = next.catch(() => {});
  return next;
}
async function showActivity(tabId, state = {}) {
  return updateActivity(async () => {
    const active = await activityTabs();
    if (!active.includes(tabId)) await chrome.storage.session.set({ activityTabs: [...active, tabId] });
    await renderActivity(tabId, state);
  });
}
async function finishActivity(tabIds) {
  return updateActivity(async () => {
    const active = await activityTabs();
    for (const id of active.filter(id => !tabIds || tabIds.includes(id))) await renderActivity(id, { active: false });
    await chrome.storage.session.set({ activityTabs: active.filter(id => tabIds && !tabIds.includes(id)) });
  });
}

function navigationKey(raw) {
  try {
    const url = new URL(raw.includes("://") ? raw : "https://" + raw);
    url.hostname = url.hostname.replace(/^www\./, "");
    return url.pathname === "/" ? url.href.replace(/\/(?=[?#]|$)/, "") : url.href;
  } catch { return raw; }
}

// Retries after a lost native acknowledgement must resolve to the same tab, even after worker suspension.
async function foregroundTab(msg) {
  const token = typeof msg.operationID === "string" ? msg.operationID : null;
  const requests = (await chrome.storage.session.get("tabRequests")).tabRequests || {};
  if (token && requests[token]) {
    const previous = requests[token];
    if (navigationKey(previous.url) !== navigationKey(msg.url) || previous.id == null) throw new Error("The earlier tab open has an unknown outcome; inspect the browser before trying again");
    const tab = await chrome.tabs.get(previous.id); // A closed tab is not silently recreated.
    await chrome.tabs.update(tab.id, { active: true });
    if (msg.activity) await showActivity(tab.id);
    return { id: tab.id };
  }
  if (token) {
    requests[token] = { url: msg.url }; // reserve before creation: a crash cannot turn a retry into another tab
    const keys = Object.keys(requests);
    for (const old of keys.slice(0, Math.max(0, keys.length - 100))) delete requests[old];
    await chrome.storage.session.set({ tabRequests: requests });
  }
  const tab = await chrome.tabs.create({ url: msg.url, active: true });
  const mine = await openedTabs(); mine.add(tab.id); await setOpened(mine);
  if (token) {
    requests[token] = { url: msg.url, id: tab.id };
    await chrome.storage.session.set({ tabRequests: requests });
  }
  if (msg.activity) await showActivity(tab.id);
  return { id: tab.id };
}

// ---- background runs ----

// A background run works in Clinqy's own window, opened without focus behind the user's, and its input goes to the
// tab through the debugger protocol: trusted clicks and keys that need neither the mouse, the keyboard nor a focused
// window. Chrome shows its "is debugging this browser" bar while attached; only Clinqy's own tabs are ever attached.
// Clinqy's window is remembered in local storage: session storage goes with every reload of the extension (each
// app update), which would orphan the window. Window ids only hold within one run of the browser, so it's
// forgotten when the browser starts.
chrome.runtime.onStartup.addListener(() => chrome.storage.local.remove("agentWin"));

async function agentWindow() {
  try {
    const { agentWin } = await chrome.storage.local.get("agentWin");
    if (agentWin != null) return await chrome.windows.get(agentWin);
  } catch {}
  return null;
}

// `at` is where the window goes: Clinqy's hidden screen (left, top, width, height in screen points), when it has one.
async function backgroundTab(url, at) {
  const win = await agentWindow();
  let t;
  if (win) {
    t = await chrome.tabs.create({ windowId: win.id, url, active: true });
    if (at) { try { await chrome.windows.update(win.id, { ...at, state: "normal" }); } catch {} }
  } else {
    const w = await chrome.windows.create({ url, focused: false, ...(at || { width: 1280, height: 900 }) });
    t = w.tabs[0];
    try { await chrome.storage.local.set({ agentWin: w.id }); } catch {}
  }
  const mine = await openedTabs();
  mine.add(t.id);
  await setOpened(mine);
  // Where the window really is (a browser may not place it where asked): the app moves it there itself.
  const w = await chrome.windows.get(t.windowId);
  return { id: t.id, windowId: t.windowId, bounds: { x: w.left, y: w.top, w: w.width, h: w.height } };
}

// A task in the user's own browser works in a tab of its own, in a "Clinqy" group beside theirs. It's never made active,
// so they keep the tab and window they're in. Metrics and focus are emulated because a tab out of sight has no size and
// counts as hidden. Only tabs Clinqy opened are touched, and it lets go of them when the task ends.
async function workTabs() {
  try { return (await chrome.storage.session.get("workTabs")).workTabs || []; } catch { return []; }
}

async function clinqyGroup(tabId, windowId) {
  if (!chrome.tabGroups) return;
  const [group] = await chrome.tabGroups.query({ title: "Clinqy", windowId });
  const id = await chrome.tabs.group(group ? { tabIds: tabId, groupId: group.id } : { tabIds: tabId, createProperties: { windowId } });
  if (!group) await chrome.tabGroups.update(id, { title: "Clinqy", color: "blue", collapsed: false });
}

async function clinqyTab(url, width, height) {
  const [front] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const t = await chrome.tabs.create({ ...(front ? { windowId: front.windowId } : {}), url, active: false });
  const mine = await openedTabs();
  mine.add(t.id);
  await setOpened(mine);
  // Arc exposes tab-group APIs whose promises can remain pending. Grouping is cosmetic;
  // it must never hold up attaching to or driving the owned tab.
  void clinqyGroup(t.id, t.windowId).catch(() => {});
  try { await chrome.storage.session.set({ workTabs: [...await workTabs(), t.id], workSize: { width, height } }); } catch {}
  try {
    await cdp(t.id, "Page.enable");
  } catch (error) {
    // A denied debugger permission must not leave an orphan task tab behind.
    try { await chrome.debugger.detach({ tabId: t.id }); } catch {}
    attached.delete(t.id);
    try { await chrome.tabs.remove(t.id); } catch {}
    mine.delete(t.id);
    await setOpened(mine);
    await chrome.storage.session.set({ workTabs: (await workTabs()).filter(id => id !== t.id) });
    throw error;
  }
  await showActivity(t.id);
  return { id: t.id };
}

async function prepareWorkTab(tabId) {
  const target = { tabId };
  const { workSize } = await chrome.storage.session.get("workSize");
  await chrome.debugger.sendCommand(target, "Page.enable");
  // A hidden task must never open a native file picker over the user’s work. Uploads use page fields directly.
  await chrome.debugger.sendCommand(target, "Page.setInterceptFileChooserDialog", { enabled: true });
  try { await chrome.debugger.sendCommand(target, "Page.setDownloadBehavior", { behavior: "default" }); } catch {}   // lifecycle events; best effort
  await chrome.debugger.sendCommand(target, "Emulation.setFocusEmulationEnabled", { enabled: true });
  await chrome.debugger.sendCommand(target, "Emulation.setDeviceMetricsOverride", { ...(workSize || { width: 1280, height: 900 }), deviceScaleFactor: 1, mobile: false });
}

// The task ended: Chrome's debugging bar goes, and the tab behaves normally if the user looks at it.
async function clinqyDone(tabIds) {
  await finishActivity(tabIds);
  const owned = await workTabs();
  for (const tabId of tabIds ? owned.filter(id => tabIds.includes(id)) : owned) {
    try { await chrome.debugger.detach({ tabId }); } catch {}
    attached.delete(tabId);
  }
  return { done: true };
}

// The next task starts: the last one's tabs go, except one the user is on or one playing sound, which are theirs now.
async function clinqyClear() {
  await clinqyDone();
  const keep = [];
  for (const tabId of await workTabs()) {
    try {
      const t = await chrome.tabs.get(tabId);
      if (t.active || t.audible) {
        const mine = await openedTabs();
        mine.delete(tabId);
        await setOpened(mine);
      } else {
        await chrome.tabs.remove(tabId);
      }
    } catch {}
  }
  try { await chrome.storage.session.set({ workTabs: keep }); } catch {}
  return { cleared: true };
}

const attached = new Set();

// Chrome can run this script with an older manifest's permissions until the extension is reloaded: without the
// debugger permission only the debugger-based actions are unavailable, and everything else has to keep working.
// Per-tab record of things the page did on its own while a command ran: JS dialogs (and what was decided),
// file-chooser requests and downloads. Drained into the next result for that tab, so the app can see them.
const tabEvents = new Map();   // tabId → [event]
const downloads = new Map();   // guid → { tabId, url, filename, state, received, total }
const dialogPolicy = new Map(); // tabId → { accept, text, persistent }
function recordEvent(tabId, event) {
  if (tabId == null) return;
  const list = tabEvents.get(tabId) || [];
  list.push({ ...event, at: Date.now() });
  if (list.length > 50) list.shift();
  tabEvents.set(tabId, list);
}
function drainEvents(tabId) {
  const list = tabEvents.get(tabId) || [];
  tabEvents.delete(tabId);
  return list;
}
// Decision for a JS dialog. Nothing is confirmed on the user's behalf by default: an alert has only one answer
// (accept), leaving a page (beforeunload) is what navigation asked for, and confirm/prompt are dismissed unless the
// app set an explicit decision for the tab (cmd "dialogPolicy"). Every decision is reported with the dialog's text.
function dialogDecision(tabId, params) {
  const explicit = dialogPolicy.get(tabId);
  if (explicit) {
    if (!explicit.persistent) dialogPolicy.delete(tabId);
    return { accept: !!explicit.accept, promptText: explicit.text, basis: "explicit" };
  }
  return { accept: params.type === "alert" || params.type === "beforeunload", basis: "default" };
}
function onDebuggerEvent(source, method, params = {}) {
  const tabId = source && source.tabId;
  if (method === "Page.javascriptDialogOpening") {
    // A dialog would hold a tab nobody is looking at forever, so it is always answered, and the answer is recorded.
    const d = dialogDecision(tabId, params);
    const event = { kind: "dialog", type: params.type, message: String(params.message || "").slice(0, 500), url: params.url,
                    decision: d.accept ? "accepted" : "dismissed", basis: d.basis };
    if (params.type === "prompt") event.defaultPrompt = params.defaultPrompt;
    recordEvent(tabId, event);
    chrome.debugger.sendCommand(source, "Page.handleJavaScriptDialog", { accept: d.accept, ...(d.promptText != null ? { promptText: String(d.promptText) } : {}) })
      .catch((e) => recordEvent(tabId, { kind: "dialog", type: params.type, decision: "unanswered", error: String(e && e.message || e) }));
  } else if (method === "Page.fileChooserOpened") {
    // The task tab never opens a native picker. The chooser is reported, not silently swallowed: the extension has
    // no file path to hand the browser, so uploads use uploadVia/upload against the page's own file inputs.
    recordEvent(tabId, { kind: "fileChooser", mode: params.mode, state: "intercepted; not fulfilled" });
  } else if (method === "Page.downloadWillBegin" || method === "Browser.downloadWillBegin") {
    downloads.set(params.guid, { tabId, url: params.url, filename: params.suggestedFilename, state: "started", received: 0, total: null });
    recordEvent(tabId, { kind: "download", phase: "started", guid: params.guid, url: params.url, filename: params.suggestedFilename });
  } else if (method === "Page.downloadProgress" || method === "Browser.downloadProgress") {
    const known = downloads.get(params.guid) || { tabId, state: "started" };
    known.state = params.state; known.received = params.receivedBytes; known.total = params.totalBytes;
    downloads.set(params.guid, known);
    if (params.state !== "inProgress") {
      recordEvent(known.tabId ?? tabId, { kind: "download", phase: params.state === "completed" ? "completed" : params.state, guid: params.guid,
                                          url: known.url, filename: known.filename, bytes: params.totalBytes ?? params.receivedBytes });
    }
  }
}
if (chrome.debugger) {
  chrome.debugger.onDetach.addListener((source) => attached.delete(source.tabId));
  chrome.debugger.onEvent.addListener(onDebuggerEvent);
}

async function cdp(tabId, method, params = {}) {
  if (!attached.has(tabId)) {
    const mine = await openedTabs();
    if (!mine.has(tabId)) throw new Error("tab " + tabId + " wasn't opened by Clinqy, so it isn't driven in the background");
    if (!chrome.debugger) throw new Error("reload the Clinqy extension to allow this action");
    try { await chrome.debugger.attach({ tabId }, "1.3"); }
    catch (e) { if (!/already attached/i.test(String(e && e.message || e))) throw e; }
    attached.add(tabId);
    if ((await workTabs()).includes(tabId)) await prepareWorkTab(tabId);
  }
  return await chrome.debugger.sendCommand({ tabId }, method, params);
}

// Named keys as the protocol wants them (key, code, Windows key code, and the text a key types).
const KEYS = {
  enter: ["Enter", "Enter", 13, "\r"], return: ["Enter", "Enter", 13, "\r"], tab: ["Tab", "Tab", 9],
  esc: ["Escape", "Escape", 27], escape: ["Escape", "Escape", 27], space: ["Space", " ", 32, " "],
  delete: ["Backspace", "Backspace", 8], backspace: ["Backspace", "Backspace", 8], forwarddelete: ["Delete", "Delete", 46],
  up: ["ArrowUp", "ArrowUp", 38], down: ["ArrowDown", "ArrowDown", 40], left: ["ArrowLeft", "ArrowLeft", 37],
  right: ["ArrowRight", "ArrowRight", 39], home: ["Home", "Home", 36], end: ["End", "End", 35],
  pageup: ["PageUp", "PageUp", 33], pagedown: ["PageDown", "PageDown", 34],
};
// ⌘-shortcuts that are editing commands on a Mac (the renderer doesn't map synthetic ⌘ keys to them itself).
const COMMANDS = { a: "selectAll", c: "copy", x: "cut", v: "paste", z: "undo" };

async function cdpKey(tabId, combo) {
  const parts = String(combo).toLowerCase().split("+").map((s) => s.trim()).filter(Boolean);
  const name = parts.pop() || "";
  const mods = { alt: 1, option: 1, opt: 1, ctrl: 2, control: 2, cmd: 4, command: 4, meta: 4, shift: 8 };
  const modifiers = parts.reduce((m, p) => m | (mods[p] || 0), 0);
  let [key, code, vk, text] = KEYS[name] || [];
  if (!key) {
    if (name.length !== 1) throw new Error("unknown key " + combo);
    key = modifiers & 8 ? name.toUpperCase() : name;
    code = /[a-z]/.test(name) ? "Key" + name.toUpperCase() : /[0-9]/.test(name) ? "Digit" + name : "";
    vk = name.toUpperCase().charCodeAt(0);
    text = modifiers & ~8 ? undefined : key;
  }
  const commands = modifiers === 4 && COMMANDS[name] ? [COMMANDS[name]]
    : modifiers === 12 && name === "z" ? ["redo"] : undefined;
  const base = { key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers };
  await cdp(tabId, "Input.dispatchKeyEvent", { ...base, type: text ? "keyDown" : "rawKeyDown", text, unmodifiedText: text, commands });
  await cdp(tabId, "Input.dispatchKeyEvent", { ...base, type: "keyUp" });
  return { pressed: combo };
}

async function cdpClick(tabId, x, y, count = 1) {
  const at = { x: Number(x), y: Number(y) };
  await cdp(tabId, "Input.dispatchMouseEvent", { type: "mouseMoved", ...at });
  for (let i = 1; i <= count; i++) {
    await cdp(tabId, "Input.dispatchMouseEvent", { type: "mousePressed", ...at, button: "left", buttons: 1, clickCount: i });
    await cdp(tabId, "Input.dispatchMouseEvent", { type: "mouseReleased", ...at, button: "left", buttons: 0, clickCount: i });
  }
  return { clicked: at };
}

// Endpoint identity is checked before any pointer input. A lost acknowledgement never triggers a retry.
async function cdpGesture(tabId, msg) {
  if (!["hover", "right_click", "double_click", "drag"].includes(msg.gesture)) throw Error("unknown gesture");
  const map = await mapFor(tabId);
  async function point(index) {
    if (!Number.isInteger(index)) throw Error("gesture needs element ids");
    const { frameId, local } = await route(tabId, index);
    if (frameId !== 0 && !(await frameChainStable(tabId, map, frameId))) throw Error("gesture frame moved; observe again");
    const spot = await call(tabId, frameId, "locate", [local, false]);
    const offset = map.offsets[frameId];
    if (!offset || !spot.hit || !spot.still) throw Error("gesture target moved or is covered; observe again");
    const result = toTop(offset, Number(spot.px), Number(spot.py));
    if (!Number.isFinite(result.x) || !Number.isFinite(result.y)) throw Error("invalid gesture point");
    return result;
  }
  const destination = msg.gesture === "drag" ? await point(msg.toIndex) : null;
  const start = await point(msg.index);
  const button = msg.gesture === "right_click" ? "right" : "left", buttons = button === "right" ? 2 : 1;
  let held = false, last = start;
  const post = args => cdp(tabId, "Input.dispatchMouseEvent", args);
  try {
    await post({ type: "mouseMoved", ...start, button: "none", buttons: 0 });
    if (msg.gesture !== "hover") {
      for (let count = 1; count <= (msg.gesture === "double_click" ? 2 : 1); count++) {
        held = true;
        await post({ type: "mousePressed", ...start, button, buttons, clickCount: count });
        if (destination) for (let step = 1; step <= 12; step++) {
          last = { x: start.x + (destination.x - start.x) * step / 12, y: start.y + (destination.y - start.y) * step / 12 };
          await post({ type: "mouseMoved", ...last, button, buttons });
          await new Promise(resolve => setTimeout(resolve, 20));
        }
        await post({ type: "mouseReleased", ...last, button, buttons: 0, clickCount: count });
        held = false;
      }
    }
  } finally {
    if (held) await post({ type: "mouseReleased", ...last, button, buttons: 0, clickCount: 1 }).catch(() => {});
  }
  return { delivered: true, verified: false };
}

function queueActivity(update) {
  const previous = commandQueues.get("management") || Promise.resolve();
  const next = previous.then(update).catch(() => {});
  commandQueues.set("management", next);
}

if (chrome.tabs.onUpdated) chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "complete") queueActivity(async () => {
    if ((await activityTabs()).includes(tabId)) await renderActivity(tabId, { kind: "working" });
  });
});

chrome.tabs.onRemoved.addListener((tabId) => queueActivity(async () => {
  await finishActivity([tabId]);
  attached.delete(tabId);
  maps.delete(tabId);
  focusFrames.delete(tabId);
  tabEvents.delete(tabId);
  dialogPolicy.delete(tabId);
  try { await chrome.storage.session.remove("map" + tabId); } catch {}
  const mine = await openedTabs();
  if (mine.delete(tabId)) await setOpened(mine);
}));

async function tabCommand(msg) {
  const tabId = Number(msg.tabId);
  switch (msg.cmd) {
    case "tabs": {
      // The tabs of the window in front, in strip order.
      const cur = await activeTab();
      const mine = await openedTabs();
      const list = await chrome.tabs.query({ windowId: cur.windowId });
      return { windowId: cur.windowId, tabs: list.map((t) => ({ id: t.id, title: (t.title || "").slice(0, 100), url: (t.url || t.pendingUrl || "").slice(0, 4096),
                                                                active: !!t.active, opened: mine.has(t.id), loading: t.status === "loading" })) };
    }
    case "switchTab": {
      const t = await chrome.tabs.update(tabId, { active: true });
      try { await chrome.windows.update(t.windowId, { focused: true }); } catch {}
      return { id: t.id, title: t.title || "", url: t.url || t.pendingUrl || "" };
    }
    case "closeTab": {
      const mine = await openedTabs();
      if (!mine.has(tabId)) throw new Error("tab " + tabId + " wasn't opened by Clinqy, so it stays open");
      await chrome.tabs.remove(tabId);
      mine.delete(tabId);
      await setOpened(mine);
      return { closed: tabId };
    }
  }
  return null;
}

// Tokens and page-initiated events travel with every tab-scoped result, so a caller never has to guess which
// observation an outcome belongs to or whether a dialog/download happened while it ran.
async function handle(msg) {
  const out = await handleCommand(msg);
  const id = msg.tabId != null && msg.tabId !== "" ? Number(msg.tabId) : null;
  if (id == null || !Number.isInteger(id) || !out || typeof out !== "object" || Array.isArray(out)) return out;
  const events = drainEvents(id);
  if (events.length && out.events === undefined) out.events = events;
  if (!["snapshot", "tabs", "tabInfo", "newTab", "clinqyTab", "switchTab", "closeTab", "clinqyDone"].includes(msg.cmd) && out.observation === undefined) {
    const map = maps.get(id);
    if (map && map.documentID) out.observation = { documentID: map.documentID, snapshotID: map.snapshotID };
  }
  return out;
}

async function handleCommand(msg) {
  if (msg.cmd === "reload") { setTimeout(() => chrome.runtime.reload(), 100); return { reloading: true }; }
  if (msg.cmd === "version") return { version: SCRIPT_VERSION, manifest: chrome.runtime.getManifest().version };
  // Task commands are explicitly scoped: they cannot fall through to the user's active tab.
  if (msg.workOnly) {
    const owned = await workTabs();
    if (msg.cmd === "tabs") {
      const tabs = [];
      for (const id of owned) {
        try {
          const t = await chrome.tabs.get(id);
          tabs.push({ id, title: t.title || "", url: t.url || t.pendingUrl || "", opened: true });
        } catch {}
      }
      return { tabs };
    }
    if (msg.cmd === "newTab") throw new Error("Use clinqyTab to create an inactive task tab");
    if (msg.tabId == null || !owned.includes(Number(msg.tabId)))
      throw new Error("This tab does not belong to Clinqy's task");
    if (msg.cmd === "switchTab") return { id: Number(msg.tabId) };
  }
  if (/^(tabs|switchTab|closeTab)$/.test(msg.cmd)) return await tabCommand(msg);
  if (msg.cmd === "backgroundTab") return await backgroundTab(msg.url, msg.at);
  if (msg.cmd === "clinqyTab") return await clinqyTab(msg.url, Number(msg.width) || 1280, Number(msg.height) || 900);
  if (msg.cmd === "clinqyDone") {
    let ids = msg.tabIds;
    if (msg.operationIDs?.length) {
      const requests = (await chrome.storage.session.get("tabRequests")).tabRequests || {};
      ids = [...new Set([...(ids || []), ...msg.operationIDs.map(token => requests[token]?.id).filter(Number.isInteger)])];
    }
    return await clinqyDone(ids);
  }
  if (msg.cmd === "clinqyClear") return await clinqyClear();
  // A window Clinqy left behind (it quit without closing it) goes; one the user took over is only forgotten.
  if (msg.cmd === "closeAgentWindow" || msg.cmd === "releaseAgentWindow") {
    const win = await agentWindow();
    try { await chrome.storage.local.remove("agentWin"); } catch {}
    if (win && msg.cmd === "closeAgentWindow") { await chrome.windows.remove(win.id); return { closed: win.id }; }
    return { closed: null };
  }
  if (msg.cmd === "newTab") return await foregroundTab(msg);
  // Every action is pinned to its explicit observed tab when available.
  const tab = msg.tabId != null ? await chrome.tabs.get(Number(msg.tabId)) : await activeTab();
  if (msg.activity || (await activityTabs()).includes(tab.id)) {
    const kind = /^(cdpClick|click|clickOption)$/.test(msg.cmd) ? "click"
      : /^(cdpType|fill|fillActive)$/.test(msg.cmd) ? "type"
      : /^(scroll|cdpScroll)$/.test(msg.cmd) ? "scroll" : "working";
    const state = { kind };
    if (msg.x != null && msg.y != null) { state.x = Number(msg.x); state.y = Number(msg.y); }
    else if (Number.isInteger(msg.index) && ["locate", "focus", "focusFor", "click", "fill", "prepare", "upload"].includes(msg.cmd)) {
      try {
        const { frameId, local } = await route(tab.id, msg.index);
        const point = await call(tab.id, frameId, "activityPoint", [local]);
        const offset = (await mapFor(tab.id)).offsets?.[frameId];
        if (point && offset) { const p = toTop(offset, point.x, point.y); state.x = p.x; state.y = p.y; }
      } catch {}
    }
    await showActivity(tab.id, state);
  }
  if (msg.cmd === "selection") {
    const win = await chrome.windows.get(tab.windowId);
    if (!/^(https?|file):/.test(tab.url || "")) return { focused: !!win.focused, text: "" };
    const found = (await callAll(tab.id, "selection")).sort((a, b) => a.frameId - b.frameId).map((r) => r.result).find((t) => t && t.trim());
    return { focused: !!win.focused, text: found || "" };
  }
  if (msg.cmd === "captureTask") {
    // The debugger helper only accepts tabs opened by Clinqy. Never activate a tab or capture the user's display.
    if (msg.tabId == null) throw new Error("task screenshot requires an explicit tab");
    const captured = await cdp(tab.id, "Page.captureScreenshot", {
      format: msg.format || "png", ...(msg.quality ? { quality: Number(msg.quality) } : {}), fromSurface: true, captureBeyondViewport: false
    });
    // Freshness/coverage: which observation this picture matches, when it was taken, and what it can show.
    const meta = { capturedAt: Date.now(), coverage: "viewport", beyondViewport: false };
    const map = await mapFor(tab.id);
    if (map.documentID) { meta.documentID = map.documentID; meta.snapshotID = map.snapshotID; }
    try { await call(tab.id, 0, "check"); meta.matchesObservation = true; } catch { meta.matchesObservation = false; }
    try {
      const m = await cdp(tab.id, "Page.getLayoutMetrics");
      const v = m && m.cssVisualViewport;
      if (v) meta.viewport = { x: v.pageX, y: v.pageY, w: v.clientWidth, h: v.clientHeight, scale: v.scale };
    } catch {}
    return { image: captured.data, tabId: tab.id, ...meta };
  }
  if (msg.cmd === "tabInfo") {
    const win = await chrome.windows.get(tab.windowId);
    return { id: tab.id, url: tab.url || tab.pendingUrl || "", status: tab.status, title: tab.title || "", focused: !!win.focused };
  }
  if (msg.cmd === "dialogPolicy") {
    // The app's explicit decision for the next dialog on this owned tab (or every one, when persistent).
    if (msg.clear) dialogPolicy.delete(tab.id);
    else dialogPolicy.set(tab.id, { accept: !!msg.accept, text: msg.text, persistent: !!msg.persistent });
    return { dialogPolicy: msg.clear ? null : { accept: !!msg.accept, persistent: !!msg.persistent } };
  }
  if (msg.cmd === "downloadStatus") {
    return { downloads: [...downloads.entries()].filter(([, d]) => d.tabId === tab.id).map(([guid, d]) => ({ guid, ...d })) };
  }
  const unguarded = new Set(["snapshot", "goBack", "navigate"]);
  if (!unguarded.has(msg.cmd)) {
    const map = await mapFor(tab.id);
    if (msg.documentID !== map.documentID || msg.snapshotID !== map.snapshotID || !map.documentID || !map.snapshotID)
      throw new Error("stale browser observation; update the extension and take a new look");
    await call(tab.id, 0, "check");
    if (["cdpKey", "cdpType", "cdpScroll"].includes(msg.cmd)) {
      // A child can reload without changing its parent's URL or document token.
      for (const frame of Object.keys(map.frameTokens || {}).map(Number)) await call(tab.id, frame, "check");
      const statuses = await callAll(tab.id, "focusStatus");
      const leaves = statuses.filter(({ result }) => result.hasFocus && !result.frame);
      for (const { frameId, result } of leaves) {
        if (map.frameTokens?.[frameId]?.documentID !== result.documentID)
          throw new Error("the focused embedded document was not observed; take a new look before input");
      }
      const top = statuses.find(({ frameId }) => frameId === 0);
      if (!top || (top.result.frame && !leaves.length))
        throw new Error("the focused embedded document cannot be verified; take a new look before input");
    }
    if (msg.cmd === "cdpClick" && Number.isInteger(msg.index)) {
      const { frameId, local } = await route(tab.id, msg.index);
      if (frameId !== 0 && !(await frameChainStable(tab.id, map, frameId)))
        throw new Error("the embedded frame moved or was replaced; take a new look");
      const spot = await call(tab.id, frameId, "locate", [local]);
      const offset = map.offsets[frameId];
      const at = offset && toTop(offset, spot.px, spot.py);
      if (!offset || !spot.hit || !spot.still || Math.abs(Number(msg.x) - at.x) > 2 || Math.abs(Number(msg.y) - at.y) > 2)
        throw new Error("the click target moved or was covered; take a new look");
    }
  }
  if (msg.cmd === "cdpGesture") return await cdpGesture(tab.id, msg);
  if (msg.cmd === "cdpClick") return await cdpClick(tab.id, msg.x, msg.y, Number(msg.count) || 1);
  if (msg.cmd === "cdpKey") return await cdpKey(tab.id, msg.keys);
  if (msg.cmd === "cdpType") { await cdp(tab.id, "Input.insertText", { text: String(msg.text) }); return { typed: true }; }
  if (msg.cmd === "cdpScroll") {
    await cdp(tab.id, "Input.dispatchMouseEvent", { type: "mouseWheel", x: Number(msg.x) || 200, y: Number(msg.y) || 200, deltaX: 0, deltaY: Number(msg.dy) });
    return { scrolled: msg.dy };
  }
  if (msg.cmd === "goBack") {
    try { await chrome.tabs.goBack(msg.tabId); } catch {}
    return { ok: true };
  }
  if (msg.cmd === "navigate") {
    await chrome.tabs.update(tab.id, { url: msg.url });
    return { url: msg.url };
  }
  const page = /^(https?|file):/.test(tab.url || "");
  if (!page) {
    const win = await chrome.windows.get(tab.windowId);
    return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], restricted: true,
             error: "this tab is a browser page (new tab, settings, extensions) that extensions can't read" };
  }
  const indexed = async (name, extra = []) => {
    const { frameId, local } = await route(tab.id, msg.index);
    return await call(tab.id, frameId, name, [local, ...extra]);
  };
  switch (msg.cmd) {
    case "values": {
      const groups = new Map(), result = {};
      for (const index of (msg.indices || []).slice(0, 200)) {
        const { frameId, local } = await route(tab.id, index);
        if (!groups.has(frameId)) groups.set(frameId, []);
        groups.get(frameId).push([index, local]);
      }
      await Promise.all([...groups].map(async ([frameId, items]) => {
        const reply = await call(tab.id, frameId, "values", [items.map(([, local]) => local)]);
        for (const [global, local] of items) result[String(global)] = reply.values[String(local)] ?? null;
      }));
      return { values: result };
    }
    case "snapshot": {
      // "Focused" = this browser's window is the focused one (the page itself may not have keyboard focus
      // right after typing in the address bar). A page that can't be read says why instead of looking empty.
      const win = await chrome.windows.get(tab.windowId);
      // A discarded (memory-saver) tab has no page to script until it's shown again.
      if (tab.discarded) return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], tabId: tab.id, active: !!tab.active,
                                  error: "this tab is asleep (discarded by the browser); switch to it first" };
      try { return { ...(await snapshot(tab)), focused: !!win.focused }; }
      catch (e) {
        const why = String(e && e.message || e);
        const blocked = /can't be scripted|cannot be scripted|cannot access|web store|extensions gallery/i.test(why);
        return { url: tab.url, title: tab.title, focused: !!win.focused, elements: [], restricted: blocked,
                 error: blocked ? "this page blocks extensions (e.g. the Chrome Web Store or a built-in PDF viewer)" : "reading the page failed: " + why };
      }
    }
    case "click": case "focus": case "value": case "isActive": case "prepare": case "state": case "chosen":
    case "alive": case "focusFor":
      return await indexed(msg.cmd);
    case "clickOption": {
      const frame = Number(msg.pointFrame);
      if (!Number.isInteger(frame) || !(await mapFor(tab.id)).frameTokens?.[frame] || typeof msg.pointToken !== "string")
        throw new Error("the option has no current target token; take a new look");
      return await call(tab.id, frame, "clickOption", [msg.pointToken]);
    }
    case "activeOption": return await indexed("activeOption", [msg.want || ""]);
    case "locate": {
      // In top-page coordinates, so a frame's element (LinkedIn's Easy Apply form) is placed right too.
      const { frameId, local } = await route(tab.id, msg.index);
      const r = await call(tab.id, frameId, "locate", [local, msg.reveal !== false]);
      const o = ((await mapFor(tab.id)).offsets || {})[frameId];
      if (!o) return { ...r, hit: frameId === 0 && r.hit };
      return { ...r, ...toTop(o, r.x, r.y), px: toTop(o, r.px, r.py).x, py: toTop(o, r.px, r.py).y };
    }
    case "uploadVia": {
      // The site's own upload button: click it in the page's world with file inputs' click()/showPicker() caught,
      // so the file goes into the input it asks for (often one it creates on the spot) and no Mac picker opens.
      const { frameId, local } = await route(tab.id, msg.index);
      await call(tab.id, frameId, "markUpload", [local]);
      let res;
      try {
        [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [frameId] }, world: "MAIN",
                                                       func: pickerUpload, args: [msg.name, msg.type, msg.data] });
      } catch (e) { throw new Error("the page can't be scripted: " + String(e && e.message || e)); }
      return (res && res.result) || { ok: false, why: "the page didn't answer" };
    }
    case "fill": return await indexed("fill", [msg.text]);
    case "waitText": return await call(tab.id, 0, "waitText", [msg.text, !!msg.gone, Number(msg.ms) || 10000]);
    case "upload": {
      if (msg.index >= 0) return await indexed("upload", [msg.name, msg.type, msg.data]);
      const map = await mapFor(tab.id);
      const counts = [];
      for (const frame of Object.keys(map.frameTokens || {}).map(Number)) {
        const result = await call(tab.id, frame, "fileInputCount");
        if (result.count > 0) counts.push({ frame, count: result.count });
      }
      if (!counts.length) throw new Error("this page has no file upload field (it may use its own picker, e.g. Google Drive)");
      if (counts.length !== 1 || counts[0].count !== 1) throw new Error("ambiguous file upload fields; choose the exact input");
      return await call(tab.id, counts[0].frame, "upload", [-1, msg.name, msg.type, msg.data]);
    }
    case "findOption": {
      // The open list may be in the page or in an embedded form; report its box in top-page coordinates. The
      // dropdown's own frame is asked with its local index (so its own list is searched first).
      const offsets = (await mapFor(tab.id)).offsets || {};
      let owner = null;
      if (msg.index != null && msg.index >= 0) { try { owner = await route(tab.id, msg.index); } catch {} }
      let fallback = null;
      const answers = owner ? [{ frameId: owner.frameId, result: await call(tab.id, owner.frameId, "findOption", [msg.text, owner.local]).catch(() => ({ found: false, options: [] })) }] : [];
      if (!answers.length || !answers[0].result.found) answers.push(...(await callAll(tab.id, "findOption", [msg.text])).sort((a, b) => a.frameId - b.frameId));
      for (const { frameId, result } of answers) {
        if (frameId !== 0 && !offsets[frameId]) continue;   // a frame we can't place on screen
        if (result.found) {
          const o = offsets[frameId] || { x: 0, y: 0, sx: 1, sy: 1 };
          const a = toTop(o, result.x, result.y), b = toTop(o, result.px, result.py);
          return { ...result, pointFrame: frameId, x: a.x, y: a.y, px: b.x, py: b.y };
        }
        if (!fallback || (result.options || []).length > (fallback.options || []).length) fallback = result;
      }
      return fallback || { found: false, options: [] };
    }
    case "review": {
      const offsets = (await mapFor(tab.id)).offsets || {};
      const parts = await callAll(tab.id, "review");
      const top = (parts.find((p) => p.frameId === 0) || { result: { url: tab.url, title: tab.title, items: [], messages: [], missing: [] } }).result;
      for (const { frameId, result } of parts) if (frameId !== 0 && offsets[frameId] && result.items.length) {
        top.items = top.items.concat(result.items);
        top.missing = top.missing.concat(result.missing);
        top.messages = top.messages.concat(result.messages);
      }
      return top;
    }
    case "images": return await call(tab.id, 0, "images");
    case "read": {
      const top = await call(tab.id, 0, "readText");
      const offsets = (await mapFor(tab.id)).offsets || {};
      for (const { frameId, result } of await callAll(tab.id, "readText")) {
        if (frameId !== 0 && offsets[frameId] && result.text) top.text = (top.text + "\n\n[embedded: " + result.url + "]\n" + result.text).slice(0, 12000);
      }
      const unread = ((await mapFor(tab.id)).coverage || []);
      if (unread.length) { top.unreadFrames = unread; top.text = (top.text + "\n\n[frames not read: " + unread.map((c) => `${c.frame} (${c.reason})`).join("; ") + "]").slice(0, 12400); }
      return top;
    }
    case "tables": {
      // The page's tables plus those in embedded forms/frames that belong to it.
      const top = await call(tab.id, 0, "tables");
      const offsets = (await mapFor(tab.id)).offsets || {};
      for (const { frameId, result } of await callAll(tab.id, "tables")) {
        if (frameId !== 0 && offsets[frameId]) top.tables = top.tables.concat(result.tables.map((t) => ({ ...t, frame: result.url })));
      }
      return top;
    }
    case "activeValue": {
      const { frameId, info } = await focusedFrame(tab.id);
      focusFrames.set(tab.id, frameId);
      return info;
    }
    case "fillActive": return await call(tab.id, focusFrames.get(tab.id) || 0, "fillActive", [msg.text]);
    case "scroll": return await call(tab.id, 0, "scroll", [msg.dy]);
    default: throw new Error("unknown command " + msg.cmd);
  }
}

// ---- keep the connection up ----
chrome.alarms.create("clinqy-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => { connect(); send({ type: "ping" }); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
setInterval(() => {
  connect(); send({ type: "ping" });
  if (socket?.readyState === WebSocket.OPEN) queueActivity(async () => { for (const id of await activityTabs()) await renderActivity(id, { kind: "working" }); });
}, 20000);
connect();
