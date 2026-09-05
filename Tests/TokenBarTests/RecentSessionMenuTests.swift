import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

private struct RecentSessionTestCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}

private actor HistoricalSessionActivityProvider: ActivityProviding {
    let snapshot: ActivitySnapshot
    let historicalSessions: [String: [SessionSummary]]
    private(set) var requestedDates: [String] = []

    init(snapshot: ActivitySnapshot, historicalSessions: [String: [SessionSummary]]) {
        self.snapshot = snapshot
        self.historicalSessions = historicalSessions
    }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.snapshot
    }

    func fetchSessions(
        on date: String,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
    {
        self.requestedDates.append(date)
        return self.historicalSessions[date] ?? []
    }
}

@MainActor
@Suite("Recent session menu")
struct RecentSessionMenuTests {
    @Test("switching platforms replaces an already-populated session submenu")
    func submenuFollowsPlatformSwitch() async throws {
        let suiteName = "RecentSessionMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")

        let model = DashboardModel(
            quotaService: DemoQuotaProvider(),
            additionalQuotaServices: [DemoClaudeQuotaProvider()],
            activityService: DemoActivityProvider(),
            cache: nil)
        await model.start()
        defer { model.stop() }

        let telemetryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentSessionMenuTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: telemetryDirectory) }
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: telemetryDirectory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: telemetryDirectory.appendingPathComponent("config.toml")))
        let activitySync = ActivitySyncController(
            settings: settings,
            credentials: RecentSessionTestCredentials())
        let controller = TokenBarStatusItemController(
            model: model,
            settings: settings,
            memoryTelemetry: telemetry,
            activitySync: activitySync,
            showSettings: {})
        defer { controller.tearDown() }

        let codexMenu = try #require(controller.firstSessionSubmenuForTesting())
        controller.menuNeedsUpdate(codexMenu)
        let codexSession = try #require(codexMenu.items.compactMap {
            $0.representedObject as? SessionSummary
        }.first)
        #expect(codexSession.platformID == .codex)

        controller.selectScopeForTesting(.claude)

        let claudeMenu = try #require(controller.firstSessionSubmenuForTesting())
        #expect(codexMenu !== claudeMenu)
        controller.menuNeedsUpdate(claudeMenu)
        let claudeSession = try #require(claudeMenu.items.compactMap {
            $0.representedObject as? SessionSummary
        }.first)
        #expect(claudeSession.platformID == .claude)
    }

    @Test("Activity Detail loads and renders the selected date's sessions")
    func loadsPreviousDate() async throws {
        let today = Self.session(id: "today", endedAtMs: 2_000)
        let yesterday = Self.session(id: "yesterday", endedAtMs: 1_000)
        let provider = HistoricalSessionActivityProvider(
            snapshot: ActivitySnapshot(
                schemaVersion: 11,
                generatedAtMs: 2_000,
                timezone: "UTC",
                today: .zero,
                sessions: [today],
                days: [
                    DailySummary(
                        date: "2026-09-01",
                        tokens: .zero,
                        costUsd: 0,
                        requestCount: 1,
                        sessionCount: 1),
                    DailySummary(
                        date: "2026-09-02",
                        tokens: .zero,
                        costUsd: 0,
                        requestCount: 1,
                        sessionCount: 1),
                ]),
            historicalSessions: ["2026-09-01": [yesterday]])
        let model = DashboardModel(
            quotaService: DemoQuotaProvider(),
            activityService: provider,
            cache: nil)
        await model.start()
        defer { model.stop() }

        let suiteName = "RecentSessionMenuTests.history.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        let telemetryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentSessionMenuHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: telemetryDirectory) }
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: telemetryDirectory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: telemetryDirectory.appendingPathComponent("config.toml")))
        let activitySync = ActivitySyncController(
            settings: settings,
            credentials: RecentSessionTestCredentials())
        let controller = TokenBarStatusItemController(
            model: model,
            settings: settings,
            memoryTelemetry: telemetry,
            activitySync: activitySync,
            showSettings: {})
        defer { controller.tearDown() }

        #expect(controller.selectedSessionDateForTesting() == "2026-09-02")
        controller.selectActivityDateForTesting("2026-09-01")
        while controller.isLoadingSessionHistoryForTesting() {
            await Task.yield()
        }

        #expect(controller.selectedSessionDateForTesting() == "2026-09-01")
        #expect(controller.renderedActivitySessionIDsForTesting() == ["codex:yesterday"])
        #expect(await provider.requestedDates == ["2026-09-01"])
        #expect(controller.firstSessionSubmenuForTesting()?.title == "today")
        let sessionMenu = try #require(controller.activitySessionMenuForTesting())
        #expect(sessionMenu.title == "Sessions · 2026-09-01")
        #expect(sessionMenu.items.compactMap {
            ($0.representedObject as? SessionSummary)?.id
        } == ["yesterday"])
        #expect(controller.activityDetailDirectSessionCountForTesting() == 0)
        #expect(controller.activityDetailShowsSessionMenuOnHoverForTesting())
        let historicalMenu = try #require(controller.firstActivitySessionSubmenuForTesting())
        #expect(historicalMenu.title == "yesterday")
        controller.menuNeedsUpdate(historicalMenu)
        #expect(historicalMenu.items.contains { $0.title == "Turns" })
    }

    private static func session(id: String, endedAtMs: Int64) -> SessionSummary {
        SessionSummary(
            id: id,
            workspaceLabel: "TokenBar",
            startedAtMs: endedAtMs - 100,
            endedAtMs: endedAtMs,
            tokens: .zero,
            costUsd: 0,
            models: ["gpt-test"],
            requests: [],
            title: id,
            platform: .codex)
    }
}
