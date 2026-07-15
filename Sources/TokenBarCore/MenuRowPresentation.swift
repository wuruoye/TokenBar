import Foundation

public extension Int64 {
    var statusBarCompactCount: String {
        let magnitude = abs(Double(self))
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return self.formatted()
        }
        let value = String(
            format: "%.0f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(self) / divisor)
        return "\(value)\(suffix)"
    }
}

public extension TokenBreakdown {
    var sessionMenuDetail: String {
        self.compactMenuDetail
    }

    var requestMenuDetail: String {
        self.compactMenuDetail
    }

    var cacheReuseText: String {
        let paid = self.input.saturatingAddForPresentation(self.cacheWrite)
        if paid == 0 {
            return self.cacheRead > 0 ? "∞" : "—"
        }
        return String(
            format: "%.1fx",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(self.cacheRead) / Double(paid))
    }

    private var compactMenuDetail: String {
        "\(self.total.tokscaleCount) total · Cache× \(self.cacheReuseText)"
    }
}

public extension RequestSummary {
    var menuServiceTier: ActivityServiceTier {
        let physicalTier = ActivityServiceTier.combining(
            self.physicalRequests.map { $0.serviceTier ?? .unknown })
        return physicalTier == .unknown
            ? self.serviceTier ?? .unknown
            : physicalTier
    }

    var menuServiceTierBadge: String? {
        self.menuServiceTier.menuBadge
    }

    var menuRowTitle: String {
        let prompt = self.promptPreview?.compactMenuText
        guard self.isSubagent else {
            return prompt ?? self.menuTitle
        }

        let actor = self.agent?.compactMenuText ?? "Subagent"
        if let prompt {
            return "↳ \(actor) · \(prompt)"
        }
        if let output = self.outputPreview?.compactMenuText {
            return "↳ \(actor) · Output · \(output)"
        }
        return "↳ \(actor)"
    }

    var menuDurationText: String {
        guard let durationMs = self.durationMs, durationMs > 0 else { return "—" }
        let seconds = max(1, durationMs / 1000)
        guard seconds >= 60 else { return "\(seconds)s" }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return "\(minutes)m\(remainingSeconds)s"
    }

    var agentRequestMenuTitle: String {
        guard self.isSubagent else { return "Main" }
        return self.agent?.compactMenuText ?? "Subagent"
    }

    var menuCostText: String? {
        let isProviderReported = self.costSource == .providerReported
        if self.costUsd == 0, !isProviderReported {
            return nil
        }
        return self.costUsd.menuCostText(isEstimated: !isProviderReported)
    }
}

public extension SessionSummary {
    var menuServiceTier: ActivityServiceTier {
        ActivityServiceTier.combining(self.requests.map(\.menuServiceTier))
    }

    var menuServiceTierBadge: String? {
        self.menuServiceTier.menuBadge
    }

    var menuCostText: String? {
        let isProviderReported = !self.requests.isEmpty
            && self.requests.allSatisfy { $0.costSource == .providerReported }
        if self.costUsd == 0, !isProviderReported {
            return nil
        }
        return self.costUsd.menuCostText(isEstimated: !isProviderReported)
    }
}

private extension ActivityServiceTier {
    var menuBadge: String? {
        switch self {
        case .fast: "FAST"
        case .mixed: "MIXED"
        case .unknown, .standard: nil
        }
    }
}

private extension Int64 {
    var tokscaleCount: String {
        let magnitude = abs(Double(self))
        if magnitude >= 1_000_000_000 {
            return String(
                format: "%.1fB",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(self) / 1_000_000_000)
        }
        if magnitude >= 1_000_000 {
            return String(
                format: "%.1fM",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(self) / 1_000_000)
        }
        if magnitude >= 1_000 {
            return "\(self / 1_000)K"
        }
        return "\(self)"
    }

    func saturatingAddForPresentation(_ other: Int64) -> Int64 {
        let (value, overflow) = self.addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }
}

private extension String {
    var compactMenuText: String? {
        let normalized = self.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

private extension Double {
    func menuCostText(isEstimated: Bool) -> String? {
        guard self.isFinite, self >= 0 else { return nil }
        if self > 0, self < 0.01 {
            return "<$0.01"
        }

        let amount: String
        if self >= 1_000_000 {
            amount = String(
                format: "$%.1fM",
                locale: Locale(identifier: "en_US_POSIX"),
                self / 1_000_000)
        } else if self >= 1_000 {
            amount = String(
                format: "$%.1fK",
                locale: Locale(identifier: "en_US_POSIX"),
                self / 1_000)
        } else {
            amount = String(
                format: "$%.2f",
                locale: Locale(identifier: "en_US_POSIX"),
                self)
        }
        return isEstimated && self > 0 ? "~\(amount)" : amount
    }
}
