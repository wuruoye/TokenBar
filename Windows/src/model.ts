export type Platform = "codex" | "claude" | "grok";
export interface Tokens { input: number; output: number; cacheRead: number; cacheWrite: number; reasoning: number }
export interface Totals {
  tokens: Tokens; costUsd: number; sessionCount: number; requestCount: number;
  averageGenerationTokensPerSecond?: number | null;
  tokenCosts?: Tokens;
}
export interface Day extends Totals {
  date: string;
  models: Array<{ platform: string; model: string; tokens: Tokens; costUsd: number }>;
}
export interface Request {
  id: string; platform: string; sessionId: string; physicalSessionId: string;
  isSubagent: boolean; agent?: string; model: string; startedAtMs: number; endedAtMs: number;
  reasoningEffort?: string | null;
  modelDurationMs?: number; tokens: Tokens; costUsd: number; costSource: string; serviceTier: string;
  sessionPath?: string; promptPreview?: string; outputPreview?: string; contributions?: Request[];
}
export interface Session {
  deviceId?: string; deviceName?: string;
  id: string; platform: string; title?: string; workspaceLabel?: string;
  startedAtMs: number; endedAtMs: number; tokens: Tokens; costUsd: number; models: string[]; requests: Request[];
}
export interface Source { platform: string; today: Totals; rangeTotals?: Totals; days: Day[]; weeklySinceReset?: { startedAtMs: number; totals: Totals } }
export interface MemoryPhase { total: number; input: number; cachedInput: number; cacheWriteInput: number; output: number; reasoningOutput: number }
export interface Snapshot {
  schemaVersion: number; generatedAtMs: number; timezone: string;
  today: Totals; days: Day[]; sessions: Session[]; sources: Source[];
  memoryUsage?: { observationCount: number; rangeTotals: { phase1: MemoryPhase; phase2: MemoryPhase }; lastMemoryReceivedAtMs?: number };
  pricingCatalog?: {source:string;updatedAtMs?:number;modelCount:number;status:string};
}
export interface QuotaWindow { usedPercent: number; windowMinutes?: number; resetsAtMs?: number }
export interface Quota { session?: QuotaWindow; weekly?: QuotaWindow; updatedAtMs: number; error?: string; availableResetCredits?: number }
export interface Settings {
  refreshSeconds: number; recentLimit: number; theme: string; showClaude: boolean; showGrok: boolean;
  autostart: boolean; codexHome: string; claudeHome: string; grokHome: string; codexBinary: string; memoryEnabled: boolean;
  syncEnabled: boolean; syncEndpoint: string; syncDeviceName: string;
  taskbarEnabled: boolean; taskbarPlatform: string; taskbarPosition: string;
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
export function remainingPercent(window: QuotaWindow): number { return Math.max(0, Math.min(100, 100 - window.usedPercent)); }
export function weeklyPacing(window: QuotaWindow, measuredAt: number) {
  const duration = (window.windowMinutes ?? 0) * 60000;
  const end = window.resetsAtMs;
  if (!end || !duration || measuredAt >= end || measuredAt < end - duration) return undefined;
  const elapsed = measuredAt - end + duration;
  if (elapsed === 0 && window.usedPercent > 0) return undefined;
  const expected = elapsed / duration * 100;
  return { day: Math.min(7, Math.floor(elapsed / duration * 7) + 1), expected, delta: window.usedPercent - expected };
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
function describeModels(requests: Request[], fallbackModels: string[] = []): string[] {
  const models = new Map<string, Set<string>>();
  for (const request of requests) {
    const model = request.model?.trim() || "unknown";
    const efforts = models.get(model) ?? new Set<string>();
    efforts.add(request.reasoningEffort?.trim() || "未记录");
    models.set(model, efforts);
  }
  for (const model of fallbackModels) if (!models.has(model)) models.set(model, new Set(["未记录"]));
  if (!models.size) models.set("unknown", new Set(["未记录"]));
  const levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "auto", "未记录"];
  return [...models].map(([model, efforts]) => (model === "unknown" ? "模型未记录" : model) + " · effort: "
    + [...efforts].sort((a, b) => levels.indexOf(a) - levels.indexOf(b) || a.localeCompare(b)).join(" / "));
}
export function sessionModelDetails(session: Session): string[] {
  return describeModels(session.requests.flatMap(physicalRequests), session.models);
}
export function requestModelDetails(request: Request): string[] {
  return describeModels(physicalRequests(request));
}
export function locator(session: Session, request?: Request): string {
  return "platform=" + session.platform + " session_id=" + (request?.physicalSessionId ?? session.id)
    + (request ? " request_range=" + request.startedAtMs + ".." + request.endedAtMs : "");
}
export function throughput(request: Request): number | undefined {
  const leaves = request.contributions?.length ? request.contributions : [request];
  let tokens = 0, milliseconds = 0;
  for (const row of leaves) {
    if (row.modelDurationMs && row.modelDurationMs > 0 && row.tokens.output + row.tokens.reasoning > 0) {
      tokens += row.tokens.output + row.tokens.reasoning;
      milliseconds += row.modelDurationMs;
    }
  }
  return milliseconds > 0 ? tokens * 1000 / milliseconds : undefined;
}
export function sessionKey(session: Session): string { return (session.deviceId ?? "local") + ":" + session.id; }
function addTokens(left: Tokens, right: Tokens): Tokens {
  return { input: left.input + right.input, output: left.output + right.output,
    cacheRead: left.cacheRead + right.cacheRead, cacheWrite: left.cacheWrite + right.cacheWrite,
    reasoning: left.reasoning + right.reasoning };
}
function addTotals(left: Totals, right: Totals): Totals {
  return { tokens: addTokens(left.tokens, right.tokens), costUsd: left.costUsd + right.costUsd,
    sessionCount: left.sessionCount + right.sessionCount, requestCount: left.requestCount + right.requestCount };
}
export function mergedSnapshot(local: Snapshot, remotes: Remote[]): Snapshot {
  const merged = structuredClone(local);
  const today = local.days.at(-1)?.date;
  for (const remote of remotes) {
    const snapshot = remote.snapshot;
    if (snapshot.schemaVersion !== local.schemaVersion || snapshot.timezone !== local.timezone) continue;
    const sameDay = snapshot.days.at(-1)?.date === today;
    merged.sessions.push(...snapshot.sessions.map(s => ({ ...s, deviceId: remote.deviceId, deviceName: remote.deviceName })));
    for (const incoming of snapshot.sources) {
      let source = merged.sources.find(s => s.platform === incoming.platform);
      if (!source) {
        source = { platform: incoming.platform, today: { tokens: zeroTokens(), costUsd: 0, sessionCount: 0, requestCount: 0 },
          days: local.days.map(d => ({ date: d.date, tokens: zeroTokens(), costUsd: 0, sessionCount: 0, requestCount: 0, models: [] })) };
        merged.sources.push(source);
      }
      if (sameDay) source.today = addTotals(source.today, incoming.today);
      if (source.weeklySinceReset && incoming.weeklySinceReset
        && source.weeklySinceReset.startedAtMs === incoming.weeklySinceReset.startedAtMs) {
        source.weeklySinceReset.totals = addTotals(source.weeklySinceReset.totals, incoming.weeklySinceReset.totals);
      } else { source.weeklySinceReset = undefined; }
      source.days = source.days.map(day => {
        const other = incoming.days.find(d => d.date === day.date);
        if (!other) return day;
        const models = structuredClone(day.models);
        for (const incomingModel of other.models ?? []) {
          const model = models.find(m => m.platform === incomingModel.platform && m.model === incomingModel.model);
          if (model) { model.tokens = addTokens(model.tokens, incomingModel.tokens); model.costUsd += incomingModel.costUsd; }
          else models.push(structuredClone(incomingModel));
        }
        return { ...addTotals(day, other), date: day.date, models };
      });
    }
  }
  return merged;
}
