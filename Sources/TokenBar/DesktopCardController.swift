import AppKit
import Observation
import SwiftUI
import TokenBarCore
import TokenBarWidgetData

/// What the desktop card shows and whether its animations should run.
@MainActor
@Observable
final class DesktopCardState {
    var snapshot = UnreadWidgetSnapshot(isTracking: true, platforms: [], tasks: [], running: [])
    /// False while other windows cover the card or its Space is not shown, so
    /// the animations stop drawing.
    var isVisible = true
    /// The size the user dragged the card to. Without one, the card's height
    /// follows its rows.
    var cardSize: CGSize?
    /// A card snapped to the bottom edge grows upward as rows arrive.
    var anchorsBottom = false
}

/// Shows the unread and running desktop tasks in a card on the desktop. Unlike
/// a WidgetKit widget, TokenBar draws it, so it can animate freely. The card
/// sits above the desktop icons and below every app window.
@MainActor
final class DesktopCardController {
    private enum Defaults {
        /// `[x, y, anchorsBottom]`: the card's left edge, and its bottom edge
        /// when anchored there or its top edge otherwise.
        static let placement = "TokenBar.desktopCard.placement"
        static let size = "TokenBar.desktopCard.size"
    }

    /// The card's distance from the screen's usable edges once it snaps.
    private static let margin: CGFloat = 20
    /// A card released this close to an edge snaps to it.
    private static let snapDistance: CGFloat = 100
    private static let minimumSize = CGSize(width: 260, height: 140)
    private static let maximumWidth: CGFloat = 720

    private let unreadTasks: DesktopUnreadTaskMonitor
    private let settings: TokenBarSettings
    private let openTask: (TokenPlatform, String) -> Void
    private let state = DesktopCardState()
    private var panel: DesktopCardPanel?
    private var hostingView: NSHostingView<DesktopCardView>?
    private var occlusionObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var dragStart: (mouse: NSPoint, card: NSRect)?
    private var resizeStart: (mouse: NSPoint, card: NSRect)?
    private var pendingShrink: DispatchWorkItem?
    private var isStarted = false

    /// How long rows take to animate in or out.
    private static let rowAnimation: TimeInterval = 0.35

    private var anchorsBottom: Bool {
        get { self.state.anchorsBottom }
        set { self.state.anchorsBottom = newValue }
    }

