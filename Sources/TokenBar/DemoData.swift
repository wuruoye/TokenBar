#if DEBUG
import AppKit
import Foundation
import SwiftUI
import TokenBarCore

struct DemoQuotaProvider: QuotaProviding {
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

struct DemoActivityProvider: ActivityProviding {
    func fetchActivity(
        sinceWeeklyResetAt: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
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
        var requestCount = 0
        for (sessionIndex, prompt) in prompts.enumerated() {
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
                requestCount += 1
                let startedAtMs = nowMs
                    - Int64(sessionIndex * 29 * 60 * 1000)
                    - Int64((2 - requestIndex) * 4 * 60 * 1000)
                let requestPrompt = requestIndex == 0
                    ? prompt
                    : ["Continue with the implementation", "Run focused validation"][requestIndex - 1]
                let serviceTier = sessionIndex.isMultiple(of: 3) ? "fast" : "standard"
                var request: [String: Any] = [
                    "id": "request-\(sessionIndex)-\(requestIndex)",
                    "sessionId": "session-\(sessionIndex)",
                    "physicalSessionId": "physical-\(sessionIndex)",
                    "isSubagent": false,
                    "agent": "codex",
                    "model": "gpt-5",
                    "provider": "openai",
                    "startedAtMs": startedAtMs,
                    "endedAtMs": startedAtMs + 82_000,
                    "durationMs": 82_000,
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
                            "sessionId": "session-\(sessionIndex)",
                            "physicalSessionId": "physical-\(sessionIndex)",
                            "isSubagent": false,
                            "agent": "codex",
                            "model": "gpt-5",
                            "provider": "openai",
                            "startedAtMs": startedAtMs,
                            "endedAtMs": startedAtMs + 48_000,
                            "durationMs": 48_000,
                            "tokens": mainTokens.object,
                            "costUsd": Double(mainTokens.total) / 1_000_000 * 4.2,
                            "costSource": "estimated",
                            "serviceTier": serviceTier,
                            "promptPreview": requestPrompt,
                            "outputPreview": "Coordinated the implementation and integrated the result.",
                        ],
                        [
                            "id": "child-\(sessionIndex)-\(requestIndex)",
                            "sessionId": "session-\(sessionIndex)",
                            "physicalSessionId": "child-\(sessionIndex)",
                            "isSubagent": true,
                            "agent": "reviewer",
                            "model": "gpt-5",
                            "provider": "openai",
                            "startedAtMs": startedAtMs + 16_000,
                            "endedAtMs": startedAtMs + 82_000,
                            "durationMs": 66_000,
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

            sessions.append([
                "id": "session-\(sessionIndex)",
                "workspaceLabel": sessionIndex.isMultiple(of: 2) ? "TokenBar" : "CodexBar",
                "startedAtMs": nowMs - Int64((sessionIndex * 29 + 12) * 60 * 1000),
                "endedAtMs": nowMs - Int64(sessionIndex * 29 * 60 * 1000),
                "tokens": sessionTokens.object,
                "costUsd": Double(sessionTokens.total) / 1_000_000 * 4.2,
                "models": ["gpt-5"],
                "requests": Array(requests.reversed()),
            ])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar(identifier: .gregorian)
        var days: [[String: Any]] = []
        var weekly = DemoTokenCounter()
        var weeklyRequestCount = 0
        var weeklySessionCount = 0
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
            let dayRequestCount = 12 + Int(wave)
            let daySessionCount = 4 + Int(wave % 3)
            if let sinceWeeklyResetAt, date >= sinceWeeklyResetAt {
                weekly.add(tokens)
                weeklyRequestCount += dayRequestCount
                weeklySessionCount += daySessionCount
            }
            days.append([
                "date": formatter.string(from: date),
                "tokens": tokens.object,
                "costUsd": dayCost,
                "requestCount": dayRequestCount,
                "sessionCount": daySessionCount,
                "models": [
                    [
                        "model": "gpt-5",
                        "provider": "openai",
                        "tokens": primaryModel.object,
                        "costUsd": dayCost * Double(primaryModel.total) / Double(max(1, tokens.total)),
                        "requestCount": 8 + Int(wave / 2),
                        "sessionCount": 3 + Int(wave % 2),
                    ],
                    [
                        "model": "gpt-5-mini",
                        "provider": "openai",
                        "tokens": secondaryModel.object,
                        "costUsd": dayCost * Double(secondaryModel.total) / Double(max(1, tokens.total)),
                        "requestCount": 4 + Int(wave - wave / 2),
                        "sessionCount": 1 + Int(wave % 2),
                    ],
                ],
            ])
        }

        var object: [String: Any] = [
            "schemaVersion": 3,
            "generatedAtMs": nowMs,
            "timezone": TimeZone.current.identifier,
            "today": [
                "tokens": today.object,
                "costUsd": Double(today.total) / 1_000_000 * 4.2,
                "tokenCosts": today.costObject,
                "requestCount": requestCount,
                "sessionCount": sessions.count,
            ],
            "sessions": sessions,
            "days": days,
        ]
        if let sinceWeeklyResetAt {
            object["weeklySinceReset"] = [
                "startedAtMs": Int64(sinceWeeklyResetAt.timeIntervalSince1970 * 1000),
                "totals": [
                    "tokens": weekly.object,
                    "costUsd": Double(weekly.total) / 1_000_000 * 4.2,
                    "tokenCosts": weekly.costObject,
                    "requestCount": weeklyRequestCount,
                    "sessionCount": weeklySessionCount,
                ],
            ]
        }
        return try JSONDecoder().decode(ActivitySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
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

@MainActor
enum DemoPreviewRenderer {
    static func render(model: DashboardModel, path: String) throws {
        let showsFiveHour = model.quotaSnapshot?.session != nil
        let showsResetCredits = model.quotaSnapshot?.resetCredits != nil
        let height = DashboardSummaryView.preferredHeight(
            showsFiveHour: showsFiveHour,
            showsResetCredits: showsResetCredits)
        let content = DashboardSummaryView(
            model: model,
            showsFiveHour: showsFiveHour,
            showsResetCredits: showsResetCredits,
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
            title: session.menuTitle,
            cost: session.menuCostText,
            detail: session.tokens.sessionMenuDetail,
            trailing: Date(timeIntervalSince1970: Double(session.endedAtMs) / 1000).demoClockText,
            showsChevron: true,
            badge: session.menuServiceTierBadge)

        let requestRow = TokenMenuRowView(width: width)
        requestRow.configure(
            title: request.menuRowTitle,
            cost: request.menuCostText,
            detail: request.tokens.requestMenuDetail,
            trailing: "\(request.startedAt.demoClockText) · \(request.menuDurationText)",
            showsChevron: true,
            badge: request.menuServiceTierBadge)

        var rows = [sessionRow, requestRow]
        rows.append(contentsOf: physicalRequests.map { physicalRequest in
            let row = TokenMenuRowView(width: width)
            row.configure(
                title: physicalRequest.agentRequestMenuTitle,
                cost: physicalRequest.menuCostText,
                detail: physicalRequest.tokens.requestMenuDetail,
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
        let content = ActivityDetailView(model: model, accentColor: .purple)
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
        let content = TokenBarSettingsView(settings: .shared)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 390)
        let canvas = DemoRowPreviewCanvas(frame: host.bounds)
        host.frame = canvas.bounds
        canvas.addSubview(host)
        try self.render(view: canvas, scale: 2, path: path)
    }

    static func renderStatus(path: String) throws {
        let statusImage = StatusLabelRenderer.image(today: "359M", weekly: "68%")
        let padding: CGFloat = 4
        let canvas = DemoRowPreviewCanvas(frame: NSRect(
            x: 0,
            y: 0,
            width: statusImage.size.width + padding * 2,
            height: statusImage.size.height + padding * 2))
        let imageView = NSImageView(frame: canvas.bounds.insetBy(dx: padding, dy: padding))
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

private extension Date {
    var demoClockText: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: self)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
#endif
