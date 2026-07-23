import Foundation
import Testing
@testable import TokenBarCore

private struct StubActivityHelperRunner: ActivityHelperRunning {
    let output: Data

    func run(
        executableURL _: URL,
        arguments _: [String],
        environment _: [String: String],
        timeout _: TimeInterval) async throws -> Data
    {
        self.output
    }
}

private actor RecordingActivityHelperRunner: ActivityHelperRunning {
    let output: Data
    private(set) var arguments: [String] = []
    private(set) var environments: [[String: String]] = []

    init(output: Data) {
        self.output = output
    }

    func run(
        executableURL _: URL,
        arguments: [String],
        environment: [String: String],
        timeout _: TimeInterval) async throws -> Data
    {
        self.arguments = arguments
        self.environments.append(environment)
        return self.output
    }
}

@Suite("ActivityService")
struct ActivityServiceTests {
    @Test("decodes helper JSON without launching a process")
    func decodesHelperJSON() async throws {
        let service = ActivityService(
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: StubActivityHelperRunner(output: Self.fixtureData))

        let snapshot = try await service.fetchActivity()

        #expect(snapshot.schemaVersion == 3)
        #expect(snapshot.today.tokens.total == 21)
        #expect(snapshot.today.tokenCosts?.input == 0.05)
        #expect(snapshot.today.tokenCosts?.cache == 0.05)
        #expect(abs((snapshot.today.tokenCosts?.total ?? 0) - 0.25) < 0.000_000_001)
        #expect(snapshot.weeklySinceReset?.totals.tokens.total == 84)
        #expect(snapshot.sessions.first?.requests.first?.model == "gpt-test")
        #expect(snapshot.sessions.first?.requests.first?.promptPreview == "private prompt")
        #expect(snapshot.sessions.first?.requests.first?.sessionPath == "/tmp/private-session.jsonl")
        #expect(snapshot.sessions.first?.requests.first?.serviceTier == .fast)
        #expect(snapshot.sessions.first?.requests.first?.physicalRequests.first?.physicalSessionId == "physical-1")
        #expect(snapshot.sessions.first?.requests.first?.physicalRequests.first?.serviceTier == .fast)
        #expect(snapshot.days.first?.models.first?.model == "gpt-test")
    }

    @Test("passes the exact weekly reset timestamp to the helper")
    func passesWeeklyResetTimestamp() async throws {
        let runner = RecordingActivityHelperRunner(output: Self.fixtureData)
        let service = ActivityService(
            arguments: ["--days", "30"],
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: runner)
        let reset = Date(timeIntervalSince1970: 1_720_000_000.125)

        _ = try await service.fetchActivity(sinceWeeklyResetAt: reset)

        #expect(await runner.arguments == ["--days", "30", "--weekly-reset-ms", "1720000000125"])
        #expect(await runner.environments.last?["TZ"] == "UTC")
    }

    @Test("uses the selected statistics timezone for the helper")
    func passesStatisticsTimeZone() async throws {
        let runner = RecordingActivityHelperRunner(output: Self.fixtureData)
        let service = ActivityService(
            environment: ["PRESERVED": "yes", "TZ": "Old"],
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: runner)

        _ = try await service.fetchActivity(
            sinceWeeklyResetAt: nil,
            statisticsTimeZone: .local)

        #expect(await runner.environments.last?["PRESERVED"] == "yes")
        #expect(await runner.environments.last?["TZ"] == TimeZone.autoupdatingCurrent.identifier)
    }

