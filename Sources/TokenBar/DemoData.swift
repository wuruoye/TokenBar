#if DEBUG
import AppKit
import Foundation
import SwiftUI
import TokenBarCore

struct DemoQuotaProvider: QuotaProviding {
    let platform = TokenPlatform.codex

    func fetchQuota() async throws -> QuotaSnapshot {
        let now = Date()
        let object: [String: Any] = [
            "session": [
                "usedPercent": 37,
                "windowMinutes": 300,
                "resetsAt": now.addingTimeInterval(2.4 * 3600).timeIntervalSinceReferenceDate,
            ],
            "weekly": [
                "usedPercent": 31,
                "windowMinutes": 10_080,
                "resetsAt": now.addingTimeInterval(3.2 * 86_400).timeIntervalSinceReferenceDate,
            ],
            "resetCredits": [
                "availableCount": 2,
                "nextExpiresAt": now.addingTimeInterval(5 * 86_400).timeIntervalSinceReferenceDate,
            ],
            "updatedAt": now.timeIntervalSinceReferenceDate,
        ]
        return try JSONDecoder().decode(QuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

struct DemoClaudeQuotaProvider: QuotaProviding {
    let platform = TokenPlatform.claude

    func fetchQuota() async throws -> QuotaSnapshot {
        let now = Date()
        let object: [String: Any] = [
            "session": [
                "usedPercent": 54,
                "windowMinutes": 300,
                "resetsAt": now.addingTimeInterval(1.6 * 3600).timeIntervalSinceReferenceDate,
            ],
            "weekly": [
                "usedPercent": 46,
                "windowMinutes": 10_080,
                "resetsAt": now.addingTimeInterval(5.1 * 86_400).timeIntervalSinceReferenceDate,
            ],
            "updatedAt": now.timeIntervalSinceReferenceDate,
        ]
        return try JSONDecoder().decode(
            QuotaSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
}

struct DemoGrokQuotaProvider: QuotaProviding {
    let platform = TokenPlatform.grok

    func fetchQuota() async throws -> QuotaSnapshot {
        let now = Date()
        let object: [String: Any] = [
            "weekly": [
                "usedPercent": 28,
                "windowMinutes": 10_080,
                "resetsAt": now.addingTimeInterval(4.4 * 86_400).timeIntervalSinceReferenceDate,
            ],
            "updatedAt": now.timeIntervalSinceReferenceDate,
        ]
        return try JSONDecoder().decode(
            QuotaSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
}

struct DemoActivityProvider: ActivityProviding {
    func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        var resets: [TokenPlatform: Date] = [:]
        resets[.codex] = sinceWeeklyResetAt
        return try self.makeSnapshot(sinceWeeklyResetAtByPlatform: resets)
    }

    func fetchActivity(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date],
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        try self.makeSnapshot(sinceWeeklyResetAtByPlatform: sinceWeeklyResetAtByPlatform)
    }

    private func makeSnapshot(
        sinceWeeklyResetAtByPlatform: [TokenPlatform: Date]) throws -> ActivitySnapshot
    {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let prompts = [
            "Refine the menu bar dashboard layout",
            "Implement session request aggregation",
            "Investigate weekly quota reset behavior",
            "Polish the activity chart colors",
            "Add clipboard summaries for requests",
            "Review token cache accounting",
            "Simplify the packaging script",
            "Improve empty state messaging",
            "Validate helper JSON decoding",
            "Tune the menu spacing and typography",
            "Add stable session ordering tests",
            "Document the TokenBar architecture",
        ]

        var sessions: [[String: Any]] = []
        var today = DemoTokenCounter()
        var todayByPlatform: [TokenPlatform: DemoTokenCounter] = [
            .codex: DemoTokenCounter(),
            .claude: DemoTokenCounter(),
            .grok: DemoTokenCounter(),
        ]
        var requestCountByPlatform: [TokenPlatform: Int] = [.codex: 0, .claude: 0, .grok: 0]
        var sessionCountByPlatform: [TokenPlatform: Int] = [.codex: 0, .claude: 0, .grok: 0]
        var requestCount = 0
        for (sessionIndex, prompt) in prompts.enumerated() {
            let platform = sessionIndex.isMultiple(of: 2)
                ? TokenPlatform.codex
                : TokenPlatform.claude
            let model = platform == .codex ? "gpt-5" : "claude-sonnet-4-5"
            let provider = platform == .codex ? "openai" : "anthropic"
            let agent = platform == .codex ? "codex" : "claude"
            var requests: [[String: Any]] = []
            var sessionTokens = DemoTokenCounter()
            for requestIndex in 0 ..< 3 {
                let tokens = DemoTokenCounter(
                    input: Int64(1_400 + sessionIndex * 115 + requestIndex * 180),
                    output: Int64(720 + sessionIndex * 60 + requestIndex * 90),
                    cacheRead: Int64(2_800 + sessionIndex * 170 + requestIndex * 240),
                    cacheWrite: Int64(180 + requestIndex * 40),
                    reasoning: Int64(90 + requestIndex * 25))
                sessionTokens.add(tokens)
                today.add(tokens)
                todayByPlatform[platform]?.add(tokens)
                requestCount += 1
                requestCountByPlatform[platform, default: 0] += 1
                let startedAtMs = nowMs
                    - Int64(sessionIndex * 29 * 60 * 1000)
                    - Int64((2 - requestIndex) * 4 * 60 * 1000)
                let requestPrompt = requestIndex == 0
                    ? prompt
                    : ["Continue with the implementation", "Run focused validation"][requestIndex - 1]
                let serviceTier = sessionIndex.isMultiple(of: 3) ? "fast" : "standard"
                var request: [String: Any] = [
                    "id": "request-\(sessionIndex)-\(requestIndex)",
                    "platform": platform.rawValue,
                    "sessionId": "session-\(sessionIndex)",
                    "physicalSessionId": "physical-\(sessionIndex)",
                    "isSubagent": false,
                    "agent": agent,
                    "model": model,
                    "provider": provider,
                    "startedAtMs": startedAtMs,
                    "endedAtMs": startedAtMs + 82_000,
                    "durationMs": 82_000,
                    "modelDurationMs": 12_000,
                    "timeToFirstTokenMs": 4_800 + requestIndex * 650,
                    "tokens": tokens.object,
                    "costUsd": Double(tokens.total) / 1_000_000 * 4.2,
                    "costSource": "estimated",
                    "serviceTier": serviceTier,
                    "promptPreview": requestPrompt,
                    "outputPreview": "Completed the requested changes and verified the relevant behavior.",
                ]
                if requestIndex == 0, sessionIndex.isMultiple(of: 2) {
                    let mainTokens = tokens.scaled(numerator: 3, denominator: 4)
                    let childTokens = tokens.subtracting(mainTokens)
                    let childServiceTier = sessionIndex == 0 ? "standard" : serviceTier
                    if childServiceTier != serviceTier {
                        request["serviceTier"] = "mixed"
                    }
                    request["contributions"] = [
                        [
                            "id": "main-\(sessionIndex)-\(requestIndex)",
                            "platform": platform.rawValue,
                            "sessionId": "session-\(sessionIndex)",
                            "physicalSessionId": "physical-\(sessionIndex)",
                            "isSubagent": false,
                            "agent": agent,
                            "model": model,
                            "provider": provider,
                            "startedAtMs": startedAtMs,
                            "endedAtMs": startedAtMs + 48_000,
                            "durationMs": 48_000,
                            "modelDurationMs": 7_500,
                            "timeToFirstTokenMs": 4_800 + requestIndex * 650,
                            "tokens": mainTokens.object,
                            "costUsd": Double(mainTokens.total) / 1_000_000 * 4.2,
                            "costSource": "estimated",
                            "serviceTier": serviceTier,
                            "promptPreview": requestPrompt,
                            "outputPreview": "Coordinated the implementation and integrated the result.",
                        ],
                        [
                            "id": "child-\(sessionIndex)-\(requestIndex)",
                            "platform": platform.rawValue,
                            "sessionId": "session-\(sessionIndex)",
                            "physicalSessionId": "child-\(sessionIndex)",
                            "isSubagent": true,
                            "agent": "reviewer",
                            "model": model,
                            "provider": provider,
                            "startedAtMs": startedAtMs + 16_000,
                            "endedAtMs": startedAtMs + 82_000,
                            "durationMs": 66_000,
                            "modelDurationMs": 9_000,
                            "timeToFirstTokenMs": 6_200 + requestIndex * 700,
                            "tokens": childTokens.object,
                            "costUsd": Double(childTokens.total) / 1_000_000 * 4.2,
                            "costSource": "estimated",
                            "serviceTier": childServiceTier,
                            "promptPreview": "Review the implementation for edge cases.",
                            "outputPreview": "Verified the nested request grouping and copy ranges.",
                        ],
                    ]
                }
                requests.append(request)
            }

            sessionCountByPlatform[platform, default: 0] += 1
            sessions.append([
                "id": "session-\(sessionIndex)",
                "platform": platform.rawValue,
                "workspaceLabel": sessionIndex.isMultiple(of: 3) ? "TokenBar" : "Platform Adapter",
                "startedAtMs": nowMs - Int64((sessionIndex * 29 + 12) * 60 * 1000),
                "endedAtMs": nowMs - Int64(sessionIndex * 29 * 60 * 1000),
                "tokens": sessionTokens.object,
                "costUsd": Double(sessionTokens.total) / 1_000_000 * 4.2,
                "models": [model],
                "requests": Array(requests.reversed()),
            ])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar(identifier: .gregorian)
        var days: [[String: Any]] = []
        var sourceDays: [TokenPlatform: [[String: Any]]] = [.codex: [], .claude: [], .grok: []]
        var range = DemoTokenCounter()
        var rangeByPlatform: [TokenPlatform: DemoTokenCounter] = [
            .codex: DemoTokenCounter(),
            .claude: DemoTokenCounter(),
            .grok: DemoTokenCounter(),
        ]
        var rangeRequestCount = 0
        var rangeSessionCount = 0
        var rangeRequestCountByPlatform: [TokenPlatform: Int] = [.codex: 0, .claude: 0, .grok: 0]
        var rangeSessionCountByPlatform: [TokenPlatform: Int] = [.codex: 0, .claude: 0, .grok: 0]
        var weeklyByPlatform: [TokenPlatform: DemoTokenCounter] = [
            .codex: DemoTokenCounter(),
            .claude: DemoTokenCounter(),
            .grok: DemoTokenCounter(),
        ]
        var weeklyRequestCount: [TokenPlatform: Int] = [.codex: 0, .claude: 0, .grok: 0]
        var weeklySessionCount: [TokenPlatform: Int] = [.codex: 0, .claude: 0, .grok: 0]
        for offset in (0 ..< 30).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let wave = Int64((29 - offset) % 7)
            let tokens = DemoTokenCounter(
                input: 14_000 + wave * 1_800,
                output: 8_000 + wave * 900,
                cacheRead: 26_000 + wave * 3_200,
                cacheWrite: 1_200,
                reasoning: 2_200 + wave * 250)
            let primaryModel = tokens.scaled(numerator: 2, denominator: 3)
            let secondaryModel = tokens.subtracting(primaryModel)
            let dayCost = Double(tokens.total) / 1_000_000 * 4.2
            let dayAverageTPS = 24.5 + Double(wave) * 1.2
            let dayRequestCount = 12 + Int(wave)
            let daySessionCount = 4 + Int(wave % 3)
            let codexRequestCount = 8 + Int(wave / 2)
            let claudeRequestCount = 4 + Int(wave - wave / 2)
            let codexSessionCount = 3 + Int(wave % 2)
            let claudeSessionCount = 1 + Int(wave % 2)
            let codexCost = dayCost * Double(primaryModel.total) / Double(max(1, tokens.total))
            let claudeCost = dayCost * Double(secondaryModel.total) / Double(max(1, tokens.total))
            range.add(tokens)
            rangeRequestCount += dayRequestCount
            rangeSessionCount += daySessionCount
            for (
                platform,
                platformTokens,
                platformCost,
                platformRequestCount,
                platformSessionCount,
                model,
                provider
            ) in [
                (
                    TokenPlatform.codex,
                    primaryModel,
                    codexCost,
                    codexRequestCount,
                    codexSessionCount,
                    "gpt-5",
                    "openai"
                ),
                (
                    TokenPlatform.claude,
                    secondaryModel,
                    claudeCost,
                    claudeRequestCount,
                    claudeSessionCount,
                    "claude-sonnet-4-5",
                    "anthropic"
                ),
            ] {
                rangeByPlatform[platform]?.add(platformTokens)
                rangeRequestCountByPlatform[platform, default: 0] += platformRequestCount
                rangeSessionCountByPlatform[platform, default: 0] += platformSessionCount
                if let reset = sinceWeeklyResetAtByPlatform[platform], date >= reset {
                    weeklyByPlatform[platform]?.add(platformTokens)
                    weeklyRequestCount[platform, default: 0] += platformRequestCount
                    weeklySessionCount[platform, default: 0] += platformSessionCount
                }
                sourceDays[platform, default: []].append([
                    "date": formatter.string(from: date),
                    "tokens": platformTokens.object,
                    "costUsd": platformCost,
                    "averageGenerationTokensPerSecond": platform == .codex
                        ? dayAverageTPS + 3
                        : dayAverageTPS - 3,
                    "averageTimeToFirstTokenMs": platform == .codex ? 5_400 : 7_200,
                    "firstTokenSampleCount": platformRequestCount,
                    "requestCount": platformRequestCount,
                    "sessionCount": platformSessionCount,
                    "models": [[
                        "platform": platform.rawValue,
                        "model": model,
                        "provider": provider,
                        "tokens": platformTokens.object,
                        "costUsd": platformCost,
                        "requestCount": platformRequestCount,
                        "sessionCount": platformSessionCount,
                    ]],
                ])
            }
            days.append([
                "date": formatter.string(from: date),
                "tokens": tokens.object,
                "costUsd": dayCost,
                "averageGenerationTokensPerSecond": dayAverageTPS,
                "averageTimeToFirstTokenMs": 6_300,
                "firstTokenSampleCount": dayRequestCount,
                "requestCount": dayRequestCount,
                "sessionCount": daySessionCount,
                "models": [
                    [
                        "platform": TokenPlatform.codex.rawValue,
                        "model": "gpt-5",
                        "provider": "openai",
                        "tokens": primaryModel.object,
                        "costUsd": codexCost,
                        "requestCount": codexRequestCount,
                        "sessionCount": codexSessionCount,
                    ],
                    [
                        "platform": TokenPlatform.claude.rawValue,
                        "model": "claude-sonnet-4-5",
                        "provider": "anthropic",
                        "tokens": secondaryModel.object,
                        "costUsd": claudeCost,
                        "requestCount": claudeRequestCount,
                        "sessionCount": claudeSessionCount,
                    ],
                ],
            ])
        }

        var sources: [[String: Any]] = []
        for platform in [TokenPlatform.codex, .claude, .grok] {
            let platformToday = todayByPlatform[platform] ?? DemoTokenCounter()
            let platformRange = rangeByPlatform[platform] ?? DemoTokenCounter()
            let averageTPS = switch platform {
            case .codex: 31.2
            case .claude: 23.4
            case .grok: 28.7
            default: 0.0
            }
            var source: [String: Any] = [
                "platform": platform.rawValue,
                "today": [
                    "tokens": platformToday.object,
                    "costUsd": Double(platformToday.total) / 1_000_000 * 4.2,
                    "tokenCosts": platformToday.costObject,
                    "averageTimeToFirstTokenMs": 5_900,
                    "firstTokenSampleCount": requestCountByPlatform[platform] ?? 0,
                    "requestCount": requestCountByPlatform[platform] ?? 0,
                    "sessionCount": sessionCountByPlatform[platform] ?? 0,
                ],
                "rangeTotals": [
                    "tokens": platformRange.object,
                    "costUsd": Double(platformRange.total) / 1_000_000 * 4.2,
                    "tokenCosts": platformRange.costObject,
                    "averageGenerationTokensPerSecond": averageTPS,
                    "averageTimeToFirstTokenMs": 6_100,
                    "firstTokenSampleCount": rangeRequestCountByPlatform[platform] ?? 0,
                    "requestCount": rangeRequestCountByPlatform[platform] ?? 0,
                    "sessionCount": rangeSessionCountByPlatform[platform] ?? 0,
                ],
                "days": sourceDays[platform] ?? [],
            ]
            if let reset = sinceWeeklyResetAtByPlatform[platform] {
                let weekly = weeklyByPlatform[platform] ?? DemoTokenCounter()
                source["weeklySinceReset"] = [
                    "startedAtMs": Int64(reset.timeIntervalSince1970 * 1000),
                    "totals": [
                        "tokens": weekly.object,
                        "costUsd": Double(weekly.total) / 1_000_000 * 4.2,
                        "tokenCosts": weekly.costObject,
                        "averageGenerationTokensPerSecond": averageTPS,
                        "averageTimeToFirstTokenMs": 6_100,
                        "firstTokenSampleCount": weeklyRequestCount[platform] ?? 0,
                        "requestCount": weeklyRequestCount[platform] ?? 0,
                        "sessionCount": weeklySessionCount[platform] ?? 0,
                    ],
                ]
            }
            sources.append(source)
        }

        let demoEnvironment = ProcessInfo.processInfo.environment
        let memoryIncludesData = demoEnvironment["TOKENBAR_DEMO_MEMORY_EMPTY"] != "1"
            && demoEnvironment["TOKENBAR_DEMO_MEMORY_DISCONNECTED"] != "1"
            && demoEnvironment["TOKENBAR_DEMO_MEMORY_WAITING"] != "1"
        let memoryHasOtlpConnection = memoryIncludesData
            || demoEnvironment["TOKENBAR_DEMO_MEMORY_WAITING"] == "1"
        let object: [String: Any] = [
            "schemaVersion": 11,
            "generatedAtMs": nowMs,
            "timezone": TimeZone.current.identifier,
            "today": [
                "tokens": today.object,
                "costUsd": Double(today.total) / 1_000_000 * 4.2,
                "tokenCosts": today.costObject,
                "averageTimeToFirstTokenMs": 5_900,
                "firstTokenSampleCount": requestCount,
                "requestCount": requestCount,
                "sessionCount": sessions.count,
            ],
            "rangeTotals": [
                "tokens": range.object,
                "costUsd": Double(range.total) / 1_000_000 * 4.2,
                "tokenCosts": range.costObject,
                "averageGenerationTokensPerSecond": 27.3,
                "averageTimeToFirstTokenMs": 6_300,
                "firstTokenSampleCount": rangeRequestCount,
                "requestCount": rangeRequestCount,
                "sessionCount": rangeSessionCount,
            ],
            "sessions": sessions,
            "days": days,
            "sources": sources,
            "memoryUsage": self.makeMemoryUsage(
                now: now,
                formatter: formatter,
                calendar: calendar,
                includesData: memoryIncludesData,
                hasOtlpConnection: memoryHasOtlpConnection),
        ]
        return try JSONDecoder().decode(ActivitySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func makeMemoryUsage(
        now: Date,
        formatter: DateFormatter,
        calendar: Calendar,
        includesData: Bool,
        hasOtlpConnection: Bool) -> [String: Any]
    {
        var phase1Range = DemoMemoryCounter()
        var phase2Range = DemoMemoryCounter()
        var memoryDays: [[String: Any]] = []
        for offset in (0 ..< 30).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let index = 29 - offset
            let hasMemoryRun = includesData && ![3, 8, 14, 21, 26].contains(index)
            let wave = Int64(index % 6)
            let phase1 = hasMemoryRun
                ? DemoMemoryCounter(
                    total: 104_000 + wave * 9_200,
                    input: 91_000 + wave * 8_000,
                    cachedInput: 62_000 + wave * 5_600,
                    cacheWriteInput: 3_200 + wave * 300,
                    output: 13_000 + wave * 1_200,
                    reasoningOutput: 3_900 + wave * 420)
                : DemoMemoryCounter()
            let phase2 = hasMemoryRun
                ? DemoMemoryCounter(
                    total: 47_000 + wave * 4_100,
                    input: 39_000 + wave * 3_500,
                    cachedInput: 26_000 + wave * 2_500,
                    cacheWriteInput: 1_100 + wave * 100,
                    output: 8_000 + wave * 600,
                    reasoningOutput: 2_300 + wave * 220)
                : DemoMemoryCounter()
            phase1Range.add(phase1)
            phase2Range.add(phase2)
            memoryDays.append([
                "date": formatter.string(from: date),
                "phase1": phase1.object,
                "phase2": phase2.object,
            ])
        }
        let today = memoryDays.last ?? [
            "phase1": DemoMemoryCounter().object,
            "phase2": DemoMemoryCounter().object,
        ]
        return [
            "collectedFromMs": Int64(
                (calendar.date(byAdding: .day, value: -29, to: now) ?? now)
                    .timeIntervalSince1970 * 1000),
            "lastReceivedAtMs": hasOtlpConnection
                ? Int64(now.addingTimeInterval(-6 * 60).timeIntervalSince1970 * 1000)
                : NSNull(),
            "lastMemoryReceivedAtMs": includesData
                ? Int64(now.addingTimeInterval(-6 * 60).timeIntervalSince1970 * 1000)
                : NSNull(),
            "observationCount": includesData ? 300 : 0,
            "today": [
                "phase1": today["phase1"] ?? DemoMemoryCounter().object,
                "phase2": today["phase2"] ?? DemoMemoryCounter().object,
            ],
            "rangeTotals": [
                "phase1": phase1Range.object,
                "phase2": phase2Range.object,
            ],
            "days": memoryDays,
        ]
    }
}

struct DemoRequestDetailProvider: RequestDetailProviding {
    func fetchDetail(for request: RequestSummary) async throws -> RequestDetail {
        RequestDetail(
            prompt: """
            \(request.promptPreview ?? "Refine the TokenBar experience")

            Keep the menu compact, preserve Tokscale-compatible accounting, and make the hierarchy easy to scan.
            """,
            output: """
            Implemented the requested TokenBar update.

            - Preserved the full multiline response.
            - Added focused offline validation.
            - Kept request content in memory only.

            The request detail view can scroll when the transcript is longer than the menu.
            """)
    }
}

private struct DemoTokenCounter {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0

    var total: Int64 {
        self.input + self.output + self.cacheRead + self.cacheWrite + self.reasoning
    }

    var object: [String: Int64] {
        [
            "input": self.input,
            "output": self.output,
            "cacheRead": self.cacheRead,
            "cacheWrite": self.cacheWrite,
            "reasoning": self.reasoning,
        ]
    }

    var costObject: [String: Double] {
        let rate = 4.2 / 1_000_000
        return [
            "input": Double(self.input) * rate,
            "output": Double(self.output) * rate,
            "cacheRead": Double(self.cacheRead) * rate,
            "cacheWrite": Double(self.cacheWrite) * rate,
            "reasoning": Double(self.reasoning) * rate,
        ]
    }

    mutating func add(_ other: DemoTokenCounter) {
        self.input += other.input
        self.output += other.output
        self.cacheRead += other.cacheRead
        self.cacheWrite += other.cacheWrite
        self.reasoning += other.reasoning
    }

    func scaled(numerator: Int64, denominator: Int64) -> DemoTokenCounter {
        DemoTokenCounter(
            input: self.input * numerator / denominator,
            output: self.output * numerator / denominator,
            cacheRead: self.cacheRead * numerator / denominator,
            cacheWrite: self.cacheWrite * numerator / denominator,
            reasoning: self.reasoning * numerator / denominator)
    }

    func subtracting(_ other: DemoTokenCounter) -> DemoTokenCounter {
        DemoTokenCounter(
            input: self.input - other.input,
            output: self.output - other.output,
            cacheRead: self.cacheRead - other.cacheRead,
            cacheWrite: self.cacheWrite - other.cacheWrite,
            reasoning: self.reasoning - other.reasoning)
    }
}

private struct DemoMemoryCounter {
    var total: Int64 = 0
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var cacheWriteInput: Int64 = 0
    var output: Int64 = 0
    var reasoningOutput: Int64 = 0

    var object: [String: Int64] {
        [
            "total": self.total,
            "input": self.input,
            "cachedInput": self.cachedInput,
            "cacheWriteInput": self.cacheWriteInput,
            "output": self.output,
            "reasoningOutput": self.reasoningOutput,
        ]
    }

    mutating func add(_ other: DemoMemoryCounter) {
        self.total += other.total
        self.input += other.input
        self.cachedInput += other.cachedInput
        self.cacheWriteInput += other.cacheWriteInput
        self.output += other.output
        self.reasoningOutput += other.reasoningOutput
    }
}

@MainActor
enum DemoPreviewRenderer {
    static func render(model: DashboardModel, path: String) throws {
        if let rawScope = ProcessInfo.processInfo.environment["TOKENBAR_DEMO_SCOPE"],
           let scope = DashboardScope(rawValue: rawScope)
        {
            model.scope = scope
        }
        let showsClaude = ProcessInfo.processInfo.environment["TOKENBAR_DEMO_SHOWS_CLAUDE"] != "0"
        let showsGrok = ProcessInfo.processInfo.environment["TOKENBAR_DEMO_SHOWS_GROK"] != "0"
        let visibleScopes = DashboardScope.visibleScopes(
            showsClaude: showsClaude,
            showsGrok: showsGrok)
        if !visibleScopes.contains(model.scope) {
            model.scope = .codex
        }
        let height = DashboardSummaryView.preferredHeight(
            quota: model.quotaState(for: model.scope.platform).value,
            showsClaude: showsClaude,
            showsGrok: showsGrok)
        let content = DashboardSummaryView(
            model: model,
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            usesWeekdayWeeklyPacing: false,
            accentColor: .purple)
            .frame(width: 384, height: height, alignment: .top)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func renderRows(model: DashboardModel, path: String) throws {
        guard
            let session = model.activitySnapshot?.sessions.first,
            let request = session.requests.first(where: { $0.physicalRequests.count > 1 })
                ?? session.requests.first
        else {
            return
        }

        let width: CGFloat = 384
        let physicalRequests = Array(request.physicalRequests.prefix(3))
        let rowCount = 2 + physicalRequests.count
        let canvas = DemoRowPreviewCanvas(
            frame: NSRect(
                x: 0,
                y: 0,
                width: width,
                height: TokenMenuRowView.rowHeight * CGFloat(rowCount)))
        let sessionRow = TokenMenuRowView(width: width)
        sessionRow.configure(
            title: session.menuDisplayTitle,
            cost: session.menuCostText,
            detail: session.menuDetail,
            trailing: Date(timeIntervalSince1970: Double(session.endedAtMs) / 1000).demoClockText,
            showsChevron: true,
            badge: session.menuServiceTierBadge)

        let requestRow = TokenMenuRowView(width: width)
        requestRow.configure(
            title: request.menuRowTitle,
            cost: request.menuCostText,
            detail: request.menuDetail,
            trailing: "\(request.startedAt.demoClockText) · \(request.menuDurationText)",
            showsChevron: true,
            badge: request.menuServiceTierBadge)

        var rows = [sessionRow, requestRow]
        rows.append(contentsOf: physicalRequests.map { physicalRequest in
            let row = TokenMenuRowView(width: width)
            row.configure(
                title: physicalRequest.agentRequestMenuTitle,
                cost: physicalRequest.menuCostText,
                detail: physicalRequest.menuDetail,
                trailing: "\(physicalRequest.startedAt.demoClockText) · \(physicalRequest.menuDurationText)",
                showsChevron: true,
                badge: physicalRequest.menuServiceTierBadge)
            return row
        })
        for (index, row) in rows.enumerated() {
            row.frame.origin.y = TokenMenuRowView.rowHeight * CGFloat(rowCount - index - 1)
            canvas.addSubview(row)
        }
        canvas.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.bounds.width * 2),
            pixelsHigh: Int(canvas.bounds.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return
        }
        representation.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func renderActivityDetail(model: DashboardModel, path: String) throws {
        let content = ActivityDetailView(
            model: model,
            usesWeekdayWeeklyPacing: false,
            accentColor: .purple)
            .frame(
                width: ActivityDetailView.preferredWidth,
                height: ActivityDetailView.preferredHeight)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: ActivityDetailView.preferredWidth,
            height: ActivityDetailView.preferredHeight)
        let canvas = DemoRowPreviewCanvas(frame: host.bounds)
        host.frame = canvas.bounds
        canvas.addSubview(host)
        try self.render(view: canvas, scale: 2, path: path)
    }

    static func renderMemory(model: DashboardModel, path: String) throws {
        let previewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarMemoryPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: previewDirectory) }
        let isEmpty = ProcessInfo.processInfo.environment["TOKENBAR_DEMO_MEMORY_EMPTY"] == "1"
        let configurationService = CodexMemoryConfigurationService(
            configurationURL: previewDirectory.appendingPathComponent("config.toml"))
        if !isEmpty {
            try configurationService.install()
        }
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: previewDirectory),
            configurationService: configurationService,
            environment: [:],
            initialReceiverState: .listening(
                startedAt: Date().addingTimeInterval(-29 * 86_400)),
            initialConfigurationState: isEmpty ? .notConfigured : .configured)
        let usage = model.activitySnapshot?.memoryUsage
        let content = HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menu summary")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                MemorySummarySection(
                    usage: usage,
                    receiverState: telemetry.receiverState,
                    configurationState: telemetry.configurationState,
                    accentColor: .purple)
                    .frame(
                        width: 384,
                        height: MemorySummarySection.preferredHeight,
                        alignment: .top)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Detail submenu")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                MemoryDetailView(
                    model: model,
                    telemetry: telemetry,
                    accentColor: .purple)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
        .frame(width: 984, height: 582, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 984, height: 582)
        let canvas = DemoRowPreviewCanvas(frame: host.bounds)
        host.frame = canvas.bounds
        canvas.addSubview(host)
        try self.render(view: canvas, scale: 2, path: path)
    }

