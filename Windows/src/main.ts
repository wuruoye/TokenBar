import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { compact, cost, locator, sessionsFor, sourceFor, throughput, tokenTotal, mergedSnapshot, sessionKey, todayCost,
  remainingPercent, weeklyPacing, cachePercentage, displayedBuckets,
  type Dashboard, type Day, type Platform, type QuotaWindow, type Request, type Session, type Settings, type Tokens, type Totals } from "./model";
import "./style.css";

const app = document.querySelector<HTMLDivElement>("#app")!;
let data: Dashboard | undefined;
let platform: Platform = "codex";
let view: "dashboard" | "settings" | "session" = "dashboard";
let selectedSession: string | undefined;
let chartDays = 30;
let pinned = false;
let settingsDirty = false;
let allDevices = false;
const names: Record<Platform, string> = { codex: "Codex", claude: "Claude", grok: "Grok" };

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className = "", text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function button(label: string, action: () => unknown, className = ""): HTMLButtonElement {
  const node = el("button", className, label);
  node.type = "button";
  node.addEventListener("click", () => Promise.resolve().then(action).catch(notify));
  return node;
}
function notify(error: unknown) {
  document.querySelector(".toast")?.remove();
  const toast = el("div", "toast", String(error));
  toast.setAttribute("role", "status");
  document.body.append(toast);
  setTimeout(() => toast.remove(), 4500);
}
async function copy(text: string) {
  await invoke("copy_text", { text });
  notify("已复制");
}
function dateTime(ms?: number): string {
  return ms ? new Date(ms).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "时间未知";
}
function age(ms?: number): string {
  if (!ms) return "等待数据";
  const minutes = Math.max(0, Math.floor((Date.now() - ms) / 60000));
  return minutes < 1 ? "刚刚更新" : minutes < 60 ? minutes + " 分钟前更新" : dateTime(ms) + " 更新";
}
function tokenRows(tokens: Tokens): HTMLElement {
  const row = el("div", "token-rows");
  for (const [key, label] of [["input", "输入"], ["output", "输出"], ["cacheRead", "缓存读取"], ["cacheWrite", "缓存写入"], ["reasoning", "推理"]] as const) {
    const item = el("div");
    item.append(el("span", "muted", label), el("strong", "", compact(tokens[key])));
    row.append(item);
  }
  return row;
}
function sectionTitle(title: string, aside?: HTMLElement): HTMLElement {
  const node = el("div", "section-title");
  node.append(el("h2", "", title));
  if (aside) node.append(aside);
  return node;
}
function header(): HTMLElement {
  const node = el("header", "titlebar");
  const brand = el("div", "brand");
  brand.append(el("span", "brand-mark", "T"), el("strong", "", "TokenBar"), el("span", "platform-label", "WINDOWS"));
  brand.addEventListener("mousedown", event => { if (event.button === 0) void getCurrentWindow().startDragging(); });
  const actions = el("div", "actions");
  const pin = button(pinned ? "●" : "○", async () => {
    await invoke("set_pinned", { pinned: !pinned });
    pinned = !pinned; document.querySelector("header")?.replaceWith(header());
  }, pinned ? "icon active" : "icon");
  pin.title = pinned ? "取消固定窗口" : "固定窗口";
  pin.setAttribute("aria-label", pin.title);
  const settings = button("⚙", () => { view = "settings"; settingsDirty = false; render(); }, "icon");
  settings.title = "设置"; settings.setAttribute("aria-label", "设置");
  const close = button("×", () => getCurrentWindow().hide(), "icon");
  close.title = "收起到托盘"; close.setAttribute("aria-label", close.title);
  actions.append(pin, settings, close);
  node.append(brand, actions);
  return node;
}

