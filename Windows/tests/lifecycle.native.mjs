// Lifecycle regression test against our own ui-test build and loopback CDP endpoint.
// Does not change settings or restart Explorer. Closes only the process it launches.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const binary = fileURLToPath(new URL("../src-tauri/target/debug/tokenbar-windows.exe", import.meta.url));
const port = Number(process.env.TOKENBAR_TEST_CDP_PORT || "9237");
const env = { ...process.env, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port}` };
const processOptions = { env, windowsHide: true, stdio: ["ignore", "ignore", "pipe"] };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, message, timeout = 30000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const result = await check(); if (result) return result; await delay(150); }
  throw new Error(message);
}
async function connect(excludeId) {
  const page = await until(async () => {
    try {
      const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      return pages.find(p => p.id !== excludeId && p.title === "TokenBar" && /^https?:\/\/tauri\.localhost\//.test(p.url));
    } catch { return undefined; }
  }, "Panel WebView was not recreated");
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let sequence = 0;
  const pending = new Map();
  socket.onmessage = event => {
    const value = JSON.parse(String(event.data));
    const entry = pending.get(value.id);
    if (!entry) return;
    pending.delete(value.id); clearTimeout(entry.timer);
    if (value.error) entry.reject(new Error(value.error.message)); else entry.resolve(value.result);
  };
  socket.onclose = () => {
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(new Error("Panel closed")); }
    pending.clear();
  };
  async function evaluate(expression, awaitPromise = true) {
    const result = await new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error("CDP timeout")); }, 20000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({id,method:"Runtime.evaluate",params:{expression,awaitPromise,returnByValue:true}}));
    });
    if (result.exceptionDetails) throw new Error(result.result?.description || result.exceptionDetails.text);
    return result.result.value;
  }
  const invoke = (name, args = {}) => evaluate(`window.__TAURI_INTERNALS__.invoke(${JSON.stringify(name)},${JSON.stringify(args)})`);
  return { id:page.id, socket, invoke, evaluate };
}

const child = spawn(binary, ["--background"], processOptions);
let stderr = "";
child.stderr.on("data", value => { stderr = (stderr + value).slice(-32768); });
const exited = new Promise(resolve => child.once("exit", (code, signal) => resolve({code, signal})));
let connection;
try {
  connection = await connect();
  await until(async () => {
    const status = await connection.invoke("test_lifecycle_status");
    assert.equal(status.pid, child.pid, "Another TokenBar instance is already running; stop it before this test");
    return status.trayExists && status.taskbar.attached;
  }, "Tray/taskbar did not start");
  await connection.invoke("test_lifecycle_action", {action:"close-panel"});
  await until(async () => !await connection.invoke("plugin:window|is_visible", {label:"main"}), "Close did not hide the panel");
  assert.equal(child.exitCode, null, "Closing a panel exited the resident app");

  for (let cycle = 0; cycle < 3; cycle++) {
    const previousId = connection.id;
    await connection.evaluate('void window.__TAURI_INTERNALS__.invoke("test_lifecycle_action",{action:"destroy-panel"}).catch(()=>{})', false).catch(() => {});
    await delay(500);
    assert.equal(child.exitCode, null, `Destroy cycle ${cycle} exited the resident app: ${stderr}`);
    connection.socket.close();
    connection = await connect(previousId);
    const status = await connection.invoke("test_lifecycle_status");
    assert.equal(status.pid, child.pid);
    assert.equal(status.panelExists, true);
    assert.equal(status.trayExists, true);
    await until(async () => (await connection.invoke("get_taskbar_status")).attached, "Taskbar disappeared after panel destruction");
    await connection.invoke("set_pinned", {pinned:true});
    const activation = spawn(binary, [], processOptions);
    activation.stderr.resume();
    const forwarded = await new Promise(resolve => activation.once("exit", code => resolve(code)));
    assert.equal(forwarded, 0, "Second launch did not forward to the resident instance");
    await until(() => connection.invoke("plugin:window|is_visible", {label:"main"}), "Recreated panel could not reopen");
    assert.equal((await connection.invoke("test_lifecycle_status")).pid, child.pid);
  }
  await connection.evaluate('void window.__TAURI_INTERNALS__.invoke("test_lifecycle_action",{action:"quit"}).catch(()=>{})', false).catch(() => {});
  const result = await Promise.race([exited, delay(10000).then(() => { throw new Error("Explicit Quit did not exit"); })]);
  assert.equal(result.code, 0);
  const log = path.join(process.env.LOCALAPPDATA, "com.wuruoye.tokenbar.windows/logs/runtime.log");
  const events = readFileSync(log, "utf8").trim().split(/\r?\n/).map(JSON.parse).filter(e => e.pid === child.pid);
  assert.equal(events.filter(e => e.event === "exit-requested" && e.fields.code === null && e.fields.prevented).length, 3);
  assert.equal(events.filter(e => e.event === "panel-recreated").length, 3);
  assert(events.some(e => e.event === "quit-selected"));
  assert(events.some(e => e.event === "exit"));
  console.log("PASS: close-to-tray, 3 panel-destruction/recreation cycles, same process and tray/taskbar retained, second-launch activation, explicit Quit, and lifecycle logs.");
} finally {
  connection?.socket.close();
  if (child.exitCode === null && child.signalCode === null) child.kill();
}
