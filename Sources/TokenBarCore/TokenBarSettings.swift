import Foundation
import Observation

public enum TokenBarTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case blue
    case purple
    case green
    case orange
    case pink

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .blue: "Blue"
        case .purple: "Purple"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        }
    }
}

public enum TokenBarRecentSessionCount: Int, CaseIterable, Codable, Identifiable, Sendable {
    case five = 5
    case ten = 10

    public var id: Self { self }
}

public enum TokenBarRefreshInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15

    public var id: Self { self }
    public var duration: Duration { .seconds(self.rawValue * 60) }

    public var displayName: String {
        self.rawValue == 1 ? "1 minute" : "\(self.rawValue) minutes"
    }
}

public enum TokenBarResetCelebration: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case session
    case weekly
    case both

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .session: "5-hour resets"
        case .weekly: "Weekly resets"
        case .both: "5-hour and weekly resets"
        }
    }

    public func includes(_ window: QuotaResetWindow) -> Bool {
        switch (self, window) {
        case (.session, .session), (.weekly, .weekly), (.both, _):
            true
        default:
            false
        }
    }
}

public enum TokenBarStatisticsTimeZone: String, CaseIterable, Codable, Identifiable, Sendable {
    case utc
    case local

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .utc: "UTC (matches Codex)"
        case .local: "Local time"
        }
    }

    var processEnvironmentValue: String {
        switch self {
        case .utc: "UTC"
        case .local: TimeZone.autoupdatingCurrent.identifier
        }
    }
}

@MainActor
@Observable
public final class TokenBarSettings {
    public static let shared = TokenBarSettings()
    public static let defaultTheme = TokenBarTheme.system
    public static let defaultRecentSessionCount = TokenBarRecentSessionCount.ten
    public static let defaultRefreshInterval = TokenBarRefreshInterval.fiveMinutes
    public static let defaultStatisticsTimeZone = TokenBarStatisticsTimeZone.utc
    public static let defaultShowsClaude = true
    public static let defaultShowsGrok = true
    public static let defaultUsesWeekdayWeeklyPacing = false
    public static let defaultShowsFullRequestContentOnHover = true
    public static let defaultMonitorsCodexMemory = true
    public static let defaultResetCelebration = TokenBarResetCelebration.off
    public static let defaultSyncEnabled = false
    public static let defaultSyncServerURL = ""
    public static var defaultSyncDeviceName: String {
        let name = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }

    public var theme: TokenBarTheme {
        didSet { self.defaults.set(self.theme.rawValue, forKey: self.keys.theme) }
    }

    public var recentSessionCount: TokenBarRecentSessionCount {
        didSet { self.defaults.set(self.recentSessionCount.rawValue, forKey: self.keys.recentSessionCount) }
    }

    public var refreshInterval: TokenBarRefreshInterval {
        didSet { self.defaults.set(self.refreshInterval.rawValue, forKey: self.keys.refreshInterval) }
    }

    public var statisticsTimeZone: TokenBarStatisticsTimeZone {
        didSet {
            self.defaults.set(
                self.statisticsTimeZone.rawValue,
                forKey: self.keys.statisticsTimeZone)
        }
    }

    public var showsClaude: Bool {
        didSet {
            self.defaults.set(
                self.showsClaude,
                forKey: self.keys.showsClaude)
        }
    }

    public var showsGrok: Bool {
        didSet {
            self.defaults.set(
                self.showsGrok,
                forKey: self.keys.showsGrok)
        }
    }

    public var usesWeekdayWeeklyPacing: Bool {
        didSet {
            self.defaults.set(
                self.usesWeekdayWeeklyPacing,
                forKey: self.keys.usesWeekdayWeeklyPacing)
        }
    }

    public var showsFullRequestContentOnHover: Bool {
        didSet {
            self.defaults.set(
                self.showsFullRequestContentOnHover,
                forKey: self.keys.showsFullRequestContentOnHover)
        }
    }

    public var monitorsCodexMemory: Bool {
        didSet {
            self.defaults.set(
                self.monitorsCodexMemory,
                forKey: self.keys.monitorsCodexMemory)
        }
    }

    public var resetCelebration: TokenBarResetCelebration {
        didSet {
            self.defaults.set(
                self.resetCelebration.rawValue,
                forKey: self.keys.resetCelebration)
        }
    }

    public var syncEnabled: Bool {
        didSet { self.defaults.set(self.syncEnabled, forKey: self.keys.syncEnabled) }
    }

    public var syncServerURL: String {
        didSet { self.defaults.set(self.syncServerURL, forKey: self.keys.syncServerURL) }
    }

    public var syncDeviceName: String {
        didSet { self.defaults.set(self.syncDeviceName, forKey: self.keys.syncDeviceName) }
    }

    public private(set) var syncDeviceID: String