function resetText(timestamp?: number): string {
  if (!timestamp) return "Reset time unavailable";
  const minutes = Math.max(0, Math.ceil((timestamp - Date.now()) / 60000));
  if (!minutes) return "Waiting for reset update";
  const hours = Math.floor(minutes / 60), days = Math.floor(hours / 24);
  return "resets in " + (days ? days + "d " + hours % 24 + "h" : hours ? hours + "h " + minutes % 60 + "m" : minutes + "m");
}
function quotaRow(label: string, window: QuotaWindow, measuredAt = Date.now()): HTMLElement {
  const row = el("div", "quota-row");
  const line = el("div", "quota-label");
  const caption = el("span"); caption.append(el("strong", "", label));
  if (label === "Weekly") caption.append(el("span", "muted", " · " + resetText(window.resetsAtMs)));
  line.append(caption, el("strong", "", remainingPercent(window).toFixed(0) + "% left"));
  const pacing = label === "Weekly" ? weeklyPacing(window, measuredAt) : undefined;
  const track = el("div", pacing ? "track segmented-quota" : "track");
  if (pacing) {
    for (let i = 0; i < 7; i++) {
      const segment = el("span", "quota-segment");
      const fill = el("span", "fill");
      fill.style.width = Math.max(0, Math.min(100, window.usedPercent * 7 - i * 100)) + "%";
      segment.append(fill); track.append(segment);
    }
    const marker = el("span", "pace-marker");
    marker.style.left = pacing.expected + "%"; track.append(marker);
  } else {
    const fill = el("div", "fill" + (remainingPercent(window) < 10 ? " warning-fill" : ""));
    fill.style.width = remainingPercent(window) + "%"; track.append(fill);
  }
  track.setAttribute("role", "progressbar");
  track.setAttribute("aria-label", label + (pacing ? "已用额度" : "剩余额度"));
  track.setAttribute("aria-valuenow", String(pacing ? window.usedPercent : remainingPercent(window)));
  track.setAttribute("aria-valuemin", "0"); track.setAttribute("aria-valuemax", "100");
  row.append(line, track);
  if (pacing) {
    const pace = el("div", "pace-caption muted");
    const delta = Math.round(pacing.delta);
    pace.append(el("span", "", "Day " + pacing.day + "/7 · " + window.usedPercent.toFixed(0) + "% used"),
      el("span", "", pacing.expected.toFixed(0) + "% expected · "),
      el("span", delta > 0 ? "over-pace" : delta < 0 ? "under-pace" : "", delta === 0 ? "on pace" : Math.abs(delta) + "pp " + (delta > 0 ? "over" : "under")));
    row.append(pace);
  } else row.append(el("div", "quota-reset muted", resetText(window.resetsAtMs)));
  return row;
}
function totalLabel(tokens: Tokens): HTMLElement {
  const label = el("div", "total-label");
  label.append(el("strong", "", compact(tokenTotal(tokens))), el("span", "muted", " tokens"));
  return label;
}
function stackedBar(tokens: Tokens): HTMLElement {
  const bar = el("div", "token-stack");
  const total = tokenTotal(tokens);
  for (const bucket of displayedBuckets(tokens)) {
    if (!bucket.value) continue;
    const part = el("span", "bucket-" + bucket.id);
    part.style.width = bucket.value / Math.max(1, total) * 100 + "%";
    part.title = bucket.label + " " + compact(bucket.value); bar.append(part);
  }
  return bar;
}
function totalsSection(title: string, totals: Totals, costText: string, detailed: boolean): HTMLElement {
  const section = el("section", "card totals-section");
  section.append(sectionTitle(title, totalLabel(totals.tokens)), stackedBar(totals.tokens));
  if (detailed) {
    const legend = el("div", "token-legend");
    const prices = totals.tokenCosts ? displayedBuckets(totals.tokenCosts) : [];
    for (const bucket of displayedBuckets(totals.tokens)) {
      const row = el("div", "legend-item");
      const caption = el("span", "muted");
      caption.append(el("i", "bucket-" + bucket.id), document.createTextNode(bucket.label));
      row.append(caption, el("strong", "", compact(bucket.value)));
      const price = prices.find(p => p.id === bucket.id);
      if (price) row.append(el("span", "cost tiny", cost(price.value)));
      legend.append(row);
    }
    section.append(legend);
  }
  const meta = el("div", "totals-meta");
  meta.append(el("span", "muted", "Cache " + cachePercentage(totals.tokens) + " · " + totals.sessionCount + " sessions · " + totals.requestCount + " turns"),
    el("strong", "cost", costText));
  section.append(meta);
  if (detailed && totals.averageGenerationTokensPerSecond) section.append(el("p", "muted small", "Avg " + totals.averageGenerationTokensPerSecond.toFixed(1) + " tok/s"));
  return section;
}
function dashboard(): HTMLElement {
  const main = el("main", "content dashboard");
  const tabs = el("nav", "provider-tabs"); tabs.setAttribute("aria-label", "平台");
  const platforms: Platform[] = ["codex", ...(data?.settings.showClaude ? ["claude" as const] : []), ...(data?.settings.showGrok ? ["grok" as const] : [])];
  for (const item of platforms) {
    const tab = button(names[item], () => { platform = item; render(); return invoke("set_active_platform", { platform: item }); }, item === platform ? "selected" : "");
    tab.setAttribute("aria-pressed", String(platform === item)); tabs.append(tab);
  }
  main.append(tabs);
  if (data?.settings.syncEnabled) {
    const devices = el("div", "device-scope");
    const selector = el("select");
    selector.setAttribute("aria-label", "统计设备");
    for (const [value, label] of [["local", "本机"], ["all", "全部设备（" + (1 + data.remoteSnapshots.length) + "）"]]) {
      const option = el("option", "", label); option.value = value; selector.append(option);
    }
    selector.value = allDevices ? "all" : "local";
    selector.addEventListener("change", () => { allDevices = selector.value === "all"; render(); });
    devices.append(selector, el("span", "muted small", data.syncStatus)); main.append(devices);
  }
  const quota = data?.quotas[platform];
  const quotaCard = el("section", "card");
  quotaCard.append(sectionTitle("Quota", el("span", "muted small", allDevices ? "本机账户" : "")));
  if (quota?.weekly) quotaCard.append(quotaRow("Weekly", quota.weekly, quota.updatedAtMs));
  if (quota?.session) quotaCard.append(quotaRow("5-hour", quota.session, quota.updatedAtMs));
  if (quota?.availableResetCredits != null) {
    const credits = el("div", "reset-credits");
    credits.append(el("strong", "", "↻  Extra resets"), el("strong", "", quota.availableResetCredits + " available"));
    quotaCard.append(credits);
  }
  if (quota?.error) quotaCard.append(el("p", "notice", (quota.session || quota.weekly ? "显示上次结果 · " : "") + quota.error));
  else if (!quota?.session && !quota?.weekly) quotaCard.append(el("p", "muted", "正在读取额度…"));
  main.append(quotaCard);
  if (data?.error) main.append(el("p", "notice error", data.error + (data.snapshot ? " 当前显示上次统计。" : "")));
  const snapshot = visibleSnapshot();
  const source = sourceFor(snapshot, platform);
  if (!data?.snapshot) {
    const loading = el("section", "empty");
    loading.append(el("div", data?.refreshing ? "spinner" : ""), el("h2", "", data?.refreshing ? "正在读取本地活动" : "还没有统计数据"),
      el("p", "muted", "首次扫描可能需要一些时间。完成后会自动显示。"));
    main.append(loading); return main;
  }
  if (source) {
    main.append(totalsSection("Today", source.today, todayCost(source.today, sessionsFor(snapshot, platform), source.days.at(-1)?.date ?? ""), true));
    if (source.weeklySinceReset) {
      main.append(totalsSection("Since weekly reset", source.weeklySinceReset.totals, source.weeklySinceReset.totals.costUsd === 0 && tokenTotal(source.weeklySinceReset.totals.tokens) > 0 ? "—" : cost(source.weeklySinceReset.totals.costUsd), false));
    }
    main.append(activityChart(source.days));
  } else {
    main.append(el("section", "empty", "最近 30 天没有 " + names[platform] + " 的本地活动。"));
  }
  const sessions = sessionsFor(snapshot, platform);
  const recent = el("section", "card sessions");
  recent.append(sectionTitle("Recent Sessions", el("span", "muted small", (allDevices ? "设备最近快照 · " : "本机今日 · ") + sessions.length)));
  for (const session of sessions.slice(0, data.settings.recentLimit)) {
    const row = button("", () => { selectedSession = sessionKey(session); view = "session"; render(); }, "session-row");
    const title = el("div", "session-title", session.title || session.requests[0]?.promptPreview || session.id);
    const sub = el("div", "session-meta muted");
    sub.append(el("span", "", (session.deviceName || session.workspaceLabel || names[platform]) + " · " + dateTime(session.endedAtMs)),
      el("span", "", compact(tokenTotal(session.tokens)) + " ›"));
    row.append(title, sub); recent.append(row);
  }
  if (!sessions.length) recent.append(el("p", "muted", "还没有会话记录。"));
  main.append(recent);
  if (platform === "codex") {
    const memory = data.snapshot.memoryUsage;
    if (memory || data.settings.memoryEnabled) {
      const card = el("section", "card");
      card.append(sectionTitle("Codex Memory", el("span", "muted small", "本机 · 最近 30 天")));
      if (memory) {
        const line = el("div", "weekly");
        line.append(el("span", "", "Phase 1  " + compact(memory.rangeTotals.phase1.total)),
          el("span", "", "Phase 2  " + compact(memory.rangeTotals.phase2.total)));
        card.append(line, el("p", "muted small", memory.observationCount + " 条观测 · " + (memory.lastMemoryReceivedAtMs ? dateTime(memory.lastMemoryReceivedAtMs) : "等待 Memory 指标")));
      }
      card.append(el("p", "muted small", data.memoryStatus)); main.append(card);
    }
  }
  const pricing = data.snapshot.pricingCatalog;
  if (platform !== "grok" && pricing) {
    const source = pricing.source === "openrouter" ? "本机价格表：OpenRouter" : "本机价格表：内置";
    const status = pricing.status === "update-failed" || pricing.status === "retry-wait" ? " · 更新暂不可用" : "";
    const updated = pricing.updatedAtMs ? " · " + dateTime(pricing.updatedAtMs) + " 更新" : "";
    main.append(el("p", "footnote", source + updated + status));
  }
  main.append(el("p", "footnote", platform === "grok" ? "费用来自 Grok 本地记录 · 请求内容仅在本机读取" : "按当前报价估算 · 无匹配报价时使用内置费率 · 请求内容仅在本机读取"));
  return main;
}