    @Test("rejects malformed helper JSON")
    func rejectsMalformedJSON() async {
        let service = ActivityService(
            resolveHelper: { URL(fileURLWithPath: "/fixture/tokenbar-helper") },
            runner: StubActivityHelperRunner(output: Data("not-json".utf8)))

        await #expect(throws: ActivityServiceError.self) {
            _ = try await service.fetchActivity()
        }
    }

    @Test("decodes cached daily summaries created before model breakdowns")
    func decodesLegacyDailySummary() throws {
        let data = Data(
            #"{"date":"2026-07-13","tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5},"costUsd":0.1,"requestCount":1,"sessionCount":1}"#.utf8)

        let day = try JSONDecoder().decode(DailySummary.self, from: data)

        #expect(day.models.isEmpty)
        #expect(day.tokens.total == 15)
    }

    @Test("decodes legacy activity snapshots without weekly reset totals")
    func decodesLegacyActivitySnapshot() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "generatedAtMs": 1720000000000,
              "timezone": "UTC",
              "today": {
                "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0},
                "costUsd": 0,
                "requestCount": 0,
                "sessionCount": 0
              },
              "sessions": [],
              "days": []
            }
            """.utf8)

        let snapshot = try JSONDecoder().decode(ActivitySnapshot.self, from: data)

        #expect(snapshot.weeklySinceReset == nil)
        #expect(snapshot.today.tokenCosts == nil)
    }

    @Test("decodes legacy requests without turn contributions")
    func decodesLegacyRequestWithoutContributions() throws {
        let data = Data(
            """
            {
              "id": "legacy-request",
              "sessionId": "root-session",
              "physicalSessionId": "physical-session",
              "isSubagent": false,
              "agent": null,
              "model": "gpt-test",
              "provider": "openai",
              "startedAtMs": 1000,
              "endedAtMs": 2000,
              "durationMs": 1000,
              "tokens": {"input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4, "reasoning": 5},
              "costUsd": 0.1,
              "costSource": "estimated",
              "promptPreview": "prompt",
              "outputPreview": "output",
              "sessionPath": "/tmp/session.jsonl"
            }
            """.utf8)

        let request = try JSONDecoder().decode(RequestSummary.self, from: data)

        #expect(request.contributions == nil)
        #expect(request.serviceTier == nil)
        #expect(request.physicalRequests.map(\.id) == ["legacy-request"])
    }

    private static let fixtureData = Data(
        """
        {
          "schemaVersion": 3,
          "generatedAtMs": 1720000000000,
          "timezone": "UTC",
          "today": {
            "tokens": {"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2, "reasoning": 1},
            "costUsd": 0.25,
            "tokenCosts": {"input": 0.05, "output": 0.10, "cacheRead": 0.03, "cacheWrite": 0.02, "reasoning": 0.05},
            "requestCount": 1,
            "sessionCount": 1
          },
          "weeklySinceReset": {
            "startedAtMs": 1719700000000,
            "totals": {
              "tokens": {"input": 40, "output": 20, "cacheRead": 12, "cacheWrite": 8, "reasoning": 4},
              "costUsd": 1.0,
              "tokenCosts": {"input": 0.20, "output": 0.40, "cacheRead": 0.12, "cacheWrite": 0.08, "reasoning": 0.20},
              "requestCount": 4,
              "sessionCount": 2
            }
          },
          "sessions": [{
            "id": "session-1",
            "workspaceLabel": "workspace",
            "startedAtMs": 1720000000000,
            "endedAtMs": 1720000001000,
            "tokens": {"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2, "reasoning": 1},
            "costUsd": 0.25,
            "models": ["gpt-test"],
            "requests": [{
              "id": "request-1",
              "sessionId": "session-1",
              "physicalSessionId": "physical-1",
              "isSubagent": false,
              "agent": "codex",
              "model": "gpt-test",
              "provider": "openai",
              "startedAtMs": 1720000000000,
              "endedAtMs": 1720000001000,
              "durationMs": 1000,
              "tokens": {"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2, "reasoning": 1},
              "costUsd": 0.25,
              "costSource": "estimated",
              "promptPreview": "private prompt",
              "outputPreview": "private output",
              "sessionPath": "/tmp/private-session.jsonl",
              "serviceTier": "fast",
              "contributions": [{
                "id": "physical-request-1",
                "sessionId": "session-1",
                "physicalSessionId": "physical-1",
                "isSubagent": false,
                "agent": "codex",
                "model": "gpt-test",
                "provider": "openai",
                "startedAtMs": 1720000000000,
                "endedAtMs": 1720000001000,
                "durationMs": 1000,
                "tokens": {"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2, "reasoning": 1},
                "costUsd": 0.25,
                "costSource": "estimated",
                "promptPreview": "private prompt",
                "outputPreview": "private output",
                "sessionPath": "/tmp/private-session.jsonl",
                "serviceTier": "fast"
              }]
            }]
          }],
          "days": [{
            "date": "2024-07-03",
            "tokens": {"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2, "reasoning": 1},
            "costUsd": 0.25,
            "requestCount": 1,
            "sessionCount": 1,
            "models": [{
              "model": "gpt-test",
              "provider": "openai",
              "tokens": {"input": 10, "output": 5, "cacheRead": 3, "cacheWrite": 2, "reasoning": 1},
              "costUsd": 0.25,
              "requestCount": 1,
              "sessionCount": 1
            }]
          }]
        }
        """.utf8)
}
