import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";

interface UnreadTask {
  id: string;
  platform: string;
  title: string;
  workspacePath?: string | null;
  workspaceLabel?: string | null;
  completedAtMs: number;
  turnDurationMs?: number | null;
  lastUserPrompt?: string | null;
  lastReplyPreview?: string | null;
  backgroundActivity?: string | null;
}

interface RunningTask {
  id: string;
  platform: string;
  title: string;
  workspacePath?: string | null;
  workspaceLabel?: string | null;
  startedAtMs: number;
  currentStep?: string | null;
  isBackground: boolean;
}

interface RecentTask {
  id: string;
  platform: string;
  title: string;
  workspacePath?: string | null;
  workspaceLabel?: string | null;
  readAtMs: number;
}

interface Snapshot {
  running: RunningTask[];
  background: RunningTask[];
  unread: UnreadTask[];
  recent: RecentTask[];
}

const root = document.querySelector<HTMLDivElement>("#companion-root")!;
const appWindow = getCurrentWindow();

root.innerHTML = `
  <div class="stage">
    <div class="panel" hidden>
      <div class="panel-head">
        <div class="panel-title"></div>
        <div class="panel-actions">
          <button class="link-btn" data-action="read-all" hidden>全部已读</button>
          <button class="icon-btn" data-action="hide" title="隐藏悬浮窗（托盘菜单可重新打开）">×</button>
        </div>
      </div>
      <div class="panel-body"></div>
    </div>
    <div class="dock">
      <button class="bubble" data-action="bubble" hidden></button>
      <div class="orb idle" data-action="orb">
        <div class="orb-face"><span class="orb-count">0</span></div>
      </div>
    </div>
  </div>`;

const stageEl = root.querySelector<HTMLElement>(".stage")!;
const panelEl = root.querySelector<HTMLElement>(".panel")!;
const panelTitleEl = root.querySelector<HTMLElement>(".panel-title")!;
const readAllBtn = root.querySelector<HTMLButtonElement>('[data-action="read-all"]')!;
const panelBodyEl = root.querySelector<HTMLElement>(".panel-body")!;
const bubbleBtn = root.querySelector<HTMLButtonElement>('[data-action="bubble"]')!;
const orbEl = root.querySelector<HTMLElement>(".orb")!;
const orbCountEl = root.querySelector<HTMLElement>(".orb-count")!;

let snapshot: Snapshot = { running: [], background: [], unread: [], recent: [] };
let expanded = false;
let previousUnread = 0;
let lastBodyKey = "";

function esc(value: string): string {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c);
}

function badgeLetter(platform: string): string {
  return platform === "antigravity" ? "A" : platform === "codex" ? "C" : platform === "claude" ? "Cl" : "?";
}

function ago(ms: number): string {
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (seconds < 60) return "刚刚";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  return `${Math.floor(hours / 24)} 天前`;
}

