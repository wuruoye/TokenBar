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

@MainActor
@Observable
public final class TokenBarSettings {
    public static let shared = TokenBarSettings()
    public static let defaultTheme = TokenBarTheme.system
    public static let defaultRecentSessionCount = TokenBarRecentSessionCount.ten
    public static let defaultRefreshInterval = TokenBarRefreshInterval.fiveMinutes
    public static let defaultShowsFullRequestContentOnHover = true

    public var theme: TokenBarTheme {
        didSet { self.defaults.set(self.theme.rawValue, forKey: self.keys.theme) }
    }

    public var recentSessionCount: TokenBarRecentSessionCount {
        didSet { self.defaults.set(self.recentSessionCount.rawValue, forKey: self.keys.recentSessionCount) }
    }

    public var refreshInterval: TokenBarRefreshInterval {
        didSet { self.defaults.set(self.refreshInterval.rawValue, forKey: self.keys.refreshInterval) }
    }

    public var showsFullRequestContentOnHover: Bool {
        didSet {
            self.defaults.set(
                self.showsFullRequestContentOnHover,
                forKey: self.keys.showsFullRequestContentOnHover)
        }
    }

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
        self.showsFullRequestContentOnHover = defaults.object(
            forKey: self.keys.showsFullRequestContentOnHover) as? Bool
            ?? Self.defaultShowsFullRequestContentOnHover
    }

    public func resetToDefaults() {
        self.theme = Self.defaultTheme
        self.recentSessionCount = Self.defaultRecentSessionCount
        self.refreshInterval = Self.defaultRefreshInterval
        self.showsFullRequestContentOnHover = Self.defaultShowsFullRequestContentOnHover
    }

    private struct Keys {
        let theme: String
        let recentSessionCount: String
        let refreshInterval: String
        let showsFullRequestContentOnHover: String

        init(prefix: String) {
            self.theme = "\(prefix).theme"
            self.recentSessionCount = "\(prefix).recentSessionCount"
            self.refreshInterval = "\(prefix).refreshInterval"
            self.showsFullRequestContentOnHover = "\(prefix).showsFullRequestContentOnHover"
        }
    }
}
