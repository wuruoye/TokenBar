import AppKit
import Observation
import SwiftUI
import TokenBarCore
import TokenBarWidgetData

/// The four macOS desktop widget sizes the card can take, or the one that
/// fits what it shows.
enum DesktopCardSize: String, CaseIterable, Identifiable {
    /// A large widget, which widens to an extra-large one while anything is
    /// unread.
    case automatic
    case small
    case medium
    case large
    case extraLarge

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    static let fixedSizes: [DesktopCardSize] = [.small, .medium, .large, .extraLarge]

    /// The visible size of a desktop widget of this size; for `automatic`, its
    /// size while nothing is unread.
    var points: CGSize {
        switch self {
        case .automatic: CGSize(width: 344, height: 344)
        case .small: CGSize(width: 164, height: 164)
        case .medium: CGSize(width: 344, height: 164)
        case .large: CGSize(width: 344, height: 344)
        case .extraLarge: CGSize(width: 704, height: 344)
        }
    }
}

/// What the desktop card shows and whether its animations should run.
@MainActor
@Observable
final class DesktopCardState {
    var snapshot = UnreadWidgetSnapshot(isTracking: true, platforms: [], tasks: [], running: [])
    /// False while other windows cover the card or its Space is not shown, so
    /// the animations stop drawing.
    var isVisible = true
    var size = DesktopCardSize.automatic
    /// The size the card lays its rows out for.
    var points = DesktopCardSize.automatic.points
}

/// Shows the unread and running desktop tasks in a card on the desktop. Unlike
/// a WidgetKit widget, TokenBar draws it, so it can animate freely. The card
/// sits above the desktop icons and below every app window, and follows the
/// desktop widget rules: widget sizes, on the widget grid, never on top of a
/// system widget.
@MainActor
final class DesktopCardController {
    private enum Defaults {
        /// `[x, y]`: the card's top-left corner where the user put it. A card
        /// that grows past the screen or into a widget moves away from it.
        static let origin = "TokenBar.desktopCard.origin"
        static let size = "TokenBar.desktopCard.widgetSize"
        /// `[x, y, anchorsBottom]` from cards that sized themselves to their
        /// rows: the left edge, and the top edge when not anchored to the bottom.
        static let legacyPlacement = "TokenBar.desktopCard.placement"
    }

    /// Desktop widgets sit this far apart, and their windows reach half of it
    /// past what they draw.
    private static let widgetGap: CGFloat = 16
    private static let gridStep = DesktopCardSize.small.points.width + widgetGap
    /// How long rows take to animate in or out.
    private static let rowAnimation: TimeInterval = 0.35

    private let publisher: UnreadWidgetPublisher
    private let settings: TokenBarSettings
    private let openTask: (TokenPlatform, String) -> Void
    private let state = DesktopCardState()
    private var panel: DesktopCardPanel?
    private var hostingView: NSHostingView<DesktopCardView>?
    private var occlusionObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var dragStart: (mouse: NSPoint, card: NSRect)?
    private var resizeStart: (mouse: NSPoint, card: NSRect)?
    private var pendingShrink: Task<Void, Never>?
    private var isStarted = false