function elapsed(ms: number): string {
  const total = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  if (m < 60) return `${m}:${String(s).padStart(2, "0")}`;
  return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m`;
}

function duration(ms?: number | null): string | null {
  if (!ms || ms < 1000) return null;
  const minutes = Math.round(ms / 60000);
  if (minutes < 1) return `${Math.round(ms / 1000)} 秒`;
  if (minutes < 60) return `${minutes} 分钟`;
  return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
}

function taskAttrs(kind: string, t: { platform: string; id: string; title: string; workspacePath?: string | null }): string {
  return `data-key="${esc(`${kind}:${t.platform}:${t.id}`)}" data-kind="${esc(kind)}" data-platform="${esc(t.platform)}" data-id="${esc(t.id)}" data-title="${esc(t.title)}" data-workspace="${esc(t.workspacePath ?? "")}"`;
}

function unreadBodyText(t: UnreadTask): string | null {
  const prompt = t.lastUserPrompt && t.lastUserPrompt !== t.title ? t.lastUserPrompt : null;
  return t.backgroundActivity ? `后台 · ${t.backgroundActivity}` : (t.lastReplyPreview ?? prompt ?? null);
}

function unreadMetaText(t: UnreadTask): string {
  return [t.workspaceLabel, duration(t.turnDurationMs) && `用时 ${duration(t.turnDurationMs)}`, ago(t.completedAtMs)]
    .filter(Boolean)
    .join(" · ");
}

function runningStepText(t: RunningTask): string {
  return t.isBackground ? `后台 · ${t.currentStep ?? "运行中"}` : (t.currentStep ?? t.workspaceLabel ?? "执行中");
}

function recentMetaText(t: RecentTask): string {
  return [t.workspaceLabel, `${ago(t.readAtMs)}看过`].filter(Boolean).join(" · ");
}

function unreadItem(t: UnreadTask): string {
  const body = unreadBodyText(t);
  const meta = unreadMetaText(t);
  return `
    <div class="item" ${taskAttrs("unread", t)} title="打开并标记已读">
      <div class="badge ${esc(t.platform)}">${badgeLetter(t.platform)}<span class="dot"></span></div>
      <div class="item-text">
        <div class="item-title" data-role="title">${esc(t.title)}</div>
        ${body ? `<div class="item-body" data-role="body">${esc(body)}</div>` : ""}
        <div class="item-sub" data-role="meta">${esc(meta)}</div>
      </div>
      <div class="item-go">›</div>
    </div>`;
}

function runningItem(t: RunningTask): string {
  const step = runningStepText(t);
  return `
    <div class="item" ${taskAttrs("running", t)} title="打开会话">
      <div class="badge ${esc(t.platform)} live">${badgeLetter(t.platform)}</div>
      <div class="item-text">
        <div class="item-title" data-role="title">${esc(t.title)}</div>
        <div class="item-sub"><span class="live-time" data-since="${t.startedAtMs}">${elapsed(t.startedAtMs)}</span> · <span data-role="step">${esc(step)}</span></div>
      </div>
      <div class="item-go">›</div>
    </div>`;
}

function recentItem(t: RecentTask): string {
  const meta = recentMetaText(t);
  return `
    <div class="item recent" ${taskAttrs("recent", t)} title="打开会话">
      <div class="badge ${esc(t.platform)}">${badgeLetter(t.platform)}</div>
      <div class="item-text">
        <div class="item-title" data-role="title">${esc(t.title)}</div>
        <div class="item-sub" data-role="meta">${esc(meta)}</div>
      </div>
      <div class="item-go">›</div>
    </div>`;
}

function updateItemInPlace(el: HTMLElement, title: string, workspacePath?: string | null) {
  el.dataset.title = title;
  el.dataset.workspace = workspacePath ?? "";
  const titleEl = el.querySelector<HTMLElement>('[data-role="title"]');
  if (titleEl && titleEl.textContent !== title) titleEl.textContent = title;
}

function render() {
  const live = [...snapshot.running, ...snapshot.background];
  const runningCount = live.length;
  const unreadCount = snapshot.unread.length;
  const recent = snapshot.recent ?? [];
  const hasAny = unreadCount > 0 || runningCount > 0;
  const hasList = hasAny || recent.length > 0;
  if (!hasList) expanded = false;

  const total = runningCount + unreadCount;
  const orbState = runningCount > 0 ? "orb running" : total > 0 ? "orb" : "orb idle";
  if (orbEl.className !== orbState) orbEl.className = orbState;
  orbEl.title = `${runningCount} 个在做，${unreadCount} 个做完未看 · 拖动可移动`;
  const totalText = String(total);
  if (orbCountEl.textContent !== totalText) orbCountEl.textContent = totalText;

  const showBubble = unreadCount > 0 && !expanded;
  bubbleBtn.hidden = !showBubble;
  if (showBubble) {
    bubbleBtn.title = unreadCount === 1 ? "打开做完的任务" : "查看做完的任务";
    bubbleBtn.innerHTML = `<span class="bubble-dot"></span>${unreadCount} 做完`;
    if (unreadCount > previousUnread) {
      bubbleBtn.classList.remove("pop");
      void bubbleBtn.offsetWidth;
      bubbleBtn.classList.add("pop");
    }
  }

  panelEl.hidden = !expanded;
  if (expanded) {
    panelTitleEl.innerHTML = `<b>${runningCount}</b> 在做 · <b>${unreadCount}</b> 做完`;
    readAllBtn.hidden = unreadCount === 0;

    const bodyKey = [
      ...snapshot.unread.map((t) => `u:${t.platform}:${t.id}:${unreadBodyText(t) ? 1 : 0}`),
      ...live.map((t) => `r:${t.platform}:${t.id}`),
      ...recent.map((t) => `c:${t.platform}:${t.id}`),
    ].join("|");

    if (bodyKey !== lastBodyKey) {
      lastBodyKey = bodyKey;
      panelBodyEl.innerHTML = `
        ${unreadCount > 0 ? `<div class="section-label">做完</div>${snapshot.unread.map(unreadItem).join("")}` : ""}
        ${runningCount > 0 ? `<div class="section-label">在做</div>${live.map(runningItem).join("")}` : ""}
        ${!hasAny ? `<div class="empty">没有在做或做完未看的任务</div>` : ""}
        ${recent.length > 0 ? `<div class="section-label">最近看过</div>${recent.map(recentItem).join("")}` : ""}`;
    } else {
      for (const t of snapshot.unread) {
        const el = panelBodyEl.querySelector<HTMLElement>(`[data-key="${CSS.escape(`unread:${t.platform}:${t.id}`)}"]`);
        if (!el) continue;
        updateItemInPlace(el, t.title, t.workspacePath);
        const bodyEl = el.querySelector<HTMLElement>('[data-role="body"]');
        const body = unreadBodyText(t) ?? "";
        if (bodyEl && bodyEl.textContent !== body) bodyEl.textContent = body;
        const metaEl = el.querySelector<HTMLElement>('[data-role="meta"]');
        const meta = unreadMetaText(t);
        if (metaEl && metaEl.textContent !== meta) metaEl.textContent = meta;
      }
      for (const t of live) {
        const el = panelBodyEl.querySelector<HTMLElement>(`[data-key="${CSS.escape(`running:${t.platform}:${t.id}`)}"]`);
        if (!el) continue;
        updateItemInPlace(el, t.title, t.workspacePath);
        const sinceEl = el.querySelector<HTMLElement>("[data-since]");
        if (sinceEl) {
          sinceEl.dataset.since = String(t.startedAtMs);
          sinceEl.textContent = elapsed(t.startedAtMs);
        }
        const stepEl = el.querySelector<HTMLElement>('[data-role="step"]');
        const step = runningStepText(t);
        if (stepEl && stepEl.textContent !== step) stepEl.textContent = step;
      }
      for (const t of recent) {
        const el = panelBodyEl.querySelector<HTMLElement>(`[data-key="${CSS.escape(`recent:${t.platform}:${t.id}`)}"]`);
        if (!el) continue;
        updateItemInPlace(el, t.title, t.workspacePath);
        const metaEl = el.querySelector<HTMLElement>('[data-role="meta"]');
        const meta = recentMetaText(t);
        if (metaEl && metaEl.textContent !== meta) metaEl.textContent = meta;
      }
    }
  } else {
    lastBodyKey = "";
  }

  previousUnread = unreadCount;
  requestAnimationFrame(fitWindow);
}

let lastSize = "";
function fitWindow() {
  const rect = stageEl.getBoundingClientRect();
  const width = Math.ceil(rect.width);
  const height = Math.ceil(rect.height);
  const key = `${width}x${height}`;
  if (key === lastSize) return;
  lastSize = key;
  void invoke("companion_resize", { width, height }).catch(() => undefined);
}

async function openTask(el: HTMLElement) {
  const { platform = "", id = "", title = "", workspace = "", kind } = el.dataset;
  if (!platform || !id) return;
  if (kind === "unread") {
    el.classList.add("leaving");
    snapshot = { ...snapshot, unread: snapshot.unread.filter((t) => !(t.platform === platform && t.id === id)) };
  }
  try {
    await invoke("open_desktop_task", { platform, taskId: id, workspacePath: workspace || null, title: title || null });
  } catch (error) {
    console.error(error);
  }
  if (snapshot.unread.length === 0) expanded = false;
  setTimeout(render, kind === "unread" ? 180 : 0);
}

// Click versus drag on the orb: dragging starts only after the pointer moves.
let press: { x: number; y: number; dragging: boolean } | null = null;

root.addEventListener("pointerdown", (e) => {
  if (e.button !== 0) return;
  const orb = (e.target as HTMLElement).closest(".orb");
  if (orb) press = { x: e.screenX, y: e.screenY, dragging: false };
});

root.addEventListener("pointermove", (e) => {
  if (!press || press.dragging || (e.buttons & 1) === 0) return;
  if (Math.hypot(e.screenX - press.x, e.screenY - press.y) > 4) {
    press.dragging = true;
    void appWindow.startDragging();
  }
});

root.addEventListener("pointerup", () => {
  const wasClick = press && !press.dragging;
  press = null;
  if (!wasClick) return;
  const total = snapshot.unread.length + snapshot.running.length + snapshot.background.length + (snapshot.recent?.length ?? 0);
  expanded = total > 0 ? !expanded : false;
  render();
});

root.addEventListener("click", async (e) => {
  const target = e.target as HTMLElement;
  const action = target.closest<HTMLElement>("[data-action]")?.dataset.action;
  if (action === "bubble") {
    if (snapshot.unread.length === 1) {
      const only = snapshot.unread[0];
      const holder = document.createElement("div");
      holder.dataset.platform = only.platform;
      holder.dataset.id = only.id;
      holder.dataset.title = only.title;
      holder.dataset.workspace = only.workspacePath ?? "";
      holder.dataset.kind = "unread";
      await openTask(holder);
    } else {
      expanded = true;
      render();
    }
    return;
  }
  if (action === "read-all") {
    snapshot = await invoke<Snapshot>("mark_all_tasks_read");
    expanded = false;
    render();
    return;
  }
  if (action === "hide") {
    expanded = false;
    await invoke("set_companion_visible", { visible: false });
    return;
  }
  const item = target.closest<HTMLElement>(".item");
  if (item) await openTask(item);
});

setInterval(() => {
  root.querySelectorAll<HTMLElement>("[data-since]").forEach((el) => {
    el.textContent = elapsed(Number(el.dataset.since));
  });
}, 1000);

async function init() {
  await appWindow.onFocusChanged(({ payload: focused }) => {
    if (!focused && expanded) {
      expanded = false;
      render();
    }
  });
  await listen<Snapshot>("desktop-tasks-updated", (event) => {
    snapshot = event.payload;
    render();
  });
  try {
    snapshot = await invoke<Snapshot>("get_desktop_tasks");
  } catch (error) {
    console.error(error);
  }
  render();
}

void init();