function activityChart(days: Day[]): HTMLElement {
  const card = el("section", "card");
  const toggle = el("div", "segmented");
  for (const range of [7, 30]) toggle.append(button(range + " 天", () => { chartDays = range; render(); }, range === chartDays ? "selected" : ""));
  const visible = days.slice(-chartDays);
  const total = visible.reduce((sum, day) => sum + tokenTotal(day.tokens), 0);
  const header = sectionTitle("Activity", el("strong", "range-total", compact(total) + " tokens"));
  header.insertBefore(toggle, header.lastChild); card.append(header);
  const max = Math.max(1, ...visible.map(d => tokenTotal(d.tokens)));
  const chart = el("div", "chart");
  const detail = el("div", "chart-detail muted small", "指向日期，查看模型用量");
  for (const [index, day] of visible.entries()) {
    const count = tokenTotal(day.tokens);
    const bar = button("", () => inspect(day), "chart-column");
    bar.setAttribute("aria-label", day.date + "，" + compact(count) + " tokens");
    const height = el("span", "bar"); height.style.height = Math.max(count ? 3 : 1, count / max * 67) + "px";
    bar.append(height, el("span", "chart-date muted", chartDays === 7 || index === 0 || index === visible.length - 1 ? day.date.slice(5) : ""));
    bar.addEventListener("mouseenter", () => inspect(day));
    bar.addEventListener("focus", () => inspect(day));
    chart.append(bar);
  }
  function inspect(day: Day) {
    detail.replaceChildren(el("strong", "", day.date + " · " + compact(tokenTotal(day.tokens)) + " tokens"));
    for (const model of day.models ?? []) detail.append(el("span", "", model.model + "  " + compact(tokenTotal(model.tokens))));
  }
  const meta = el("div", "totals-meta muted");
  meta.append(el("span", "", chartDays + " days · UTC"), el("span", "", visible.reduce((sum, d) => sum + d.requestCount, 0) + " turns · " + compact(total / Math.max(1, visible.length)) + "/day"));
  card.append(chart, detail, meta); return card;
}

