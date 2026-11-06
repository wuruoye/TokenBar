import { generationSample } from "./performance";

export type Platform = "codex" | "claude" | "grok" | "antigravity";
export interface Tokens { input: number; output: number; cacheRead: number; cacheWrite: number; reasoning: number }
export interface GenerationMetrics { generatedTokens: number; durationMs: number }
export interface Totals {
  tokens: Tokens; costUsd: number; sessionCount: number; requestCount: number;
  averageGenerationTokensPerSecond?: number | null;
  generationMetrics?: GenerationMetrics | null;
  averageTimeToFirstTokenMs?: number | null; firstTokenSampleCount?: number;
  tokenCosts?: Tokens;
}
export interface Day extends Totals {
  date: string;
  models: Array<{ platform: string; model: string; provider?:string; tokens: Tokens; costUsd: number; sessionCount?:number;requestCount?:number }>;
}
export interface ContextOccupancy {
  promptTokens: number;
  contextWindow?: number;
  percent?: number;
  systemTokens?: number;
  messageTokens?: number;
}
export interface Request {
  id: string; platform: string; sessionId: string; physicalSessionId: string;
  isSubagent: boolean; agent?: string; model: string; startedAtMs: number; endedAtMs: number;
  reasoningEffort?: string | null;
  generationMetrics?: GenerationMetrics | null;
  durationMs?: number; modelDurationMs?: number; timeToFirstTokenMs?: number;
  tokens: Tokens; costUsd: number; costSource: string; serviceTier: string;
  sessionPath?: string; promptPreview?: string; outputPreview?: string; context?: ContextOccupancy;
  contributions?: Request[];
}
export interface Session {
  deviceId?: string; deviceName?: string;
  id: string; platform: string; title?: string; workspaceLabel?: string;
  startedAtMs: number; endedAtMs: number; tokens: Tokens; costUsd: number; models: string[]; requests: Request[];
  context?: ContextOccupancy;
}
export interface Source { platform: string; today: Totals; rangeTotals?: Totals; days: Day[]; weeklySinceReset?: { startedAtMs: number; totals: Totals } }
export interface MemoryPhase { total: number; input: number; cachedInput: number; cacheWriteInput: number; output: number; reasoningOutput: number }
export interface Snapshot {
  schemaVersion: number; generatedAtMs: number; timezone: string;
  today: Totals; days: Day[]; sessions: Session[]; sources: Source[];
  rangeTotals?: Totals; weeklySinceReset?: Source["weeklySinceReset"];
  memoryUsage?: { observationCount: number; rangeTotals: { phase1: MemoryPhase; phase2: MemoryPhase }; lastMemoryReceivedAtMs?: number };
  pricingCatalog?: {source:string;updatedAtMs?:number;modelCount:number;status:string};
}
export interface QuotaWindow { usedPercent: number; windowMinutes?: number; resetsAtMs?: number }
export interface QuotaGroup { label: string; session?: QuotaWindow; weekly?: QuotaWindow }
export interface Quota { session?: QuotaWindow; weekly?: QuotaWindow; updatedAtMs: number; error?: string; availableResetCredits?: number; secondaryGroup?: QuotaGroup }
export interface Settings {
  refreshSeconds: number; recentLimit: number; theme: string; showClaude: boolean; showGrok: boolean; showAntigravity: boolean;
  autostart: boolean; codexHome: string; claudeHome: string; grokHome: string; antigravityHome: string; codexBinary: string; memoryEnabled: boolean;
  syncEnabled: boolean; syncEndpoint: string; syncDeviceName: string;
  syncAllDevices: boolean;
  taskbarEnabled: boolean; taskbarPlatform: string; taskbarPosition: string;
  usesWeekdayWeeklyPacing: boolean;
  showCompanion?: boolean;
}
export interface Dashboard {
  settings: Settings; snapshot?: Snapshot; quotas: Partial<Record<Platform, Quota>>;
  refreshing: boolean; error?: string; memoryStatus: string;
  remoteSnapshots: Remote[]; syncStatus: string;
}
export interface Remote { deviceId: string; deviceName: string; snapshot: Snapshot }
export const zeroTokens = (): Tokens => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0 });
export function tokenTotal(tokens: Tokens): number {
  return tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite + tokens.reasoning;
}
export function compact(value: number): string {
  if (!Number.isFinite(value)) return "—";
  if (value >= 1e9) return (value / 1e9).toFixed(1).replace(/\.0$/, "") + "B";
  if (value >= 1e6) return (value / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (value >= 1e3) return (value / 1e3).toFixed(1).replace(/\.0$/, "") + "K";
  return Math.round(value).toLocaleString();
}
export function occupancyPercent(context?: ContextOccupancy): number | undefined {
  if (context?.percent == null || !Number.isFinite(context.percent)) return undefined;
  return Math.max(0, Math.min(100, context.percent));
}
export function occupancyLabel(context?: ContextOccupancy): string | undefined {
  if (!context || !(context.promptTokens > 0)) return undefined;
  const used = compact(context.promptTokens);
  const window = context.contextWindow && context.contextWindow > 0 ? compact(context.contextWindow) : undefined;
  const percent = occupancyPercent(context);
  if (window && percent != null) return used + " / " + window + " · " + Math.round(percent) + "%";
  if (window) return used + " / " + window;
  return used;
}
export function occupancyParts(context?: ContextOccupancy): Array<{ id: string; label: string; value: number }> {
  if (!context || context.systemTokens == null || context.messageTokens == null) return [];
  return [
    { id: "system", label: "系统提示词", value: context.systemTokens },
    { id: "messages", label: "对话", value: context.messageTokens }
  ].filter(part => part.value > 0);
}
export function occupancyWindowParts(context?: ContextOccupancy): Array<{ id: string; label: string; value: number }> {
  if (!context || !(context.promptTokens > 0)) return [];
  const used = occupancyParts(context);
  const parts = used.length ? used : [{ id: "used", label: "已用", value: context.promptTokens }];
  const window = context.contextWindow;
  if (window && window > context.promptTokens) parts.push({ id: "free", label: "剩余窗口", value: window - context.promptTokens });
  return parts;
}
export function durationLabel(ms?: number): string {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return "—";
  if (ms < 1000) return Math.round(ms) + " ms";
  if (ms < 60_000) return (ms / 1000).toFixed(ms < 10_000 ? 1 : 0) + "s";
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.round((ms % 60_000) / 1000);
  return seconds ? minutes + "m" + seconds + "s" : minutes + "m";
}
export function chronologicalTurns(session: Session): Request[] {
  return [...session.requests].sort((a, b) => a.endedAtMs - b.endedAtMs || a.startedAtMs - b.startedAtMs);
}
export function contextStats(session: Session) {
  return {
    turns: session.requests.length,
    cacheHit: cachePercentage(session.tokens),
    costUsd: session.costUsd,
    durationMs: Math.max(0, session.endedAtMs - session.startedAtMs)
  };
}
export function timingStats(session: Session) {
  let wait = 0, gen = 0, other = 0;
  for (const request of session.requests) {
    const total = request.durationMs ?? Math.max(0, request.endedAtMs - request.startedAtMs);
    const model = request.modelDurationMs ?? 0;
    const ttft = request.timeToFirstTokenMs ?? 0;
    wait += ttft;
    gen += Math.max(0, model - ttft);
    other += Math.max(0, total - model);
  }
  return { wait, gen, other, total: wait + gen + other };
}
export function occupancyTrend(session: Session) {
  return chronologicalTurns(session).map((request, index) => ({
    turn: index + 1,
    context: request.context,
    prompt: request.promptPreview || request.model,
    tokens: tokenTotal(request.tokens),
    cost: request.costUsd
  }));
}
export function agentNetwork(session: Session) {
  const groups = new Map<string, { name: string; role: "main" | "subagent"; tokens: number; requests: number }>();
  for (const turn of session.requests) {
    const rows = turn.contributions?.length ? turn.contributions : [turn];
    for (const row of rows) {
      const role = row.isSubagent ? "subagent" as const : "main" as const;
      const name = role === "subagent" ? (row.agent?.trim() || "Subagent") : "Main";
      const key = role + ":" + name;
      const entry = groups.get(key) ?? { name, role, tokens: 0, requests: 0 };
      entry.tokens += tokenTotal(row.tokens);
      entry.requests += 1;
      groups.set(key, entry);
    }
  }
  return [...groups.values()].sort((a, b) => Number(a.role === "subagent") - Number(b.role === "subagent") || b.tokens - a.tokens);
}
export function remainingPercent(window: QuotaWindow): number { return Math.max(0, Math.min(100, 100 - window.usedPercent)); }
export function weeklyPacing(window: QuotaWindow, measuredAt: number, weekdaysOnly = false) {
  const duration = (window.windowMinutes ?? 0) * 60000;
  const end = window.resetsAtMs;
  if (!Number.isFinite(window.usedPercent) || !Number.isFinite(duration) || duration <= 0 ||
      end == null || !Number.isFinite(end) || !Number.isFinite(measuredAt) ||
      measuredAt >= end || measuredAt < end - duration) return undefined;
  const start = end - duration;
  const elapsed = measuredAt - start;
  const actual = Math.max(0, Math.min(100, window.usedPercent));
  if (elapsed === 0 && actual > 0) return undefined;
  let expected = elapsed / duration * 100;
  const segments = weekdaysOnly ? 5 : 7;
  let day = Math.min(7, Math.floor(elapsed / (duration / 7)) + 1);
  if (weekdaysOnly) {
    let total = 0, consumed = 0, withinWorkday = false;
    const cursor = new Date(start);
    cursor.setHours(0, 0, 0, 0);
    while (cursor.getTime() < end) {
      const dayStart = cursor.getTime(), weekday = cursor.getDay();
      // Calendar days preserve local midnight boundaries across DST changes.
      cursor.setDate(cursor.getDate() + 1);
      if (weekday === 0 || weekday === 6) continue;
      const from = Math.max(start, dayStart), to = Math.min(end, cursor.getTime());
      if (from >= to) continue;
      total += to - from;
      consumed += Math.max(0, Math.min(to - from, measuredAt - from));
      withinWorkday ||= measuredAt >= from && measuredAt < to;
    }
    if (total <= 0) return undefined;
    expected = Math.max(0, Math.min(100, consumed / total * 100));
    day = Math.max(0, Math.min(5, withinWorkday ? Math.floor(expected / 20) + 1 : Math.ceil(expected / 20)));
  }
  return { day, segments, weekdaysOnly, actual, expected, delta: actual - expected };
}
export function quotaPaceComparison(delta: number) {
  return Math.abs(delta) < 1 ? { text: "on pace", className: "" }
    : { text: Math.round(Math.abs(delta)) + "pp " + (delta > 0 ? "over" : "under"),
      className: delta > 0 ? "over-pace" : "under-pace" };
}
export function cachePercentage(tokens: Tokens): string {
  const prompt = tokens.input + tokens.cacheWrite + tokens.cacheRead;
  return prompt > 0 ? (tokens.cacheRead / prompt * 100).toFixed(1) + "%" : "—";
}
export function displayedBuckets(tokens: Tokens) {
  return [
    {id:"input", label:"Input", value:tokens.input + tokens.cacheWrite},
    {id:"output", label:"Output", value:tokens.output},
    {id:"cache", label:"Cache", value:tokens.cacheRead},
    {id:"reasoning", label:"Reasoning", value:tokens.reasoning},
  ];
}
export function cost(value: number): string { return Number.isFinite(value) ? "~$" + value.toFixed(2) : "—"; }
function menuCost(amount: number, reported: boolean): string {
  if (!Number.isFinite(amount) || amount < 0 || (amount === 0 && !reported)) return "—";
  if (amount > 0 && amount < 0.01) return "<$0.01";
  const value = amount >= 1e6 ? (amount / 1e6).toFixed(1) + "M"
    : amount >= 1e3 ? (amount / 1e3).toFixed(1) + "K" : amount.toFixed(2);
  return (reported ? "$" : "~$") + value;
}
export function sessionCost(session: Session): string {
  const reported = session.requests.length > 0 && session.requests.every(request => request.costSource === "providerReported");
  return menuCost(session.costUsd, reported);
}
export function requestCost(request: Request): string {
  return menuCost(request.costUsd, request.costSource === "providerReported");
}
export function todayCost(totals: Totals, sessions: Session[], day: string): string {
  if (totals.costUsd > 0 || tokenTotal(totals.tokens) === 0) return cost(totals.costUsd);
  const priced = sessions.some(session => session.requests.some(turn =>
    (turn.contributions?.length ? turn.contributions : [turn]).some(request =>
      request.costSource !== "unknown" && new Date(request.endedAtMs).toISOString().slice(0, 10) === day)));
  return priced ? cost(totals.costUsd) : "—";
}
export function sourceFor(snapshot: Snapshot | undefined, platform: Platform): Source | undefined {
  return snapshot?.sources.find(s => s.platform === platform);
}
export function sessionsFor(snapshot: Snapshot | undefined, platform: Platform): Session[] {
  return (snapshot?.sessions ?? []).filter(s => s.platform === platform).sort((a, b) => b.endedAtMs - a.endedAtMs);
}
function physicalRequests(request: Request): Request[] {
  return request.contributions?.length ? request.contributions.flatMap(physicalRequests) : [request];
}
export function formatTPS(value: number | undefined): string | undefined {
  if (value == null || !Number.isFinite(value) || value <= 0) return undefined;
  if (value >= 1e6) return (value / 1e6).toFixed(1) + "M tok/s";
  if (value >= 1e3) return (value / 1e3).toFixed(1) + "K tok/s";
  return value.toFixed(1) + " tok/s";
}
export function formatFirstTokenTime(ms: number | null | undefined): string {
  if (ms == null || !Number.isFinite(ms) || ms < 0) return "—";
  return ms < 1000 ? Math.round(ms) + " ms" : (ms / 1000).toFixed(1) + " s";
}
export function firstTokenTime(request: Request): number | undefined {
  let total = 0, count = 0;
  for (const row of physicalRequests(request)) {
    const ms = row.timeToFirstTokenMs;
    if (ms != null && Number.isFinite(ms) && ms >= 0) { total += ms; count++; }
  }
  return count ? total / count : undefined;
}
function describeModels(requests: Request[], fallbackModels: string[] = [], includeTPS = false): string[] {
  const models = new Map<string, { efforts: Set<string>; tokens: number; durationMs: number; firstTokenMs: number; firstTokenCount: number }>();
  for (const request of requests) {
    const model = request.model?.trim() || "unknown";
    const entry = models.get(model) ?? { efforts: new Set<string>(), tokens: 0, durationMs: 0, firstTokenMs: 0, firstTokenCount: 0 };
    entry.efforts.add(request.reasoningEffort?.trim() || "未记录");
    const sample = generationSample(request);
    if (sample) {
      entry.tokens += sample.generatedTokens;
      entry.durationMs += sample.durationMs;
    }
    const first = request.timeToFirstTokenMs;
    if (first != null && Number.isFinite(first) && first >= 0) {
      entry.firstTokenMs += first;
      entry.firstTokenCount++;
    }
    models.set(model, entry);
  }
  for (const model of fallbackModels) if (!models.has(model)) models.set(model, { efforts: new Set(["未记录"]), tokens: 0, durationMs: 0, firstTokenMs: 0, firstTokenCount: 0 });
  if (!models.size) models.set("unknown", { efforts: new Set(["未记录"]), tokens: 0, durationMs: 0, firstTokenMs: 0, firstTokenCount: 0 });
  const levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "auto", "未记录"];
  return [...models].map(([model, entry]) => {
    let line = (model === "unknown" ? "模型未记录" : model) + " · effort: "
      + [...entry.efforts].sort((a, b) => levels.indexOf(a) - levels.indexOf(b) || a.localeCompare(b)).join(" / ");
    if (includeTPS && entry.durationMs > 0 && entry.tokens > 0) {
      const rate = entry.tokens * 1000 / entry.durationMs;
      const tps = formatTPS(rate);
      if (tps) line += " · " + tps;
    }
    if (entry.firstTokenCount) line += " · 平均首字 " + formatFirstTokenTime(entry.firstTokenMs / entry.firstTokenCount);
    return line;
  });
}
export function sessionModelDetails(session: Session, includeTPS = true): string[] {
  return describeModels(session.requests.flatMap(physicalRequests), session.models, includeTPS);
}
export function requestModelDetails(request: Request): string[] {
  return describeModels(physicalRequests(request), [], false);
}
export function locator(session: Session, request?: Request): string {
  return "platform=" + session.platform + " session_id=" + (request?.physicalSessionId ?? session.id)
    + (request ? " request_range=" + request.startedAtMs + ".." + request.endedAtMs : "");
}
export function throughput(request: Request): number | undefined {
  const leaves = request.contributions?.length ? request.contributions : [request];
  let tokens = 0, milliseconds = 0;
  for (const row of leaves) {
    const sample = generationSample(row);
    if (sample) {
      tokens += sample.generatedTokens;
      milliseconds += sample.durationMs;
    }
  }
  return milliseconds > 0 ? tokens * 1000 / milliseconds : undefined;
}
export function sessionThroughput(session: Session): number | undefined {
  const leaves = session.requests.flatMap(physicalRequests);
  let tokens = 0, milliseconds = 0;
  for (const row of leaves) {
    const sample = generationSample(row);
    if (sample) {
      tokens += sample.generatedTokens;
      milliseconds += sample.durationMs;
    }
  }
  return milliseconds > 0 && tokens > 0 ? tokens * 1000 / milliseconds : undefined;
}
export function sessionKey(session: Session): string { return (session.deviceId ?? "local") + ":" + session.platform + ":" + session.id; }
export { mergedSnapshot, currentRemotes } from "./merge";