    /// The card shows the widget's snapshot, which also remembers the tasks
    /// read last.
    init(
        publisher: UnreadWidgetPublisher,
        settings: TokenBarSettings,
        openTask: @escaping (TokenPlatform, String) -> Void)
    {
        self.publisher = publisher
        self.settings = settings
        self.openTask = openTask
        if let size = UserDefaults.standard.string(forKey: Defaults.size).flatMap(DesktopCardSize.init(rawValue:)) {
            self.state.size = size
        }
    }

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        self.observe()
        self.update()
    }

    func stop() {
        self.isStarted = false
        self.pendingShrink?.cancel()
        self.pendingShrink = nil
        self.closePanel()
    }

    private func observe() {
        withObservationTracking {
            _ = self.settings.showsDesktopCard
            _ = self.publisher.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.observe()
                self.update()
            }
        }
    }

    private func update() {
        guard self.settings.showsDesktopCard else {
            self.closePanel()
            return
        }
        let snapshot = self.publisher.snapshot
        guard self.panel != nil else {
            self.state.snapshot = snapshot
            self.state.points = self.points(for: snapshot)
            self.openPanel()
            return
        }
        guard snapshot != self.state.snapshot else { return }
        self.pendingShrink?.cancel()
        self.pendingShrink = nil
        // A card grows to make room before new rows slide in, and shrinks only
        // after the rows that leave have faded out.
        let points = self.points(for: snapshot)
        let current = self.state.points
        let grown = CGSize(width: max(points.width, current.width), height: max(points.height, current.height))
        if grown != current {
            self.resizeCard(to: grown)
        }
        withAnimation(.smooth(duration: Self.rowAnimation)) {
            self.state.snapshot = snapshot
        }
        if points != grown {
            self.pendingShrink = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.rowAnimation))
                guard let self, !Task.isCancelled else { return }
                self.pendingShrink = nil
                self.resizeCard(to: self.points(for: self.state.snapshot))
            }
        }
    }

    // MARK: Window

    private func openPanel() {
        let view = DesktopCardView(
            state: self.state,
            open: { [weak self] platform, taskID in
                self?.openTask(TokenPlatform(rawValue: platform), taskID)
            },
            drag: { [weak self] phase in
                self?.move(phase)
            },
            resize: { [weak self] phase in
                self?.resize(phase)
            },
            setSize: { [weak self] size in
                self?.setSize(size)
            },
            hide: { [weak self] in
                self?.settings.showsDesktopCard = false
            })
        let hostingView = NSHostingView(rootView: view)
        // The controller sizes the window; SwiftUI must not pin it.
        hostingView.sizingOptions = []
        let panel = DesktopCardPanel(contentView: hostingView)
        self.hostingView = hostingView
        self.panel = panel
        let size = self.state.points
        if let saved = self.savedTopLeft() {
            let card = self.placed(NSRect(x: saved.x, y: saved.y - size.height, width: size.width, height: size.height))
            panel.setFrame(Self.panelFrame(for: card), display: false)
        } else {
            let card = self.placed(self.defaultCard(size: size))
            panel.setFrame(Self.panelFrame(for: card), display: false)
            self.save(card)
        }
        panel.orderFrontRegardless()

        self.occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.state.isVisible = panel.occlusionState.contains(.visible)
            }
        }
        self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resizeCard(to: self.points(for: self.state.snapshot), animated: false)
            }
        }
    }

    private func closePanel() {
        for observer in [self.occlusionObserver, self.screenObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        self.occlusionObserver = nil
        self.screenObserver = nil
        self.panel?.orderOut(nil)
        self.panel = nil
        self.hostingView = nil
    }

    // MARK: Geometry

    private var card: NSRect? {
        self.panel.map { $0.frame.insetBy(dx: DesktopCardView.glowRoom, dy: DesktopCardView.glowRoom) }
    }

    private static func panelFrame(for card: NSRect) -> NSRect {
        card.insetBy(dx: -DesktopCardView.glowRoom, dy: -DesktopCardView.glowRoom)
    }

    private func move(_ phase: DesktopCardView.DragPhase) {
        guard let panel = self.panel, let card = self.card else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            let start = self.dragStart ?? (mouse, card)
            self.dragStart = start
            panel.setFrame(
                Self.panelFrame(for: start.card.offsetBy(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y)),
                display: true)
        case .ended:
            self.dragStart = nil
            self.settle(animated: true)
        }
    }

    /// The bottom-right corner picks the widget size nearest the pointer, the
    /// way a desktop widget steps between sizes.
    private func resize(_ phase: DesktopCardView.DragPhase) {
        guard let card = self.card else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            let start = self.resizeStart ?? (mouse, card)
            self.resizeStart = start
            let wanted = CGSize(
                width: start.card.width + mouse.x - start.mouse.x,
                height: start.card.height - (mouse.y - start.mouse.y))
            let nearest = DesktopCardSize.fixedSizes.min { lhs, rhs in
                Self.distance(lhs.points, wanted) < Self.distance(rhs.points, wanted)
            } ?? self.state.size
            if nearest.points != self.state.points || nearest != self.state.size {
                self.apply(nearest, topLeft: NSPoint(x: start.card.minX, y: start.card.maxY))
            }
        case .ended:
            self.resizeStart = nil
            UserDefaults.standard.set(self.state.size.rawValue, forKey: Defaults.size)
            self.settle(animated: true)
        }
    }

    private func setSize(_ size: DesktopCardSize) {
        guard size != self.state.size else { return }
        self.state.size = size
        UserDefaults.standard.set(size.rawValue, forKey: Defaults.size)
        self.resizeCard(to: self.points(for: self.state.snapshot))
    }

    /// Changes the size with the card's top-left corner in place.
    private func apply(_ size: DesktopCardSize, topLeft: NSPoint) {
        guard let panel = self.panel else { return }
        let points = size.points
        self.state.size = size
        self.state.points = points
        panel.setFrame(
            Self.panelFrame(for: NSRect(
                x: topLeft.x,
                y: topLeft.y - points.height,
                width: points.width,
                height: points.height)),
            display: true)
    }

    /// The size the card takes for `snapshot`: its widget size, or for
    /// `automatic` the extra-large widget while anything is unread.
    private func points(for snapshot: UnreadWidgetSnapshot) -> CGSize {
        guard self.state.size == .automatic, !snapshot.tasks.isEmpty else {
            return self.state.size.points
        }
        return DesktopCardSize.extraLarge.points
    }

    /// Resizes the card on the grid spot nearest where the user put it. The
    /// card keeps that place, so it returns there once it is short enough.
    private func resizeCard(to points: CGSize, animated: Bool = true) {
        guard let card = self.card else { return }
        let home = self.savedTopLeft() ?? NSPoint(x: card.minX, y: card.maxY)
        self.state.points = points
        let target = self.placed(NSRect(
            x: home.x,
            y: home.y - points.height,
            width: points.width,
            height: points.height))
        self.setCard(target, animated: animated)
    }

    private func setCard(_ card: NSRect, animated: Bool) {
        guard let panel = self.panel else { return }
        let frame = Self.panelFrame(for: card)
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private static func distance(_ lhs: CGSize, _ rhs: CGSize) -> CGFloat {
        hypot(lhs.width - rhs.width, lhs.height - rhs.height)
    }

    /// Moves the card onto the nearest free spot of the widget grid and
    /// remembers it.
    private func settle(animated: Bool) {
        guard let card = self.card else { return }
        let target = self.placed(card)
        self.setCard(target, animated: animated)
        self.save(target)
    }

    private func savedTopLeft() -> NSPoint? {
        let defaults = UserDefaults.standard
        if let values = defaults.array(forKey: Defaults.origin) as? [Double], values.count == 2 {
            return NSPoint(x: values[0], y: values[1])
        }
        if let values = defaults.array(forKey: Defaults.legacyPlacement) as? [Double], values.count == 3, values[2] == 0 {
            return NSPoint(x: values[0], y: values[1])
        }
        return nil
    }

    private func save(_ card: NSRect) {
        UserDefaults.standard.set([card.minX, card.maxY], forKey: Defaults.origin)
    }

    /// The grid spot nearest `card` on the screen under its center where the
    /// card fits on screen and clears every system widget by the widget gap.
    private func placed(_ card: NSRect) -> NSRect {
        let center = NSPoint(x: card.midX, y: card.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first
        else {
            return card
        }
        let area = screen.visibleFrame.insetBy(dx: Self.widgetGap, dy: Self.widgetGap)
        let widgets = Self.systemWidgetFrames().filter { screen.frame.intersects($0) }
        // Share the system widgets' grid; without any, start at the top-left
        // corner of the usable area.
        let anchor = widgets.first.map { NSPoint(x: $0.minX, y: $0.maxY) } ?? NSPoint(x: area.minX, y: area.maxY)
        let step = Self.gridStep
        let size = card.size
        let columns = Int(floor((area.minX - anchor.x) / step))...Int(ceil((area.maxX - anchor.x) / step))
        let rows = Int(floor((anchor.y - area.maxY) / step))...Int(ceil((anchor.y - area.minY) / step))

        var best: NSRect?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for column in columns {
            for row in rows {
                let spot = NSRect(
                    x: anchor.x + CGFloat(column) * step,
                    y: anchor.y - CGFloat(row) * step - size.height,
                    width: size.width,
                    height: size.height)
                guard area.contains(spot),
                      !widgets.contains(where: {
                          $0.insetBy(dx: -Self.widgetGap / 2, dy: -Self.widgetGap / 2).intersects(spot)
                      })
                else {
                    continue
                }
                let distance = hypot(spot.minX - card.minX, spot.maxY - card.maxY)
                if distance < bestDistance {
                    best = spot
                    bestDistance = distance
                }
            }
        }
        return best ?? card
    }

    /// The top-right corner of the screen with the menu bar.
    private func defaultCard(size: CGSize) -> NSRect {
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.maxX - Self.widgetGap - size.width,
            y: visible.maxY - Self.widgetGap - size.height,
            width: size.width,
            height: size.height)
    }

    /// What each system desktop widget draws, in screen coordinates. The
    /// widgets are Notification Center windows just above the desktop icons,
    /// each reaching half the widget gap past what it draws.
    private static func systemWidgetFrames() -> [NSRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }
        let widgetLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 2
        let sizes = Set(DesktopCardSize.fixedSizes.flatMap {
            [$0.points.width + self.widgetGap, $0.points.height + self.widgetGap]
        })
        return windows.compactMap { window -> NSRect? in
            guard window[kCGWindowLayer as String] as? Int == widgetLevel,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.notificationcenterui",
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  sizes.contains(width), sizes.contains(height)
            else {
                return nil
            }
            // Window bounds are measured from the top-left of the primary screen.
            return NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
                .insetBy(dx: self.widgetGap / 2, dy: self.widgetGap / 2)
        }
    }
}

/// A borderless panel at the desktop icon level. It never becomes key, so
/// clicking it leaves the frontmost app as it was.
private final class DesktopCardPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 344, height: 344),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.contentView = contentView
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isMovable = false
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
