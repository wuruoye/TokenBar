import { invoke } from "@tauri-apps/api/core";
import "./workbench.css";

type Platform = "dsh" | "grok";
interface ListItem {
  platform: Platform; id: string; title?: string; cwd?: string; lastPromptAt?: number;
  promptTokens: number; contextWindow?: number; percent?: number;
}
interface Composition {
  system: number; tools: number; user: number; inject: number; assistant: number; tool: number;
  promptTokens: number; contextWindow?: number; percent?: number;
}
interface Document {
  session: ListItem; current: Composition;
  stats: { turns: number; steps: number; humanInputs: number; toolCalls: number; cacheHit?: number; costUsd?: number };
  tokens: { input: number; output: number; cacheRead: number; cacheWrite: number; reasoning: number };
  timing: { wallMs: number; ttftMs: number; genMs: number; toolsMs: number; otherMs: number; calls: number; toolCalls: number };
  trend: Array<{ time: number; turn: number; step: number; system: number; tools: number; user: number; inject: number; assistant: number; tool: number; total: number; prompt: number; output: number; cacheRead: number }>;
  browser: Array<{ seq: number; time: number; cat: string; tokens: number; text?: string; tool?: string }>;
  events: Array<{ seq: number; time: number; kind: string; tokens: number; name?: string; detail?: string }>;
  files: Array<{ path: string; reads: number; writes: number; searches: number; added: number; removed: number; lastTime: number }>;
  agents: Array<{ id: string; name: string; role: string; promptTokens: number; contextWindow?: number }>;
  source: string;
}

const CATS: Array<{ key: keyof Composition; label: string; color: string }> = [
  { key: "system", label: "系统提示词", color: "#6366f1" },
  { key: "tools", label: "工具定义", color: "#f59e0b" },
  { key: "user", label: "用户消息", color: "#22c55e" },
  { key: "inject", label: "注入内容", color: "#a855f7" },
  { key: "assistant", label: "助手消息", color: "#3b82f6" },
  { key: "tool", label: "工具结果", color: "#14b8a6" }
];
const KIND: Record<string, string> = { inject: "注入", compaction: "压缩", prune: "剪枝", model: "切换", mode: "模式" };

const app = document.querySelector<HTMLDivElement>("#app")!;
let items: ListItem[] = [];
let selected: { platform: Platform; id: string } | undefined;
let doc: Document | undefined;
let loading = false;
let error: string | undefined;
let query = "";
let platformFilter: "all" | Platform = "all";
let catFilter = "all";
let trendMode: "total" | "delta" = "total";

