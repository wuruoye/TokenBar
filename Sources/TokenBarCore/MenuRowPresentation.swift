import Foundation

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
    var menuCostText: String? {
        let isProviderReported = !self.requests.isEmpty
            && self.requests.allSatisfy { $0.costSource == .providerReported }
        if self.costUsd == 0, !isProviderReported {
            return nil
        }
        return self.costUsd.menuCostText(isEstimated: !isProviderReported)
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
