import Foundation
@testable import TokenBarCore
import Testing

@MainActor
struct TokenBarSettingsTests {
    @Test("Settings use product defaults in a new store")
    func defaults() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)

            #expect(settings.theme == .system)
            #expect(settings.recentSessionCount == .ten)
            #expect(settings.recentSessionLimit == 10)
            #expect(settings.refreshInterval == .fiveMinutes)
            #expect(settings.backgroundRefreshDuration == .seconds(5 * 60))
            #expect(settings.statisticsTimeZone == .utc)
            #expect(settings.showsFullRequestContentOnHover)
            #expect(settings.resetCelebration == .off)
        }
    }

    @Test("Settings changes persist for the next model instance")
    func persistence() {
        self.withDefaults { defaults, prefix in
            var settings: TokenBarSettings? = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings?.theme = .purple
            settings?.recentSessionCount = .five
            settings?.refreshInterval = .fifteenMinutes
            settings?.statisticsTimeZone = .local
            settings?.showsFullRequestContentOnHover = false
            settings?.resetCelebration = .both
            settings = nil

            let restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.theme == .purple)
            #expect(restored.recentSessionLimit == 5)
            #expect(restored.refreshInterval == .fifteenMinutes)
            #expect(restored.statisticsTimeZone == .local)
            #expect(!restored.showsFullRequestContentOnHover)
            #expect(restored.resetCelebration == .both)
        }
    }

    @Test("Unsupported stored values fall back safely")
    func invalidValues() {
        self.withDefaults { defaults, prefix in
            defaults.set("ultraviolet", forKey: "\(prefix).theme")
            defaults.set(7, forKey: "\(prefix).recentSessionCount")
            defaults.set(3, forKey: "\(prefix).refreshInterval")
            defaults.set("mars", forKey: "\(prefix).statisticsTimeZone")
            defaults.set("fireworks", forKey: "\(prefix).resetCelebration")

            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(settings.theme == .system)
            #expect(settings.recentSessionCount == .ten)
            #expect(settings.refreshInterval == .fiveMinutes)
            #expect(settings.statisticsTimeZone == .utc)
            #expect(settings.resetCelebration == .off)
        }
    }

    @Test("Restore defaults updates values and persistence")
    func reset() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings.theme = .pink
            settings.recentSessionCount = .five
            settings.refreshInterval = .oneMinute
            settings.statisticsTimeZone = .local
            settings.showsFullRequestContentOnHover = false
            settings.resetCelebration = .session

            settings.resetToDefaults()

            let restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.theme == .system)
            #expect(restored.recentSessionCount == .ten)
            #expect(restored.refreshInterval == .fiveMinutes)
            #expect(restored.statisticsTimeZone == .utc)
            #expect(restored.showsFullRequestContentOnHover)
            #expect(restored.resetCelebration == .off)
        }
    }

    private func withDefaults(
        _ body: (UserDefaults, String) throws -> Void) rethrows
    {
        let suiteName = "TokenBarSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, "test.settings")
    }
}