function compact(value: number): string {
  if (!Number.isFinite(value)) return "—";
  if (value >= 1e6) return (value / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (value >= 1e3) return (value / 1e3).toFixed(1).replace(/\.0$/, "") + "K";
  return Math.round(value).toLocaleString();
}
function duration(ms: number): string {
  if (!ms) return "—";
  if (ms < 1000) return Math.round(ms) + " ms";
  if (ms < 60_000) return (ms / 1000).toFixed(ms < 10_000 ? 1 : 0) + "s";
  return Math.floor(ms / 60_000) + "m" + Math.round((ms % 60_000) / 1000) + "s";
}
function el<K extends keyof HTMLElementTagNameMap>(tag: K, className = "", text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function button(label: string, action: () => unknown, className = ""): HTMLButtonElement {
  const node = el("button", className, label);
  node.type = "button";
  node.addEventListener("click", () => Promise.resolve().then(action).catch(fail));
  return node;
}
function fail(error: unknown) {
  const toast = el("div", "toast", String(error));
  document.body.append(toast);
  setTimeout(() => toast.remove(), 4000);
}

async function loadList() {
  loading = true; error = undefined; render();
  try {
    const result = await invoke<{ sessions: ListItem[] }>("workbench_list");
    items = result.sessions ?? [];
    if (!selected && items[0]) await open(items[0].platform, items[0].id);
  } catch (caught) {
    error = String(caught);
  } finally {
    loading = false; render();
  }
}
async function open(platform: Platform, id: string) {
  selected = { platform, id };
  loading = true; error = undefined; render();
  try {
    doc = await invoke<Document>("workbench_show", { platform, sessionId: id });
  } catch (caught) {
    error = String(caught); doc = undefined;
  } finally {
    loading = false; render();
  }
}

function ring(percent: number, size: number): HTMLElement {
  const wrap = el("span", "ring");
  wrap.style.width = size + "px"; wrap.style.height = size + "px";
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 36 36");
  for (const [cls, dash] of [["track", "100 0"], ["fill", percent + " " + (100 - percent)]] as const) {
    const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    circle.setAttribute("cx", "18"); circle.setAttribute("cy", "18"); circle.setAttribute("r", "15.5");
    circle.setAttribute("fill", "none"); circle.setAttribute("pathLength", "100");
    circle.setAttribute("stroke-dasharray", dash); circle.classList.add(cls);
    svg.append(circle);
  }
  wrap.append(svg); return wrap;
}
function stack(parts: Array<{ label: string; value: number; color: string; hatched?: boolean }>, total: number): HTMLElement {
  const wrap = el("div");
  const bar = el("div", "stack");
  const legend = el("div", "legend");
  const denom = Math.max(1, total);
  for (const part of parts) {
    if (!part.value) continue;
    const slice = el("span", part.hatched ? "hatched" : "");
    slice.style.width = part.value / denom * 100 + "%";
    if (!part.hatched) slice.style.background = part.color;
    slice.title = part.label + "  " + compact(part.value);
    bar.append(slice);
    const item = el("span", "");
    const swatch = el("i"); swatch.style.background = part.hatched ? "repeating-linear-gradient(135deg,#3a3a3a 0 3px,transparent 3px 6px)" : part.color;
    item.append(swatch, document.createTextNode(part.label + "  " + compact(part.value)));
    legend.append(item);
  }
  wrap.append(bar, legend); return wrap;
}
function card(title: string, body: HTMLElement): HTMLElement {
  const node = el("section", "card");
  node.append(el("h2", "", title), body);
  return node;
}
function stats(entries: Array<[string, string]>): HTMLElement {
  const grid = el("div", "stats");
  for (const [label, value] of entries) {
    const cell = el("div");
    cell.append(el("span", "", label), el("strong", "", value));
    grid.append(cell);
  }
  return grid;
}

function currentCard(doc: Document): HTMLElement {
  const body = el("div", "current");
  const percent = doc.current.percent ?? 0;
  const copy = el("div", "current-copy");
  copy.append(ring(percent, 88), el("div"));
  copy.lastElementChild!.append(
    el("strong", "", Math.round(percent) + "%"),
    el("span", "", compact(doc.current.promptTokens) + (doc.current.contextWindow ? " / " + compact(doc.current.contextWindow) : "") + " · 上下文已用")
  );
  const used: Array<{ label: string; value: number; color: string; hatched?: boolean }> = CATS.map(cat => ({ label: cat.label, value: Number(doc.current[cat.key]) || 0, color: cat.color }));
  const window = doc.current.contextWindow ?? used.reduce((sum, part) => sum + part.value, 0);
  if (window > doc.current.promptTokens) used.push({ label: "剩余窗口", value: window - doc.current.promptTokens, color: "#333", hatched: true });
  body.append(copy, stack(used, Math.max(window, 1)));
  return card("当前上下文", body);
}

function trendCard(doc: Document): HTMLElement {
  const body = el("div");
  const toggle = el("div", "segmented");
  for (const mode of ["total", "delta"] as const) {
    toggle.append(button(mode === "total" ? "累计" : "增量", () => { trendMode = mode; render(); }, trendMode === mode ? "selected" : ""));
  }
  body.append(toggle);
  if (!doc.trend.length) {
    body.append(el("p", "empty", "发送消息后，每一步的构成会显示在这里"));
    return card("上下文趋势", body);
  }
  const values = doc.trend.map(bar => trendMode === "total" ? bar.total : bar.total);
  const max = Math.max(1, ...doc.trend.map(bar => CATS.reduce((sum, cat) => sum + (Number((bar as unknown as Record<string, number>)[cat.key]) || 0), 0)));
  const chart = el("div", "trend");
  const detail = el("div", "trend-detail", "指向柱子查看该步构成");
  doc.trend.forEach((bar, index) => {
    const column = el("button", "trend-col");
    column.type = "button";
    const inner = el("div", "trend-stack");
    const total = CATS.reduce((sum, cat) => sum + (Number((bar as unknown as Record<string, number>)[cat.key]) || 0), 0) || bar.total;
    for (const cat of CATS) {
      const value = Number((bar as unknown as Record<string, number>)[cat.key]) || 0;
      if (!value) continue;
      const slice = el("span");
      slice.style.background = cat.color;
      slice.style.height = Math.max(2, value / max * 140) + "px";
      inner.append(slice);
    }
    column.append(inner, el("span", "muted", String(bar.turn) + "." + bar.step));
    const inspect = () => {
      detail.replaceChildren(el("strong", "", "第 " + bar.turn + " 轮 · 第 " + bar.step + " 步 · ≈ " + compact(total)));
      for (const cat of CATS) {
        const value = Number((bar as unknown as Record<string, number>)[cat.key]) || 0;
        if (value) detail.append(el("span", "", cat.label + " " + compact(value)));
      }
    };
    column.addEventListener("mouseenter", inspect);
    column.addEventListener("click", inspect);
    chart.append(column);
    void values; void index;
  });
  body.append(chart, detail);
  return card("上下文趋势", body);
}

function browserCard(doc: Document): HTMLElement {
  const body = el("div");
  const chips = el("div", "chips");
  for (const [id, label] of [["all", "全部"], ...CATS.map(cat => [cat.key, cat.label])] as Array<[string, string]>) {
    chips.append(button(label, () => { catFilter = id; render(); }, catFilter === id ? "selected" : ""));
  }
  body.append(chips);
  const rows = doc.browser.filter(row => catFilter === "all" || row.cat === catFilter);
  const list = el("div", "browser");
  for (const row of rows.slice(-80)) {
    const item = el("details", "browser-row");
    const summary = el("summary");
    const cat = CATS.find(entry => entry.key === row.cat);
    summary.append(el("i"), el("strong", "", cat?.label || row.cat), el("span", "muted", compact(row.tokens) + (row.tool ? " · " + row.tool : "")));
    (summary.firstElementChild as HTMLElement).style.background = cat?.color || "#888";
    item.append(summary, el("pre", "", row.text || "（无文本）"));
    list.append(item);
  }
  if (!rows.length) list.append(el("p", "empty", "当前分类没有条目"));
  body.append(list);
  return card("上下文浏览器", body);
}

function eventsCard(doc: Document): HTMLElement {
  const body = el("div", "events");
  if (!doc.events.length) body.append(el("p", "empty", "暂无上下文事件（压缩、注入、模型切换会出现在这里）"));
  for (const event of doc.events.slice(-60)) {
    const row = el("div", "event");
    row.append(
      el("span", "badge", KIND[event.kind] || event.kind),
      el("strong", "", event.name || event.kind),
      el("span", "muted", compact(event.tokens) + (event.detail ? " · " + event.detail : ""))
    );
    body.append(row);
  }
  return card("上下文事件", body);
}

function filesCard(doc: Document): HTMLElement {
  const body = el("div", "files");
  if (!doc.files.length) body.append(el("p", "empty", "该范围内没有文件读取、写入或搜索操作"));
  for (const file of doc.files.slice(0, 40)) {
    const row = el("div", "file");
    const name = file.path.replace(/^.*[\\/]/, "");
    row.append(
      el("strong", "", name),
      el("span", "muted", file.path),
      el("span", "", "读 " + file.reads + " · 写 " + file.writes + " · 搜 " + file.searches + (file.added || file.removed ? " · +" + file.added + "/−" + file.removed : ""))
    );
    body.append(row);
  }
  return card("文件活动", body);
}

function agentsCard(doc: Document): HTMLElement {
  const body = el("div", "agents");
  if (doc.agents.length <= 1) body.append(el("p", "empty", "还没有子 Agent。委派任务后，协作网络会列在这里。"));
  for (const agent of doc.agents) {
    const row = el("div", "agent");
    const pct = agent.contextWindow ? Math.round(agent.promptTokens / agent.contextWindow * 100) : 0;
    row.append(ring(pct, 36), el("div"));
    row.lastElementChild!.append(
      el("strong", "", agent.name),
      el("span", "muted", (agent.role === "current" ? "当前" : "子 Agent") + " · " + compact(agent.promptTokens) + (agent.contextWindow ? " / " + compact(agent.contextWindow) : ""))
    );
    body.append(row);
  }
  return card("Agent 网络", body);
}

function render() {
  const shell = el("div", "shell");
  const side = el("aside", "side");
  const brand = el("div", "brand");
  brand.append(el("strong", "", "上下文工作台"), button("刷新", loadList, "ghost"));
  const search = el("input") as HTMLInputElement;
  search.type = "search"; search.placeholder = "搜索会话"; search.value = query;
  search.addEventListener("input", () => { query = search.value; render(); search.focus(); search.setSelectionRange(query.length, query.length); });
  const filters = el("div", "chips");
  for (const [id, label] of [["all", "全部"], ["dsh", "dsh"], ["grok", "Grok"]] as const) {
    filters.append(button(label, () => { platformFilter = id; render(); }, platformFilter === id ? "selected" : ""));
  }
  const list = el("div", "sessions");
  const visible = items.filter(item => (platformFilter === "all" || item.platform === platformFilter)
    && (!query || (item.title || item.id).toLowerCase().includes(query.toLowerCase()) || (item.cwd || "").toLowerCase().includes(query.toLowerCase())));
  for (const item of visible) {
    const row = button("", () => open(item.platform, item.id), selected?.id === item.id && selected.platform === item.platform ? "session selected" : "session");
    row.append(
      el("strong", "", item.title || item.id),
      el("span", "muted", item.platform + (item.cwd ? " · " + item.cwd.replace(/^.*[\\/]/, "") : "")),
      el("span", "muted", item.percent != null ? Math.round(item.percent) + "% · " + compact(item.promptTokens) : compact(item.promptTokens))
    );
    list.append(row);
  }
  if (!visible.length) list.append(el("p", "empty", loading ? "正在读取会话…" : "没有匹配的会话"));
  side.append(brand, search, filters, list);

  const main = el("main", "main");
  if (error) main.append(el("p", "notice", error));
  if (doc) {
    const head = el("header", "session-head");
    head.append(
      el("h1", "", doc.session.title || doc.session.id),
      el("p", "muted", doc.session.platform + (doc.session.cwd ? " · " + doc.session.cwd : "") + " · " + (doc.source === "dsh-projection" ? "dsh 投影" : "从本地日志重建"))
    );
    const billed = doc.tokens;
    const billedTotal = billed.input + billed.output + billed.cacheRead + billed.cacheWrite + billed.reasoning;
    const grid = el("div", "grid");
    grid.append(
      currentCard(doc),
      card("上下文统计", stats([
        ["轮次", String(doc.stats.turns)],
        ["步数", String(doc.stats.steps)],
        ["用户输入", String(doc.stats.humanInputs)],
        ["工具调用", String(doc.stats.toolCalls)],
        ["缓存命中", doc.stats.cacheHit != null ? doc.stats.cacheHit.toFixed(1) + "%" : "—"],
        ["预估费用", doc.stats.costUsd != null ? "~$" + doc.stats.costUsd.toFixed(2) : "—"]
      ])),
      card("Token 统计", stack([
        { label: "输入", value: billed.input, color: "#22c55e" },
        { label: "缓存读取", value: billed.cacheRead, color: "#14b8a6" },
        { label: "缓存写入", value: billed.cacheWrite, color: "#84cc16" },
        { label: "输出", value: billed.output, color: "#3b82f6" },
        { label: "思考", value: billed.reasoning, color: "#f59e0b" }
      ], billedTotal)),
      card("耗时统计", (() => {
        const body = el("div");
        body.append(stack([
          { label: "模型等待", value: doc.timing.ttftMs, color: "#f59e0b" },
          { label: "模型生成", value: doc.timing.genMs, color: "#6366f1" },
          { label: "工具执行", value: doc.timing.toolsMs, color: "#14b8a6" },
          { label: "其他开销", value: doc.timing.otherMs, color: "#64748b" }
        ], Math.max(1, doc.timing.wallMs || (doc.timing.ttftMs + doc.timing.genMs + doc.timing.toolsMs + doc.timing.otherMs))));
        body.append(stats([
          ["活跃时长", duration(doc.timing.wallMs)],
          ["模型调用", String(doc.timing.calls)],
          ["工具次数", String(doc.timing.toolCalls)]
        ]));
        return body;
      })())
    );
    main.append(head, grid, trendCard(doc), browserCard(doc), eventsCard(doc), filesCard(doc), agentsCard(doc));
  } else if (!loading) {
    main.append(el("p", "empty", "从左侧打开一条会话。dsh 会话使用官方投影，和其他 Agent 共用同一套九块卡片。"));
  }
  app.replaceChildren(shell);
  shell.append(side, main);
}

loadList();
render();