function visibleSnapshot() {
  return data?.snapshot && allDevices && data.settings.syncEnabled
    ? mergedSnapshot(data.snapshot, data.remoteSnapshots) : data?.snapshot;
}
function sessionView(): HTMLElement {
  const main = el("main", "content");
  main.append(button("‹ 返回面板", () => { view = "dashboard"; render(); }, "back"));
  const session = sessionsFor(visibleSnapshot(), platform).find(s => sessionKey(s) === selectedSession);
  if (!session) { main.append(el("p", "notice", "该会话已不在当前统计中。")); return main; }
  main.append(el("h1", "detail-title", session.title || session.id),
    el("p", "muted small", names[platform] + " · " + dateTime(session.startedAtMs)));
  const actions = el("div", "detail-actions");
  actions.append(button("复制会话", () => copy(locator(session))));
  if (platform !== "grok" && !session.deviceId) actions.append(button(platform === "claude" ? "打开 Claude 会话列表" : "在 Codex 中打开", () =>
    invoke("open_session", { platform, sessionId: session.id })));
  main.append(actions, tokenRows(session.tokens));
  if (session.deviceId) main.append(el("p", "notice", "来自 " + session.deviceName + " · 远端会话只读，同步数据不包含提示词、输出和本地路径。"));
  if (platform === "grok") main.append(el("p", "muted small", "可在 Grok Build 中使用 --resume 和会话 ID 恢复。"));
  session.requests.forEach((request, index) => {
    const turn = el("details", "turn");
    const summary = el("summary", "turn-summary");
    const text = el("div");
    text.append(el("strong", "", "Turn " + (index + 1)), el("span", "muted small", " · " + compact(tokenTotal(request.tokens)) + " tokens"));
    const tps = throughput(request);
    if (tps) text.append(el("span", "muted small", " · " + tps.toFixed(1) + " tok/s"));
    if (request.serviceTier === "fast" || request.serviceTier === "mixed") text.append(el("span", "badge", request.serviceTier.toUpperCase()));
    summary.append(text, el("p", "preview", request.promptPreview || request.model));
    turn.append(summary);
    let loaded = false;
    turn.addEventListener("toggle", () => {
      if (turn.open && !loaded) {
        loaded = true;
        for (const physical of request.contributions?.length ? request.contributions : [request]) turn.append(requestRow(session, physical));
      }
    });
    main.append(turn);
  });
  return main;
}
function requestRow(session: Session, request: Request): HTMLElement {
  const row = el("div", "request");
  row.append(el("strong", "small", (request.isSubagent ? request.agent || "Subagent" : "Main") + " · " + request.model),
    el("p", "muted small", compact(tokenTotal(request.tokens)) + " tokens · " + (request.costSource === "unknown" ? "费用未知" : cost(request.costUsd))),
    tokenRows(request.tokens));
  const actions = el("div", "detail-actions");
  actions.append(button("复制定位信息", () => copy(locator(session, request))));
  const details = el("div", "request-text");
  const load = button("查看完整请求", async () => {
    load.disabled = true; load.textContent = "正在读取…";
    try {
      const result = await invoke<{ prompt?: string; output?: string }>("request_detail", { platform: session.platform, sessionId: session.id, requestId: request.id });
      details.replaceChildren();
      for (const [title, text] of [["Prompt", result.prompt], ["Output", result.output]]) {
        const heading = sectionTitle(title!);
        if (text) heading.append(button("复制", () => copy(text), "small"));
        details.append(heading, el("pre", "", text || "本地记录中未提供此内容。"));
      }
      load.remove();
    } catch (error) { load.textContent = "重试"; load.disabled = false; throw error; }
  });
  if (!session.deviceId) actions.append(load);
  row.append(actions, details); return row;
}

