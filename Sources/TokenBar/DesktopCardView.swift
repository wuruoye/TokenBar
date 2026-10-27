import AppKit
import SwiftUI
import TokenBarCore
import TokenBarWidgetData

/// The desktop card's content: unread tasks with their replies, then running
/// tasks. While anything is unread the card and its count breathe with a red
/// glow, and each running task spins.
struct DesktopCardView: View {
    enum DragPhase {
        case changed
        case ended
    }

    static let width: CGFloat = 340
    /// Room around the card for the glow, which a window would otherwise clip.
    static let glowRoom: CGFloat = 22
    private static let cornerRadius: CGFloat = 22
    /// A card that sizes itself to its rows stops growing here.
    private static let maximumUnreadRows = 5
    private static let maximumRunningRows = 5

    let state: DesktopCardState
    let open: (String, String) -> Void
    let drag: (DragPhase) -> Void
    let resize: (DragPhase) -> Void
    let resetSize: () -> Void
    let hide: () -> Void
    @State private var isHovered = false

    var body: some View {
        let snapshot = self.state.snapshot
        let hasUnread = !snapshot.tasks.isEmpty
        let size = self.state.cardSize
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(snapshot: snapshot, animates: self.state.isVisible)
            if size == nil {
                self.rows(snapshot, isLimited: true)
            } else {
                // A card the user sized keeps its size and scrolls what does not fit.
                ScrollView(.vertical) {
                    self.rows(snapshot, isLimited: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(self.isHovered ? .automatic : .hidden)
            }
        }
        .padding(16)
        .frame(
            width: size?.width ?? Self.width,
            height: size?.height,
            alignment: .topLeading)
        .background {
            // Opaque like a full-color desktop widget, with its soft shadow.
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            ZStack {
                // `BreathingGlow` draws the drop shadow once in Core Animation;
                // a SwiftUI shadow would be re-rendered with every redraw.
                shape.fill(Color(nsColor: .windowBackgroundColor))
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .overlay {
            BreathingGlow(
                cornerRadius: Self.cornerRadius,
                inset: Self.glowRoom,
                isActive: hasUnread,
                animates: self.state.isVisible)
                .padding(-Self.glowRoom)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(resize: self.resize)
                .opacity(self.isHovered ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onHover { self.isHovered = $0 }
        .animation(.easeOut(duration: 0.2), value: self.isHovered)
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in self.drag(.changed) }
                .onEnded { _ in self.drag(.ended) })
        .contextMenu {
            if size != nil {
                Button("Reset Size", action: self.resetSize)
            }
            Button("Hide Desktop Card", action: self.hide)
        }
        .padding(Self.glowRoom)
        // The window keeps its size while rows animate away, so the card holds
        // the edge it is anchored to.
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: self.state.anchorsBottom ? .bottomLeading : .topLeading)
    }

    private static let rowTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .move(edge: .top)),
        removal: .opacity)

    @ViewBuilder
    private func rows(_ snapshot: UnreadWidgetSnapshot, isLimited: Bool) -> some View {
        let unreadRows = isLimited ? Array(snapshot.tasks.prefix(Self.maximumUnreadRows)) : snapshot.tasks
        let runningRows = isLimited ? Array(snapshot.running.prefix(Self.maximumRunningRows)) : snapshot.running
        VStack(alignment: .leading, spacing: 10) {
            if unreadRows.isEmpty {
                HStack(spacing: CardGrid.spacing) {
                    Image(systemName: "checkmark.circle")
                        .frame(width: CardGrid.iconColumn)
                    Text("All caught up")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(unreadRows.enumerated()), id: \.element.id) { index, task in
                        VStack(spacing: 0) {
                            if index > 0 {
                                Divider().padding(.leading, CardGrid.textInset)
                            }
                            UnreadCardRow(task: task) {
                                self.open(task.platform, task.taskID)
                            }
                        }
                        .transition(Self.rowTransition)
                    }
                }
                if snapshot.tasks.count > unreadRows.count {
                    Text("+\(snapshot.tasks.count - unreadRows.count) more unread")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, CardGrid.textInset)
                }
            }
            if !runningRows.isEmpty {
                Divider()
                Text(snapshot.running.count > runningRows.count
                    ? "Running · \(snapshot.running.count)"
                    : "Running")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, CardGrid.textInset)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(runningRows) { task in
                        RunningCardRow(task: task, animates: self.state.isVisible) {
                            self.open(task.platform, task.taskID)
                        }
                        .transition(Self.rowTransition)
                    }
                }
            }
        }
    }
}