    static func renderRequestDetail(path: String) throws {
        let view = RequestDetailMenuView()
        view.show(
            prompt: """
            Build a compact menu bar dashboard.

            Preserve multiline prompts and code such as:
            let refreshInterval = Duration.seconds(300)
            """,
            output: (0 ..< 14)
                .map { "Result line \($0 + 1): request details remain readable and scrollable." }
                .joined(separator: "\n"))
        let canvas = DemoRowPreviewCanvas(frame: view.bounds)
        view.frame = canvas.bounds
        canvas.addSubview(view)
        try self.render(view: canvas, scale: 2, path: path)
    }

    static func renderSettings(path: String) throws {
        let activitySync = ActivitySyncController(
            settings: .shared,
            credentials: DemoActivitySyncCredentialStore())
        let content = TokenBarSettingsView(
            settings: .shared,
            activitySync: activitySync)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 820)
        let canvas = DemoRowPreviewCanvas(frame: host.bounds)
        host.frame = canvas.bounds
        canvas.addSubview(host)
        try self.render(view: canvas, scale: 2, path: path)
    }

    static func renderStatus(path: String) throws {
        let statusImage = StatusLabelRenderer.layout(
            codexToday: "359M",
            codexWeekly: "68%",
            claudeToday: "141K",
            claudeWeekly: "54%").image
        let padding: CGFloat = 4
        let canvas = DemoRowPreviewCanvas(frame: NSRect(
            x: 0,
            y: 0,
            width: statusImage.size.width + padding * 2,
            height: statusImage.size.height + padding * 2))
        let imageView = NSImageView(frame: NSRect(
            x: padding,
            y: padding,
            width: statusImage.size.width,
            height: statusImage.size.height))
        imageView.image = statusImage
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = .labelColor
        canvas.addSubview(imageView)
        canvas.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.bounds.width * 8),
            pixelsHigh: Int(canvas.bounds.height * 8),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return
        }
        representation.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func render(view: NSView, scale: CGFloat, path: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return
        }
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private final class DemoRowPreviewCanvas: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        self.bounds.fill()
    }
}

private struct DemoActivitySyncCredentialStore: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { "demo-token" }
    func saveToken(_: String?) throws {}
}

private extension Date {
    var demoClockText: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: self)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
#endif
