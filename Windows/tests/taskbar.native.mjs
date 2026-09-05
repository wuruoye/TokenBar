// Opt-in integration test for our own native buttons and WebView.
// Requires a ui-test build launched with a loopback WebView2 debugging port.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const manifest = fileURLToPath(new URL("../src-tauri/Cargo.toml",import.meta.url));
const nativeWindows = () => JSON.parse(execFileSync("cargo",["run","--manifest-path",manifest,"--example","taskbar_layout","--quiet"],
  {encoding:"utf8",windowsHide:true,maxBuffer:1024*1024}));
const intersects = (a,b) => a[0]<b[2] && a[2]>b[0] && a[1]<b[3] && a[3]>b[1];

const port = Number(process.env.TOKENBAR_TEST_CDP_PORT || "9237");
let pages = [];
for (let attempt = 0; attempt < 60; attempt++) {
  try {
    pages = await (await fetch("http://127.0.0.1:" + port + "/json/list")).json();
    if (pages.some(p => p.title === "TokenBar")) break;
  } catch {}
  await new Promise(resolve => setTimeout(resolve, 250));
}
const page = pages.find(p => p.title === "TokenBar" && /^https?:\/\/tauri\.localhost\/$/.test(p.url));
assert(page, "The TokenBar test window must be running");
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let sequence = 0;
const pending = new Map();
socket.onmessage = event => {
  const message = JSON.parse(String(event.data));
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  clearTimeout(entry.timer);
  if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
  else entry.resolve(message.result);
};
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("CDP request timed out")); }, 180000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const result = await rpc("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text + ": " + result.result?.description);
  return result.result.value;
}
const invoke = (command, args = {}) => evaluate("window.__TAURI_INTERNALS__.invoke(" + JSON.stringify(command) + "," + JSON.stringify(args) + ")");
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, description) {
  for (let i = 0; i < 40; i++) { if (await check()) return; await delay(250); }
  throw new Error(description);
}
let original;
try {
  original = (await invoke("get_dashboard")).settings;
  await invoke("set_pinned", {pinned:true});
  await invoke("save_settings", {settings:{...original,taskbarEnabled:false},syncToken:null});
  await until(async () => {const s=await invoke("get_taskbar_status");return !s.attached && s.segmentCount===0;},"Baseline native bar did not close");
  const baseline = nativeWindows();
  const shellPid = baseline.find(w => w.class === "Shell_TrayWnd").pid;
  const foreign = baseline.filter(w => w.pid !== shellPid && w.visible);
  await invoke("save_settings", { settings: { ...original, taskbarEnabled: true, taskbarPlatform: "codex" }, syncToken: null });
  await until(async () => (await invoke("get_taskbar_status")).attached, "Native taskbar bar was not attached");
  const status = await invoke("get_taskbar_status");
  assert.equal(status.segmentCount, 1);
  assert.equal(status.painted, true, "The composited text frame must have been presented");
  assert(status.rect.left >= status.taskbarRect.left && status.rect.right <= status.taskbarRect.right);
  assert(status.rect.top >= status.taskbarRect.top && status.rect.bottom <= status.taskbarRect.bottom);
  // First make the panel visible; BM_CLICK goes through the actual Win32 BUTTON and WM_COMMAND.
  let visible = await invoke("plugin:window|is_visible", { label: "main" });
  if (!visible) {
    await invoke("test_taskbar_click", { index: 0 });
    await until(() => invoke("plugin:window|is_visible", {label:"main"}), "Click did not open the panel");
  }
  await invoke("set_active_platform", { platform: "codex" });
  await invoke("test_taskbar_click", { index: 0 });
  await until(async () => !await invoke("plugin:window|is_visible", {label:"main"}), "Second click did not close the panel");
  await invoke("test_taskbar_click", { index: 0 });
  await until(() => invoke("plugin:window|is_visible", {label:"main"}), "Native click did not reopen the panel");
  const position = await invoke("plugin:window|outer_position", {label:"main"});
  const size = await invoke("plugin:window|outer_size", {label:"main"});
  assert(position.y + size.height <= status.taskbarRect.top, "Panel must sit above the bottom taskbar");
  await invoke("save_settings", {settings:{...original,taskbarEnabled:true,taskbarPlatform:"all",showClaude:true,showGrok:true},syncToken:null});
  await until(async () => (await invoke("get_taskbar_status")).segmentCount === 3, "All three taskbar buttons were not created");
  await until(async () => (await invoke("get_taskbar_status")).painted, "Three native buttons were not painted");
  const placed = nativeWindows();
  const nativeBar = placed.find(w => w.class === "TokenBarTaskbarWindow");
  assert(nativeBar?.visible, "Actual native host must be visible");
  assert(parseInt(nativeBar.exStyle,16) & 0x80000, "Native host needs a composited layer");
  assert(placed.some(w => w.pid === nativeBar.pid && w.hwnd === nativeBar.hitAtCenter),
    "Taskbar center is occluded by another application's window");
  for (const other of foreign) {
    const current = placed.find(w => w.hwnd === other.hwnd);
    assert(current, "Existing taskbar window was removed");
    assert.deepEqual(current.rect,other.rect,"Existing taskbar application moved or resized");
    assert(!intersects(nativeBar.rect,current.rect),"TokenBar overlaps an existing custom taskbar window");
  }
  await invoke("test_taskbar_click", {index:1});
  await until(async () => await invoke("get_active_platform") === "claude", "Claude button did not select Claude");
  await until(() => evaluate("document.querySelector('.provider-tabs .selected')?.textContent === 'Claude'"), "Frontend did not follow native platform selection");
  await invoke("save_settings", {settings:{...original,taskbarEnabled:false},syncToken:null});
  await until(async () => {const s=await invoke("get_taskbar_status");return !s.attached && s.segmentCount===0;}, "Disabled native bar was not removed");
  console.log("PASS: native paint and hit testing, no overlap or resizing of existing taskbar apps, open/close, platform selection and settings restore.");
} finally {
  if (original) await invoke("save_settings", {settings:original,syncToken:null});
  await invoke("set_pinned", {pinned:false});
  socket.close();
}