function settingsView(): HTMLElement {
  const main = el("main", "content settings");
  main.append(button("‹ 返回面板", () => { view = "dashboard"; settingsDirty = false; render(); }, "back"),
    el("h1", "", "设置"));
  if (!data) return main;
  const settings = { ...data.settings };
  const form = el("form", "card");
  const controls = new Map<keyof Settings, HTMLInputElement | HTMLSelectElement>();
  function field(key: keyof Settings, label: string, kind: string, options?: Array<[string, string]>) {
    const row = el("label", "field");
    const title = el("span", "", label);
    let input: HTMLInputElement | HTMLSelectElement;
    if (kind === "select") {
      input = el("select");
      for (const [value, name] of options ?? []) {
        const option = el("option", "", name); option.value = value; input.append(option);
      }
      input.value = String(settings[key]);
    } else {
      input = el("input"); input.type = kind;
      if (kind === "checkbox") { input.checked = Boolean(settings[key]); row.classList.add("check-field"); }
      else input.value = String(settings[key]);
      if (kind === "text") { input.placeholder = "自动检测"; input.spellcheck = false; }
      if (key === "refreshSeconds") { input.min = "60"; input.max = "3600"; }
      if (key === "recentLimit") { input.min = "5"; input.max = "100"; }
    }
    input.name = key;
    input.addEventListener("input", () => { settingsDirty = true; });
    controls.set(key, input); row.append(title, input); form.append(row);
  }
  form.append(el("h2", "", "显示与刷新"));
  field("theme", "主题", "select", [["system", "跟随系统"], ["dark", "深色"], ["light", "浅色"]]);
  field("refreshSeconds", "后台刷新间隔（秒）", "number");
  field("recentLimit", "最近会话数量", "number");
  field("showClaude", "显示 Claude", "checkbox");
  field("showGrok", "显示 Grok", "checkbox");
  field("autostart", "登录 Windows 后在托盘启动", "checkbox");
  form.append(el("h2", "", "任务栏常驻用量"));
  field("taskbarEnabled", "在任务栏显示用量", "checkbox");
  field("taskbarPlatform", "显示平台", "select", [["codex","Codex"],["claude","Claude"],["grok","Grok"],["all","全部已显示的平台"]]);
  field("taskbarPosition", "优先位置", "select", [["right","靠近通知区域"],["left","任务栏左侧空位"]]);
  form.append(el("p", "muted small", "以透明背景和两行文字显示：上行是各平台的今日 Tokens，下行是周额度剩余。点击平台展开，再次点击收起。"));
  const taskbarStatus = el("p", "muted small", "正在检查任务栏…");
  form.append(taskbarStatus);
  void invoke<{ message: string }>("get_taskbar_status").then(status => {
    if (taskbarStatus.isConnected) taskbarStatus.textContent = status.message;
  }).catch(() => { if (taskbarStatus.isConnected) taskbarStatus.textContent = "任务栏状态暂时不可用"; });
  form.append(el("h2", "", "本地数据目录"));
  field("codexHome", "Codex 数据目录", "text");
  field("claudeHome", "Claude Code 数据目录", "text");
  field("grokHome", "Grok Build 数据目录", "text");
  field("codexBinary", "Codex 可执行文件（.exe）", "text");
  form.append(el("p", "muted small", "留空时读取客户端环境变量和当前用户目录。统计按 UTC 日期汇总。"));
  form.append(el("h2", "", "多设备同步"));
  field("syncEnabled", "同步脱敏后的活动统计", "checkbox");
  field("syncEndpoint", "HTTPS 服务地址", "text");
  field("syncDeviceName", "本机设备名称", "text");
  const tokenLabel = el("label", "field");
  const tokenInput = el("input"); tokenInput.type = "password";
  tokenInput.autocomplete = "new-password"; tokenInput.placeholder = "留空保留已保存的令牌";
  tokenInput.addEventListener("input", () => { settingsDirty = true; });
  tokenLabel.append(el("span", "", "设备访问令牌"), tokenInput); form.append(tokenLabel);
  form.append(el("p", "muted small", "开启后向指定服务上传脱敏统计并下载其他设备数据。会话标题、提示词、输出和本地路径不会上传。访问令牌由 Windows DPAPI 加密保存。"),
    el("p", "muted small", data.syncStatus));
  form.append(el("h2", "", "Codex Memory"));
  field("memoryEnabled", "接收本机 Memory 指标", "checkbox");
  form.append(el("p", "muted small", "接收地址：http://127.0.0.1:4318/v1/metrics。需要在 Codex 中配置 OTLP/HTTP JSON 指标导出；只记录启用后的 Memory 指标。"),
    el("p", "muted small", data.memoryStatus));
  const save = el("button", "primary", "保存设置"); save.type = "submit";
  form.append(save);
  form.addEventListener("submit", async event => {
    event.preventDefault(); save.disabled = true; save.textContent = "保存中…";
    try {
      for (const [key, control] of controls) {
        const value = control instanceof HTMLInputElement && control.type === "checkbox" ? control.checked
          : typeof settings[key] === "number" ? Number(control.value) : control.value.trim();
        Object.assign(settings, { [key]: value });
      }
      await invoke("save_settings", { settings, syncToken: tokenInput.value || null });
      tokenInput.value = "";
      settingsDirty = false; view = "dashboard"; render(); notify("设置已保存");
    } catch (error) { notify(error); save.disabled = false; save.textContent = "保存设置"; }
  });
  main.append(form);
  return main;
}
function footer(): HTMLElement {
  const footer = el("footer", "statusbar");
  const status = el("span", "muted small", data?.refreshing ? "正在刷新…" : age(data?.snapshot?.generatedAtMs));
  status.setAttribute("role", "status");
  const refresh = button("↻  刷新", () => invoke("refresh_dashboard"), "refresh");
  refresh.disabled = data?.refreshing ?? true;
  footer.append(status, refresh); return footer;
}
function render() {
  if (platform === "claude" && !data?.settings.showClaude || platform === "grok" && !data?.settings.showGrok) platform = "codex";
  document.documentElement.dataset.theme = data?.settings.theme ?? "system";
  document.documentElement.dataset.provider = platform;
  const content = document.querySelector("main");
  const scroll = content?.scrollTop ?? 0;
  app.replaceChildren(header(), view === "settings" ? settingsView() : view === "session" ? sessionView() : dashboard(), footer());
  if (view === "dashboard") document.querySelector("main")?.scrollTo(0, scroll);
}
function update(next: Dashboard) {
  data = next;
  if (view === "settings" && settingsDirty || view === "session") {
    document.querySelector("footer")?.replaceWith(footer()); return;
  }
  render();
}
window.addEventListener("keydown", event => {
  if (event.ctrlKey && event.key.toLowerCase() === "r") { event.preventDefault(); void invoke("refresh_dashboard"); }
  if (event.ctrlKey && event.key === ",") { event.preventDefault(); view = "settings"; render(); }
  if (event.key === "Escape") {
    if (view !== "dashboard") { view = "dashboard"; settingsDirty = false; render(); }
    else void getCurrentWindow().hide();
  }
});
render();
async function start() {
  await listen<Dashboard>("dashboard-updated", event => update(event.payload));
  await listen("open-settings", () => { view = "settings"; settingsDirty = false; render(); });
  await listen<Platform>("open-platform", event => {
    platform = event.payload; view = "dashboard"; settingsDirty = false; allDevices = false; render();
  });
  await listen("panel-opened", () => {
    if (!data?.refreshing && (!data?.snapshot || Date.now() - data.snapshot.generatedAtMs > 60000)) void invoke("refresh_dashboard");
  });
  platform = await invoke<Platform>("get_active_platform");
  update(await invoke<Dashboard>("get_dashboard"));
}
void start().catch(error => { app.append(el("p", "notice error", "应用初始化失败：" + String(error))); });
