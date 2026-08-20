import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

private struct RecentSessionTestCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
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
}