/// Drags the card's bottom-right corner to resize it.
private struct ResizeGrip: View {
    let resize: (DesktopCardView.DragPhase) -> Void

    var body: some View {
        Canvas { context, size in
            for offset in [4.0, 8.0, 12.0] {
                var line = Path()
                line.move(to: CGPoint(x: size.width - offset, y: size.height - 2))
                line.addLine(to: CGPoint(x: size.width - 2, y: size.height - offset))
                context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .frame(width: 18, height: 18)
        .padding(5)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in self.resize(.changed) }
                .onEnded { _ in self.resize(.ended) })
        .help("Drag to resize")
    }
}

/// Every row puts its badge, icon, or ring in one column and starts its text
/// at the same edge after it.
private enum CardGrid {
    static let iconColumn: CGFloat = 26
    static let spacing: CGFloat = 9
    static var textInset: CGFloat {
        self.iconColumn + self.spacing
    }

    /// Room a hover highlight extends past the rows without moving them.
    static let highlightOutset: CGFloat = 6
}

/// A highlight behind a hovered row that reaches past the row's edges, so the
/// row's contents stay on the card's grid.
private struct RowHighlight: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, CardGrid.highlightOutset)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(self.isHovered ? 0.06 : 0)))
            .padding(.horizontal, -CardGrid.highlightOutset)
            .contentShape(Rectangle())
    }
}

private struct CardHeader: View {
    let snapshot: UnreadWidgetSnapshot
    let animates: Bool

    var body: some View {
        HStack(alignment: .center, spacing: CardGrid.spacing) {
            BreathingBadge(count: self.snapshot.unreadCount, animates: self.animates)
            Text("Unread")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(self.snapshot.unreadCount > 0 ? .primary : .secondary)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                ForEach(self.snapshot.platforms) { platform in
                    HStack(spacing: 3) {
                        CardPlatformIcon(platform: platform.id, size: 12)
                        Text("\(platform.unreadCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(platform.unreadCount > 0 ? .primary : .secondary)
                    }
                }
            }
        }
    }
}

