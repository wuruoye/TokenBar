import {describe,expect,it} from "vitest";
import {mergedSnapshot,zeroTokens,sessionKey,type Snapshot,type Remote,type Totals} from "./model";
function fixture(output:number,at=1): Snapshot {
  const totals: Totals = {tokens:{...zeroTokens(),output},costUsd:output/100,requestCount:1,sessionCount:1,
    averageGenerationTokensPerSecond:10,tokenCosts:{...zeroTokens(),output:output/100}};
  const day = {...totals,date:"2026-09-06",models:[{model:"gpt-6-astra",provider:"openai",platform:"codex",...totals}]};
  return {schemaVersion:11,generatedAtMs:at,timezone:"UTC",today:totals,rangeTotals:totals,days:[day],
    sessions:[{id:"same",platform:"codex",startedAtMs:0,endedAtMs:at,tokens:totals.tokens,costUsd:totals.costUsd,models:["gpt-6-astra"],requests:[]}],
    sources:[{platform:"codex",today:totals,rangeTotals:totals,days:[day],weeklySinceReset:{startedAtMs:123,totals}}]};
}
const remote = (snapshot:Snapshot,id="mac"): Remote => ({deviceId:id,deviceName:id,snapshot});
describe("downloaded snapshot merging",()=>{
  it("rebuilds all totals using only the latest version of a device",()=>{
    const local=fixture(100); const incoming=[remote(fixture(200,2)),remote(fixture(300,3))];
    const merged=mergedSnapshot(local,incoming);
    expect(merged.today.tokens.output).toBe(400);
    expect(merged.days[0].tokens.output).toBe(400);
    expect(merged.rangeTotals?.tokens.output).toBe(400);
    expect(merged.sources[0].today.tokenCosts?.output).toBe(4);
    expect(merged.sources[0].days[0].models[0].tokens.output).toBe(400);
    expect(merged.sessions.map(sessionKey)).toHaveLength(2);
    expect(new Set(merged.sessions.map(sessionKey)).size).toBe(2);
    expect(mergedSnapshot(local,incoming)).toEqual(merged);
    expect(local.today.tokens.output).toBe(100);
  });
  it("excludes stale devices and incompatible calendars without requiring identical schema versions",()=>{
    const local=fixture(100),old=fixture(200,2),future=fixture(300,3),otherZone=fixture(400,4);
    old.days[0].date="2026-09-05"; future.schemaVersion=12;otherZone.timezone="Asia/Taipei";
    const merged=mergedSnapshot(local,[remote(old,"old"),remote(future,"future"),remote(otherZone,"other")]);
    expect(merged.today.tokens.output).toBe(400); expect(merged.sessions).toHaveLength(2);
  });
  it("keeps the local weekly cycle when another device reports a different reset",()=>{
    const local=fixture(100),matching=fixture(200),other=fixture(300);
    other.sources[0].weeklySinceReset!.startedAtMs=456;
    const merged=mergedSnapshot(local,[remote(matching,"matching"),remote(other,"other")]);
    expect(merged.sources[0].weeklySinceReset?.totals.tokens.output).toBe(300);
    expect(merged.sources[0].today.tokens.output).toBe(600);
  });
  it("weights throughput by generated tokens and keeps providers separate",()=>{
    const local=fixture(100),mac=fixture(300);
    mac.today.averageGenerationTokensPerSecond=30;
    mac.sources[0].days[0].models[0].provider="gateway";
    const merged=mergedSnapshot(local,[remote(mac)]);
    expect(merged.today.averageGenerationTokensPerSecond).toBe(20);
    expect(merged.sources[0].days[0].models).toHaveLength(2);
    mac.today.tokenCosts=undefined;
    expect(mergedSnapshot(local,[remote(mac)]).today.tokenCosts).toBeUndefined();
  });
});