    init(
        unreadTasks: DesktopUnreadTaskMonitor,
        settings: TokenBarSettings,
        openTask: @escaping (TokenPlatform, String) -> Void)
    {
        self.unreadTasks = unreadTasks
        self.settings = settings
        self.openTask = openTask
        if let size = UserDefaults.standard.array(forKey: Defaults.size) as? [Double], size.count == 2 {
            self.state.cardSize = CGSize(width: size[0], height: size[1])
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
        self.closePanel()
    }

    private func observe() {
        withObservationTracking {
            _ = self.settings.showsDesktopCard
            _ = self.settings.showsClaude
            _ = self.unreadTasks.tasks
            _ = self.unreadTasks.running
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
        let snapshot = UnreadWidgetPublisher.snapshot(of: self.unreadTasks, settings: self.settings)
        guard self.panel != nil else {
            self.state.snapshot = snapshot
            self.openPanel()
            return
        }
        guard snapshot != self.state.snapshot else { return }
        withAnimation(.smooth(duration: Self.rowAnimation)) {
            self.state.snapshot = snapshot
        }
        // SwiftUI lays out the new rows before the card takes their height.
        DispatchQueue.main.async { [weak self] in
            self?.fitToContent()
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
            resetSize: { [weak self] in
                self?.resetSize()
            },
            hide: { [weak self] in
                self?.settings.showsDesktopCard = false
            })
        let hostingView = NSHostingView(rootView: view)
        // The controller sizes the window from the card's ideal size; SwiftUI
        // must not also pin the window's minimum and maximum to it.
        hostingView.sizingOptions = [.intrinsicContentSize]
        let panel = DesktopCardPanel(contentView: hostingView)
        self.hostingView = hostingView
        self.panel = panel
        let size = self.contentSize()
        let card = self.savedCard(size: size) ?? self.defaultCard(size: size)
        panel.setFrame(Self.panelFrame(for: card), display: false)
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
                self?.settle(animated: false)
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

    /// The card's own size, without the glow room around it.
    private func contentSize() -> CGSize {
        if let size = self.state.cardSize {
            return size
        }
        let fitting = self.hostingView?.fittingSize ?? CGSize(width: DesktopCardView.width, height: 120)
        let glow = DesktopCardView.glowRoom * 2
        return CGSize(width: fitting.width - glow, height: fitting.height - glow)
    }

    private var card: NSRect? {
        self.panel.map { $0.frame.insetBy(dx: DesktopCardView.glowRoom, dy: DesktopCardView.glowRoom) }
    }

    private static func panelFrame(for card: NSRect) -> NSRect {
        card.insetBy(dx: -DesktopCardView.glowRoom, dy: -DesktopCardView.glowRoom)
    }

    /// Keeps the anchored edge in place while the height follows the rows. The
    /// transparent window grows before new rows animate in and shrinks only
    /// after old rows have animated out, so the card itself moves smoothly.
    private func fitToContent() {
        guard let panel = self.panel, let card = self.card else { return }
        let size = self.contentSize()
        guard size != card.size else { return }
        self.pendingShrink?.cancel()
        self.pendingShrink = nil
        let resize = { [weak self] in
            guard let self, let card = self.card else { return }
            let size = self.contentSize()
            let y = self.anchorsBottom ? card.minY : card.maxY - size.height
            panel.setFrame(
                Self.panelFrame(for: NSRect(x: card.minX, y: y, width: size.width, height: size.height)),
                display: true)
            self.settle(animated: false)
        }
        guard size.height < card.height else {
            resize()
            return
        }
        let shrink = DispatchWorkItem(block: resize)
        self.pendingShrink = shrink
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rowAnimation + 0.05, execute: shrink)
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

    /// The bottom-right corner follows the pointer while the top-left corner
    /// stays put.
    private func resize(_ phase: DesktopCardView.DragPhase) {
        guard let panel = self.panel, let card = self.card else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            let start = self.resizeStart ?? (mouse, card)
            self.resizeStart = start
            let screenHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
            let size = CGSize(
                width: min(max(start.card.width + mouse.x - start.mouse.x, Self.minimumSize.width), Self.maximumWidth),
                height: min(
                    max(start.card.height - (mouse.y - start.mouse.y), Self.minimumSize.height),
                    screenHeight - Self.margin * 2))
            self.state.cardSize = size
            panel.setFrame(
                Self.panelFrame(for: NSRect(
                    x: start.card.minX,
                    y: start.card.maxY - size.height,
                    width: size.width,
                    height: size.height)),
                display: true)
        case .ended:
            self.resizeStart = nil
            if let size = self.state.cardSize {
                UserDefaults.standard.set([size.width, size.height], forKey: Defaults.size)
            }
            self.settle(animated: true)
        }
    }

    private func resetSize() {
        self.state.cardSize = nil
        UserDefaults.standard.removeObject(forKey: Defaults.size)
        DispatchQueue.main.async { [weak self] in
            self?.fitToContent()
        }
    }

    /// Snaps the card to nearby screen edges, keeps it on a screen, and
    /// remembers where it went.
    private func settle(animated: Bool) {
        guard let panel = self.panel, let card = self.card else { return }
        let target = self.snapped(card)
        let frame = Self.panelFrame(for: target)
        if frame != panel.frame {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
        UserDefaults.standard.set(
            [target.minX, self.anchorsBottom ? target.minY : target.maxY, self.anchorsBottom ? 1 : 0],
            forKey: Defaults.placement)
    }

    /// Pulls the card inside the usable area of the screen under its center,
    /// then snaps each axis to an edge within `snapDistance`. A card off every
    /// screen goes back to the default corner.
    private func snapped(_ card: NSRect) -> NSRect {
        let center = NSPoint(x: card.midX, y: card.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return self.defaultCard(size: card.size)
        }
        let area = screen.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
        var result = card
        result.origin.x = min(max(result.minX, area.minX), max(area.maxX - result.width, area.minX))
        result.origin.y = min(max(result.minY, area.minY), max(area.maxY - result.height, area.minY))

        if result.minX - area.minX < Self.snapDistance {
            result.origin.x = area.minX
        } else if area.maxX - result.maxX < Self.snapDistance {
            result.origin.x = area.maxX - result.width
        }
        self.anchorsBottom = false
        if area.maxY - result.maxY < Self.snapDistance {
            result.origin.y = area.maxY - result.height
        } else if result.minY - area.minY < Self.snapDistance {
            result.origin.y = area.minY
            self.anchorsBottom = true
        }
        return result
    }

    /// The top-right corner of the screen with the menu bar.
    private func defaultCard(size: CGSize) -> NSRect {
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        self.anchorsBottom = false
        return NSRect(
            x: visible.maxX - Self.margin - size.width,
            y: visible.maxY - Self.margin - size.height,
            width: size.width,
            height: size.height)
    }

    private func savedCard(size: CGSize) -> NSRect? {
        guard let values = UserDefaults.standard.array(forKey: Defaults.placement) as? [Double],
              values.count == 3
        else {
            return nil
        }
        self.anchorsBottom = values[2] == 1
        let y = self.anchorsBottom ? values[1] : values[1] - size.height
        return self.snapped(NSRect(x: values[0], y: y, width: size.width, height: size.height))
    }
}

/// A borderless panel at the desktop icon level. It never becomes key, so
/// clicking it leaves the frontmost app as it was.
private final class DesktopCardPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
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
