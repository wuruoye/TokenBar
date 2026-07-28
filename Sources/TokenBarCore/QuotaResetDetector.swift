import Foundation

public enum QuotaResetWindow: String, Codable, Equatable, Sendable {
    case session
    case weekly
}

public struct QuotaResetEvent: Equatable, Sendable {
    public let platform: TokenPlatform
    public let window: QuotaResetWindow
    public let detectedAt: Date
    public let previousResetAt: Date
    public let resetAt: Date

    public init(
        platform: TokenPlatform,
        window: QuotaResetWindow,
        detectedAt: Date,
        previousResetAt: Date,
        resetAt: Date)
    {
        self.platform = platform
        self.window = window
        self.detectedAt = detectedAt
        self.previousResetAt = previousResetAt
        self.resetAt = resetAt
    }
}

public struct QuotaResetDetector: Sendable {
    public static let resetUsageThreshold = 1.0
    public static let resetBoundaryTolerance: TimeInterval = 2 * 60

    private struct Key: Hashable, Sendable {
        let platform: TokenPlatform
        let window: QuotaResetWindow
    }

    private struct State: Sendable {
        let wasAboveThreshold: Bool
        let lastObservedAt: Date
        let resetBoundary: Date?
    }

    private var states: [Key: State] = [:]

    public init() {}

    public mutating func observe(
        _ snapshot: QuotaSnapshot,
        for platform: TokenPlatform) -> [QuotaResetEvent]
    {
        var events: [QuotaResetEvent] = []
        if let event = self.observe(
            snapshot.session,
            snapshotUpdatedAt: snapshot.updatedAt,
            platform: platform,
            window: .session)
        {
            events.append(event)
        }
        if let event = self.observe(
            snapshot.weekly,
            snapshotUpdatedAt: snapshot.updatedAt,
            platform: platform,
            window: .weekly)
        {
            events.append(event)
        }
        return events
    }

    public mutating func reset(for platform: TokenPlatform) {
        self.states = self.states.filter { $0.key.platform != platform }
    }

    private mutating func observe(
        _ snapshot: QuotaWindowSnapshot?,
        snapshotUpdatedAt: Date,
        platform: TokenPlatform,
        window: QuotaResetWindow) -> QuotaResetEvent?
    {
        guard let snapshot,
              snapshot.usedPercent.isFinite,
              snapshotUpdatedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }

        let key = Key(platform: platform, window: window)
        let previous = self.states[key]
        if let previous, snapshotUpdatedAt <= previous.lastObservedAt {
            return nil
        }

        let usedPercent = min(max(snapshot.usedPercent, 0), 100)
        let isAboveThreshold = usedPercent > Self.resetUsageThreshold
        let advancedBoundary = Self.advancedBoundary(
            from: previous?.resetBoundary,
            to: snapshot.resetsAt)
        let crossedBelowThreshold = previous?.wasAboveThreshold == true && !isAboveThreshold
        let shouldEmit = crossedBelowThreshold && advancedBoundary != nil

        // A transient zero with the same (or a regressed) reset boundary must not
        // erase the high-usage baseline needed to recognize the genuine reset.
        let shouldPreserveBaseline = crossedBelowThreshold && advancedBoundary == nil
        let resetBoundary = Self.preferredBoundary(
            previous: previous?.resetBoundary,
            current: snapshot.resetsAt)
        self.states[key] = State(
            wasAboveThreshold: shouldPreserveBaseline ? true : isAboveThreshold,
            lastObservedAt: snapshotUpdatedAt,
            resetBoundary: resetBoundary)

        guard let (previousResetAt, resetAt) = advancedBoundary, shouldEmit else {
            return nil
        }
        return QuotaResetEvent(
            platform: platform,
            window: window,
            detectedAt: snapshotUpdatedAt,
            previousResetAt: previousResetAt,
            resetAt: resetAt)
    }

    private static func advancedBoundary(
        from previous: Date?,
        to current: Date?) -> (Date, Date)?
    {
        guard let previous,
              let current,
              previous.timeIntervalSinceReferenceDate.isFinite,
              current.timeIntervalSinceReferenceDate.isFinite,
              current.timeIntervalSince(previous) >= Self.resetBoundaryTolerance
        else {
            return nil
        }
        return (previous, current)
    }

    private static func preferredBoundary(previous: Date?, current: Date?) -> Date? {
        guard let current,
              current.timeIntervalSinceReferenceDate.isFinite
        else {
            return previous
        }
        guard let previous,
              previous.timeIntervalSinceReferenceDate.isFinite
        else {
            return current
        }
        return current.timeIntervalSince(previous) >= Self.resetBoundaryTolerance
            ? current
            : previous
    }
}
