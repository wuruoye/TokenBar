// Rebuild the display from local data plus the newest compatible device snapshots, as on macOS.
import type { Day, Remote, Snapshot, Source, Tokens, Totals } from "./model";

const latestDate = (snapshot: Snapshot) => snapshot.days.map(d => d.date).sort().at(-1);
export function currentRemotes(local: Snapshot, remotes: Remote[]): Remote[] {
  const latest = new Map<string, Remote>();
  for (const remote of remotes) {
    const id = remote.deviceId.toLowerCase();
    const previous = latest.get(id);
    if (!previous || remote.snapshot.generatedAtMs > previous.snapshot.generatedAtMs) latest.set(id, remote);
  }
  const day = latestDate(local);
  return [...latest.values()].filter(r => day && r.snapshot.schemaVersion > 0 && r.snapshot.timezone === local.timezone && latestDate(r.snapshot) === day);
}
function sum(values: number[]): number {
  return values.reduce((total, value) => Number.isFinite(value) && value > 0 ? Math.min(Number.MAX_VALUE, total + value) : total, 0);
}
function sumTokens(values: Tokens[]): Tokens {
  const total: Tokens = {input:0,output:0,cacheRead:0,cacheWrite:0,reasoning:0};
  for (const key of Object.keys(total) as Array<keyof Tokens>) total[key] = sum(values.map(v => v[key]));
  return total;
}
function sumTotals(values: Totals[]): Totals {
  let generated = 0, seconds = 0, firstTokenTotal = 0, samples = 0;
  for (const value of values) {
    const count = value.tokens.output + value.tokens.reasoning;
    const rate = value.averageGenerationTokensPerSecond;
    if (rate && Number.isFinite(rate) && rate > 0 && count > 0) { generated += count; seconds += count / rate; }
    if (value.firstTokenSampleCount && value.firstTokenSampleCount > 0 && value.averageTimeToFirstTokenMs != null) {
      samples += value.firstTokenSampleCount; firstTokenTotal += value.firstTokenSampleCount * value.averageTimeToFirstTokenMs;
    }
  }
  return { tokens:sumTokens(values.map(v=>v.tokens)), costUsd:sum(values.map(v=>v.costUsd)),
    sessionCount:sum(values.map(v=>v.sessionCount)), requestCount:sum(values.map(v=>v.requestCount)),
    tokenCosts:values.length && values.every(v=>v.tokenCosts != null) ? sumTokens(values.map(v=>v.tokenCosts!)) : undefined,
    averageGenerationTokensPerSecond:seconds > 0 ? generated / seconds : undefined,
    averageTimeToFirstTokenMs:samples > 0 ? firstTokenTotal / samples : undefined,
    firstTokenSampleCount:samples || undefined };
}
function mergeDays(days: Day[], allowed: Set<string>): Day[] {
  const groups = new Map<string, Day[]>();
  for (const day of days) if (allowed.has(day.date)) groups.set(day.date, [...(groups.get(day.date) ?? []), day]);
  return [...groups].sort(([a],[b])=>a.localeCompare(b)).map(([date, values]) => {
    const modelGroups = new Map<string, Day["models"]>();
    for (const model of values.flatMap(v=>v.models ?? [])) {
      const key = JSON.stringify([model.platform || "codex", model.model, model.provider || ""]);
      modelGroups.set(key, [...(modelGroups.get(key) ?? []), model]);
    }
    const models = [...modelGroups.values()].map(group => ({...group[0], platform:group[0].platform || "codex",
      tokens:sumTokens(group.map(m=>m.tokens)), costUsd:sum(group.map(m=>m.costUsd)),
      sessionCount:sum(group.map(m=>m.sessionCount ?? 0)), requestCount:sum(group.map(m=>m.requestCount ?? 0))}));
    return {...sumTotals(values), date, models};
  });
}
function rangeTotals(value: {days:Day[];rangeTotals?:Totals}, allowed:Set<string>): Totals {
  return value.rangeTotals && value.days.every(d=>allowed.has(d.date)) ? value.rangeTotals : sumTotals(mergeDays(value.days, allowed));
}
function mergeWeekly(ranges: Array<Source["weeklySinceReset"]>, target?: number): Source["weeklySinceReset"] {
  if (!target) return undefined;
  const matching = ranges.filter(r=>r?.startedAtMs === target);
  return matching.length ? {startedAtMs:target, totals:sumTotals(matching.map(r=>r!.totals))} : undefined;
}
export function mergedSnapshot(local: Snapshot, remotes: Remote[]): Snapshot {
  const compatible = currentRemotes(local, remotes);
  if (!compatible.length) return structuredClone(local);
  const snapshots = [local, ...compatible.map(r=>r.snapshot)];
  const allowed = new Set(local.days.map(d=>d.date));
  const sources = [...new Set(snapshots.flatMap(s=>s.sources.map(s=>s.platform)))].sort().map(platform => {
    const candidates = snapshots.flatMap(s=>s.sources.filter(s=>s.platform === platform));
    const target = local.sources.find(s=>s.platform === platform)?.weeklySinceReset?.startedAtMs;
    return {platform, today:sumTotals(candidates.map(s=>s.today)), days:mergeDays(candidates.flatMap(s=>s.days), allowed),
      rangeTotals:sumTotals(candidates.map(s=>rangeTotals(s, allowed))),
      weeklySinceReset:mergeWeekly(candidates.map(s=>s.weeklySinceReset), target)};
  });
  const sessions = [...structuredClone(local.sessions), ...compatible.flatMap(remote=>remote.snapshot.sessions.map(session=>
    ({...structuredClone(session),deviceId:remote.deviceId.toLowerCase(),deviceName:remote.deviceName})))];
  sessions.sort((a,b)=>b.endedAtMs-a.endedAtMs || a.platform.localeCompare(b.platform) || a.id.localeCompare(b.id));
  return {...structuredClone(local), today:sumTotals(snapshots.map(s=>s.today)), days:mergeDays(snapshots.flatMap(s=>s.days), allowed),
    rangeTotals:sumTotals(snapshots.map(s=>rangeTotals(s, allowed))), sources, sessions,
    weeklySinceReset:mergeWeekly(snapshots.map(s=>s.weeklySinceReset),local.weeklySinceReset?.startedAtMs)};
}
