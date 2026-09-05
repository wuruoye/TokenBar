import { describe, expect, it } from "vitest";
import { locator, sessionsFor, sourceFor, throughput, tokenTotal, zeroTokens, mergedSnapshot, sessionKey, todayCost,
  remainingPercent, weeklyPacing, displayedBuckets, type Session, type Snapshot, type Request } from "./model";

describe("provider isolation and counting", () => {
  it("keeps identical session IDs in different platforms separate", () => {
    const snapshot = { sessions: [{ id: "same", platform: "codex", endedAtMs: 1 }, { id: "same", platform: "claude", endedAtMs: 2 }],
      sources: [{ platform: "codex", today: { requestCount: 3 } }, { platform: "claude", today: { requestCount: 5 } }] } as Snapshot;
    expect(sessionsFor(snapshot, "codex")).toHaveLength(1);
    expect(sourceFor(snapshot, "claude")?.today.requestCount).toBe(5);
    expect(sourceFor(snapshot, "grok")).toBeUndefined();
  });
  it("adds each disjoint helper token bucket once", () => {
    expect(tokenTotal({ input: 10, output: 20, cacheRead: 30, cacheWrite: 40, reasoning: 50 })).toBe(150);
  });
  it("copies physical request identity for subagents", () => {
    const session = { platform: "codex", id: "root" } as Session;
    const request = { physicalSessionId: "child", startedAtMs: 10, endedAtMs: 20 } as Request;
    expect(locator(session, request)).toBe("platform=codex session_id=child request_range=10..20");
  });
  it("weights throughput by model duration, omitting untimed output", () => {
    const request = { contributions: [
      { tokens: { ...zeroTokens(), output: 100 }, modelDurationMs: 1000 },
      { tokens: { ...zeroTokens(), output: 100, reasoning: 50 }, modelDurationMs: 3000 },
      { tokens: { ...zeroTokens(), output: 900 } }
    ] } as Request;
    expect(throughput(request)).toBe(62.5);
    expect(throughput({ tokens: zeroTokens() } as Request)).toBeUndefined();
  });
  it("distinguishes unpriced usage from a provider-reported zero cost", () => {
    const totals = { tokens: { ...zeroTokens(), output: 100 }, costUsd: 0, requestCount: 1, sessionCount: 1 };
    const session = { requests: [{ endedAtMs: Date.parse("2026-09-05T01:00:00Z"), costSource: "unknown" }] } as Session;
    expect(todayCost(totals, [session], "2026-09-05")).toBe("—");
    session.requests[0].costSource = "providerReported";
    expect(todayCost(totals, [session], "2026-09-05")).toBe("~$0.00");
  });
});

describe("macOS menu presentation", () => {
  it("shows remaining quota while preserving used percentage for pacing", () => {
    const window = {usedPercent:78,windowMinutes:10080,resetsAtMs:7*86400000};
    expect(remainingPercent(window)).toBe(22);
    const pacing = weeklyPacing(window, 3.5*86400000);
    expect(pacing).toEqual({day:4,expected:50,delta:28});
    expect(window.usedPercent).toBe(78);
  });
  it("does not invent pacing outside the known reset cycle", () => {
    const window = {usedPercent:0,windowMinutes:10080,resetsAtMs:8*86400000};
    expect(weeklyPacing(window,0)).toBeUndefined();
    expect(weeklyPacing(window,9*86400000)).toBeUndefined();
    expect(weeklyPacing({usedPercent:10},Date.now())).toBeUndefined();
  });
  it("includes cache writes in Input and counts every token once", () => {
    const tokens = {input:100,output:20,cacheRead:70,cacheWrite:30,reasoning:10};
    const buckets = displayedBuckets(tokens);
    expect(buckets.map(b => b.value)).toEqual([130,20,70,10]);
    expect(buckets.reduce((n,b) => n+b.value,0)).toBe(tokenTotal(tokens));
  });
});

describe("multi-device statistics", () => {
  function fixture(date: string, output: number): Snapshot {
    const totals = { tokens: { ...zeroTokens(), output }, costUsd: 1, sessionCount: 1, requestCount: 1 };
    const day = { ...totals, date, models: [] };
    return { schemaVersion: 9, timezone: "UTC", generatedAtMs: 1, today: totals, days: [day],
      sources: [{ platform: "codex", today: totals, days: [day] }],
      sessions: [{ id: "same", platform: "codex", endedAtMs: 1, tokens: totals.tokens, requests: [] } as unknown as Session] };
  }
  it("sums devices without changing the local snapshot or colliding session IDs", () => {
    const local = fixture("2026-09-05", 100);
    const result = mergedSnapshot(local, [{ deviceId: "remote", deviceName: "Mac", snapshot: fixture("2026-09-05", 200) }]);
    expect(result.sources[0].today.tokens.output).toBe(300);
    expect(local.sources[0].today.tokens.output).toBe(100);
    expect(new Set(result.sessions.map(sessionKey)).size).toBe(2);
    expect(result.sources[0].today.averageGenerationTokensPerSecond).toBeUndefined();
  });
  it("does not add an old device's Today into the current UTC day", () => {
    const local = fixture("2026-09-05", 100);
    const result = mergedSnapshot(local, [{ deviceId: "remote", deviceName: "Mac", snapshot: fixture("2026-09-04", 200) }]);
    expect(result.sources[0].today.tokens.output).toBe(100);
    expect(result.sources[0].days[0].tokens.output).toBe(100);
  });
  it("rejects incompatible calendars and schemas", () => {
    const local = fixture("2026-09-05", 100);
    const remote = { ...fixture("2026-09-05", 200), timezone: "Asia/Taipei" };
    expect(mergedSnapshot(local, [{ deviceId: "other", deviceName: "Other", snapshot: remote }]).sessions).toHaveLength(1);
  });
});