    public var recentSessionLimit: Int { self.recentSessionCount.rawValue }
    public var backgroundRefreshDuration: Duration { self.refreshInterval.duration }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: Keys

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "TokenBar.settings")
    {
        self.defaults = defaults
        self.keys = Keys(prefix: keyPrefix)
        self.theme = defaults.string(forKey: self.keys.theme)
            .flatMap(TokenBarTheme.init(rawValue:)) ?? Self.defaultTheme
        self.recentSessionCount = TokenBarRecentSessionCount(
            rawValue: defaults.integer(forKey: self.keys.recentSessionCount)) ?? Self.defaultRecentSessionCount
        self.refreshInterval = TokenBarRefreshInterval(
            rawValue: defaults.integer(forKey: self.keys.refreshInterval)) ?? Self.defaultRefreshInterval
        self.statisticsTimeZone = defaults.string(forKey: self.keys.statisticsTimeZone)
            .flatMap(TokenBarStatisticsTimeZone.init(rawValue:)) ?? Self.defaultStatisticsTimeZone
        self.showsClaude = defaults.object(
            forKey: self.keys.showsClaude) as? Bool
            ?? Self.defaultShowsClaude
        self.showsGrok = defaults.object(
            forKey: self.keys.showsGrok) as? Bool
            ?? Self.defaultShowsGrok
        self.usesWeekdayWeeklyPacing = defaults.object(
            forKey: self.keys.usesWeekdayWeeklyPacing) as? Bool
            ?? Self.defaultUsesWeekdayWeeklyPacing
        self.showsFullRequestContentOnHover = defaults.object(
            forKey: self.keys.showsFullRequestContentOnHover) as? Bool
            ?? Self.defaultShowsFullRequestContentOnHover
        self.monitorsCodexMemory = defaults.object(
            forKey: self.keys.monitorsCodexMemory) as? Bool
            ?? Self.defaultMonitorsCodexMemory
        self.resetCelebration = defaults.string(forKey: self.keys.resetCelebration)
            .flatMap(TokenBarResetCelebration.init(rawValue:)) ?? Self.defaultResetCelebration
        self.syncEnabled = defaults.object(forKey: self.keys.syncEnabled) as? Bool
            ?? Self.defaultSyncEnabled
        self.syncServerURL = defaults.string(forKey: self.keys.syncServerURL)
            ?? Self.defaultSyncServerURL
        self.syncDeviceName = defaults.string(forKey: self.keys.syncDeviceName)
            ?? Self.defaultSyncDeviceName
        let storedDeviceID = defaults.string(forKey: self.keys.syncDeviceID)
        self.syncDeviceID = storedDeviceID.flatMap { UUID(uuidString: $0) }?
            .uuidString.lowercased() ?? UUID().uuidString.lowercased()
        defaults.set(self.syncDeviceID, forKey: self.keys.syncDeviceID)
    }

    public func resetToDefaults() {
        self.theme = Self.defaultTheme
        self.recentSessionCount = Self.defaultRecentSessionCount
        self.refreshInterval = Self.defaultRefreshInterval
        self.statisticsTimeZone = Self.defaultStatisticsTimeZone
        self.showsClaude = Self.defaultShowsClaude
        self.showsGrok = Self.defaultShowsGrok
        self.usesWeekdayWeeklyPacing = Self.defaultUsesWeekdayWeeklyPacing
        self.showsFullRequestContentOnHover = Self.defaultShowsFullRequestContentOnHover
        self.monitorsCodexMemory = Self.defaultMonitorsCodexMemory
        self.resetCelebration = Self.defaultResetCelebration
        self.syncEnabled = Self.defaultSyncEnabled
        self.syncServerURL = Self.defaultSyncServerURL
        self.syncDeviceName = Self.defaultSyncDeviceName
    }

    private struct Keys {
        let theme: String
        let recentSessionCount: String
        let refreshInterval: String
        let statisticsTimeZone: String
        let showsClaude: String
        let showsGrok: String
        let usesWeekdayWeeklyPacing: String
        let showsFullRequestContentOnHover: String
        let monitorsCodexMemory: String
        let resetCelebration: String
        let syncEnabled: String
        let syncServerURL: String
        let syncDeviceName: String
        let syncDeviceID: String

        init(prefix: String) {
            self.theme = "\(prefix).theme"
            self.recentSessionCount = "\(prefix).recentSessionCount"
            self.refreshInterval = "\(prefix).refreshInterval"
            self.statisticsTimeZone = "\(prefix).statisticsTimeZone"
            self.showsClaude = "\(prefix).showsClaude"
            self.showsGrok = "\(prefix).showsGrok"
            self.usesWeekdayWeeklyPacing = "\(prefix).usesWeekdayWeeklyPacing"
            self.showsFullRequestContentOnHover = "\(prefix).showsFullRequestContentOnHover"
            self.monitorsCodexMemory = "\(prefix).monitorsCodexMemory"
            self.resetCelebration = "\(prefix).resetCelebration"
            self.syncEnabled = "\(prefix).syncEnabled"
            self.syncServerURL = "\(prefix).syncServerURL"
            self.syncDeviceName = "\(prefix).syncDeviceName"
            self.syncDeviceID = "\(prefix).syncDeviceID"
        }
    }
}