/// The title and when the reply came, then the reply itself, then what the
/// user asked with the project and how long the turn ran.
private struct UnreadCardRow: View {
    let task: UnreadWidgetSnapshot.Item
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(alignment: .top, spacing: CardGrid.spacing) {
                CardPlatformIcon(platform: self.task.platform, size: 14)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(CardAccent.unread)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -3)
                    }
                    .padding(.top, 2)
                    .frame(width: CardGrid.iconColumn)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(self.task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        CardTimeText(date: self.task.updatedAt)
                    }
                    if let reply = self.task.reply {
                        Text(reply)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    self.details
                }
            }
            .padding(.vertical, 8)
            .modifier(RowHighlight(isHovered: self.isHovered))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: self.isHovered)
    }

    @ViewBuilder
    private var details: some View {
        let duration = self.task.turnDuration.flatMap { $0 >= 1 ? UnreadTaskFormat.duration($0) : nil }
        if self.task.distinctPrompt != nil || self.task.workspaceName != nil || duration != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let prompt = self.task.distinctPrompt {
                    Label(prompt, systemImage: "person.fill")
                        .labelStyle(CompactLabelStyle())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let workspace = self.task.workspaceName {
                    Text(workspace)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .fixedSize(horizontal: self.task.distinctPrompt == nil, vertical: false)
                }
                if let duration {
                    Label(duration, systemImage: "timer")
                        .labelStyle(CompactLabelStyle())
                        .fixedSize()
                }
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

private struct RunningCardRow: View {
    let task: UnreadWidgetSnapshot.RunningItem
    let animates: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: CardGrid.spacing) {
                ZStack {
                    SpinningRing(tint: CardAccent.tint(for: self.task.platform), animates: self.animates)
                        .frame(width: 20, height: 20)
                    CardPlatformIcon(platform: self.task.platform, size: 10)
                }
                .frame(width: CardGrid.iconColumn)
                Text(self.task.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let startedAt = self.task.startedAt {
                    ElapsedMinutesText(since: startedAt)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .modifier(RowHighlight(isHovered: self.isHovered))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: self.isHovered)
    }
}

/// Elapsed time in whole minutes, such as `now`, `12m`, or `1h 5m`. Redrawing
/// the card once a minute instead of every second keeps it nearly idle.
private struct ElapsedMinutesText: View {
    let since: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            // The schedule's date is the start of the minute, which can trail now.
            let minutes = max(0, Int(max(context.date, Date()).timeIntervalSince(self.since) / 60))
            Text(minutes == 0 ? "now" : UnreadTaskFormat.duration(TimeInterval(minutes * 60)))
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// When the reply arrived: `now`, `5m ago`, `3h ago`, or a date before that.
private struct CardTimeText: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.everyMinute) { context in
                let minutes = Int(max(context.date, Date()).timeIntervalSince(date) / 60)
                Group {
                    if minutes < 1 {
                        Text("now")
                    } else if minutes < 60 {
                        Text("\(minutes)m ago")
                    } else if minutes < 24 * 60 {
                        Text("\(minutes / 60)h ago")
                    } else {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
        }
    }
}

// MARK: Animation

/// Core Animation runs these loops in the window server, so an always-on card
/// costs TokenBar no redraws. Each loop stops while the card is hidden.
private struct BreathingBadge: View {
    let count: Int
    let animates: Bool

    var body: some View {
        let isUnread = self.count > 0
        Text(self.count > 99 ? "99+" : "\(self.count)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(self.count)))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(isUnread ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 26, height: 26)
            .background {
                if isUnread {
                    ZStack {
                        PulseRings(color: NSColor(CardAccent.unread), animates: self.animates)
                            .frame(width: 26, height: 26)
                        Circle().fill(CardAccent.unread)
                    }
                }
            }
    }
}

/// A faint ring that slowly expands out of the badge and fades away.
private struct PulseRings: NSViewRepresentable {
    let color: NSColor
    let animates: Bool

    func makeNSView(context: Context) -> PulseRingsView {
        PulseRingsView()
    }

    func updateNSView(_ view: PulseRingsView, context: Context) {
        view.color = self.color
        view.animates = self.animates
    }
}

private final class PulseRingsView: NSView {
    private static let period: CFTimeInterval = 3.2
    private let rings = [CAShapeLayer()]

    var color = NSColor.systemRed {
        didSet { self.needsLayout = true }
    }

    var animates = false {
        didSet {
            guard self.animates != oldValue else { return }
            self.needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        for ring in self.rings {
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.opacity = 0
            self.layer?.addSublayer(ring)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        for (index, ring) in self.rings.enumerated() {
            ring.frame = self.bounds
            ring.path = CGPath(ellipseIn: self.bounds, transform: nil)
            ring.strokeColor = self.color.cgColor
            guard self.animates else {
                ring.removeAllAnimations()
                continue
            }
            guard ring.animation(forKey: "pulse") == nil else { continue }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.45
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35
            fade.toValue = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = Self.period
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulse.beginTime = CACurrentMediaTime() + Self.period / 2 * Double(index)
            ring.add(pulse, forKey: "pulse")
        }
    }
}

/// The card's soft drop shadow, plus a red border and glow that breathe while
/// anything is unread. The view is larger than the card by `inset` on every
/// side, so neither is clipped.
private struct BreathingGlow: NSViewRepresentable {
    let cornerRadius: CGFloat
    let inset: CGFloat
    let isActive: Bool
    let animates: Bool

    func makeNSView(context: Context) -> BreathingGlowView {
        BreathingGlowView()
    }

    func updateNSView(_ view: BreathingGlowView, context: Context) {
        view.cornerRadius = self.cornerRadius
        view.inset = self.inset
        view.isActive = self.isActive
        view.animates = self.animates
        view.needsLayout = true
    }
}

private final class BreathingGlowView: NSView {
    private static let period: CFTimeInterval = 3
    private let dropShadow = CAShapeLayer()
    private let dropShadowMask = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let border = CAShapeLayer()

    var cornerRadius: CGFloat = 18
    var inset: CGFloat = 22
    var isActive = false
    var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        // Both shadows come from the card's shape and are masked to the outside
        // of the card, so they never tint its contents.
        self.dropShadow.shadowColor = NSColor.black.cgColor
        self.dropShadow.shadowOpacity = 0.18
        self.dropShadow.shadowRadius = 10
        self.dropShadow.shadowOffset = CGSize(width: 0, height: -4)
        self.glow.shadowOffset = .zero
        self.glow.shadowRadius = 8
        for mask in [self.dropShadowMask, self.glowMask] {
            mask.fillRule = .evenOdd
            mask.fillColor = NSColor.black.cgColor
        }
        self.dropShadow.mask = self.dropShadowMask
        self.glow.mask = self.glowMask
        self.border.fillColor = nil
        self.border.lineWidth = 1
        self.layer?.addSublayer(self.dropShadow)
        self.layer?.addSublayer(self.glow)
        self.layer?.addSublayer(self.border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let card = self.bounds.insetBy(dx: self.inset, dy: self.inset)
        let path = CGPath(
            roundedRect: card,
            cornerWidth: self.cornerRadius,
            cornerHeight: self.cornerRadius,
            transform: nil)
        let red = NSColor(CardAccent.unread).cgColor
        let outside = CGMutablePath()
        outside.addRect(self.bounds)
        outside.addPath(path)
        for (layer, mask) in [(self.dropShadow, self.dropShadowMask), (self.glow, self.glowMask)] {
            layer.frame = self.bounds
            layer.shadowPath = path
            mask.frame = self.bounds
            mask.path = outside
        }
        self.glow.shadowColor = red
        self.border.frame = self.bounds
        self.border.path = CGPath(
            roundedRect: card.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: self.cornerRadius - 0.75,
            cornerHeight: self.cornerRadius - 0.75,
            transform: nil)
        // The card draws its own hairline while nothing is unread.
        self.border.strokeColor = self.isActive ? red : nil

        guard self.isActive else {
            self.glow.shadowOpacity = 0
            self.border.opacity = 1
            self.glow.removeAllAnimations()
            self.border.removeAllAnimations()
            return
        }
        self.glow.shadowOpacity = 0.15
        self.border.opacity = 0.35
        guard self.animates else {
            self.glow.removeAllAnimations()
            self.border.removeAllAnimations()
            return
        }
        if self.glow.animation(forKey: "breath") == nil {
            self.glow.add(Self.breath(keyPath: "shadowOpacity", from: 0.05, to: 0.25), forKey: "breath")
            self.border.add(Self.breath(keyPath: "opacity", from: 0.2, to: 0.5), forKey: "breath")
        }
    }

    private static func breath(keyPath: String, from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = self.period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

/// A short, faint arc that slowly turns around a running task's icon, quieter
/// than the unread glow.
private struct SpinningRing: NSViewRepresentable {
    let tint: Color
    let animates: Bool

    func makeNSView(context: Context) -> SpinningRingView {
        SpinningRingView()
    }

    func updateNSView(_ view: SpinningRingView, context: Context) {
        view.tint = NSColor(self.tint)
        view.animates = self.animates
        view.needsLayout = true
    }
}

private final class SpinningRingView: NSView {
    private let arc = CAShapeLayer()

    var tint = NSColor.labelColor
    var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.arc.fillColor = nil
        self.arc.lineWidth = 1.5
        self.arc.lineCap = .round
        self.arc.strokeStart = 0
        self.arc.strokeEnd = 0.3
        self.arc.opacity = 0.55
        self.layer?.addSublayer(self.arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.arc.frame = self.bounds
        self.arc.path = CGPath(ellipseIn: self.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        // Resolve dynamic colors for the card's light or dark appearance.
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.arc.strokeColor = self.tint.cgColor
        }
        guard self.animates else {
            self.arc.removeAllAnimations()
            return
        }
        guard self.arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        self.arc.add(spin, forKey: "spin")
    }
}

// MARK: Pieces

private struct CardPlatformIcon: View {
    let platform: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = PlatformStatusIcon.image(for: TokenPlatform(rawValue: self.platform)) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.fill")
                    .resizable()
            }
        }
        .frame(width: self.size, height: self.size)
        .foregroundStyle(CardAccent.tint(for: self.platform))
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon
                .font(.system(size: 8, weight: .semibold))
            configuration.title
        }
    }
}

private enum CardAccent {
    static let unread = Color(red: 1.0, green: 0.30, blue: 0.24)

    static func tint(for platform: String) -> Color {
        platform == TokenPlatform.claude.rawValue
            ? Color(red: 0.85, green: 0.47, blue: 0.34)
            : .primary
    }
}
