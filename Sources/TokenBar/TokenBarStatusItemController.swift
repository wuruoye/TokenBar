import AppKit
import Observation
import SwiftUI
import TokenBarCore

@MainActor
final class TokenBarStatusItemController: NSObject, NSMenuDelegate, TokenBarMenuPersistentActionDelegate {
    private static let menuWidth: CGFloat = 384
    private static let requestDetailCacheLimit = 64

    private struct RenderedSessionProjection {
        let ids: [String]
        let collapsedLimit: Int
    }

    private let model: DashboardModel
    private let settings: TokenBarSettings
    private let requestDetailService: any RequestDetailProviding
    private let statusItem: NSStatusItem
    private let rootMenu = TokenBarMenu()
    private var sessionItems: [String: NSMenuItem] = [:]
    private var renderedSessionProjection: RenderedSessionProjection?
    private var submenuSessionIDs: [ObjectIdentifier: String] = [:]
    private var requestDetailMenus: [ObjectIdentifier: RequestDetailMenuContext] = [:]
    private var requestDetailTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var requestDetailCache: [String: RequestDetail] = [:]
    private var requestDetailCacheOrder: [String] = []
    private var sessionExpansionItem: NSMenuItem?
    private var sessionExpansionView: PersistentMenuActionRowView?
    private var highlightedRows: [ObjectIdentifier: any TokenMenuHighlighting] = [:]
    private var showsAllSessions = false
    private var isRootMenuOpen = false
    private var startupTask: Task<Void, Never>?
    private var settingsWindowController: SettingsWindowController?

    init(
        model: DashboardModel,
        settings: TokenBarSettings = .shared,
        requestDetailService: any RequestDetailProviding = CodexRequestDetailService())
    {
        self.model = model
        self.settings = settings
        self.requestDetailService = requestDetailService
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.rootMenu.autoenablesItems = false
        self.rootMenu.minimumWidth = Self.menuWidth
        self.rootMenu.delegate = self
        self.rootMenu.persistentActionDelegate = self
        self.statusItem.menu = self.rootMenu
        self.configureStatusButton()
        self.model.updateBackgroundRefreshInterval(settings.backgroundRefreshDuration)
        self.rebuildRootMenu()
        self.observeModel()
        self.observeSettings()
    }

    func start() {
        self.startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.start()
            #if DEBUG
            if ProcessInfo.processInfo.environment["TOKENBAR_DEMO_OPEN_MENU"] == "1" {
                try? await Task.sleep(for: .milliseconds(250))
                self.statusItem.button?.performClick(nil)
            }
            #endif
        }
    }

    func tearDown() {
        self.startupTask?.cancel()
        self.startupTask = nil
        self.discardRequestDetailMenus(in: self.rootMenu)
        self.rootMenu.delegate = nil
        self.rootMenu.persistentActionDelegate = nil
        self.settingsWindowController?.close()
        self.settingsWindowController = nil
        self.statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(self.statusItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.rootMenu {
            self.rebuildRootMenu()
            return
        }

        let menuID = ObjectIdentifier(menu)
        if let context = self.requestDetailMenus[menuID] {
            self.prepareRequestDetailView(context)
            return
        }

        guard let sessionID = self.submenuSessionIDs[menuID] else { return }
        self.rebuildRequestMenu(menu, sessionID: sessionID)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.rootMenu {
            self.isRootMenuOpen = true
            Task { @MainActor [weak self] in
                await self?.model.refreshAll()
            }
            return
        }

        let menuID = ObjectIdentifier(menu)
        if self.requestDetailMenus[menuID] != nil {
            for (otherMenuID, task) in self.requestDetailTasks where otherMenuID != menuID {
                task.cancel()
            }
        }
        self.loadRequestDetailIfNeeded(menuID: menuID)
    }

    func menuDidClose(_ menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        if self.requestDetailMenus[menuID] != nil {
            self.requestDetailTasks[menuID]?.cancel()
        }
        self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
        if menu === self.rootMenu {
            self.isRootMenuOpen = false
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let menuID = ObjectIdentifier(menu)
        self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
        guard let row = item?.view as? any TokenMenuHighlighting else { return }
        row.setMenuHighlighted(true)
        self.highlightedRows[menuID] = row
    }

    nonisolated func performPersistentRefresh() {
        Task { @MainActor [weak self] in
            await self?.model.refreshAll()
        }
    }

    private func configureStatusButton() {
        guard let button = self.statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        self.updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = self.statusItem.button else { return }
        let today = self.model.activitySnapshot?.today.tokens.total.compactCount ?? "—"
        let weekly = self.model.quotaSnapshot?.weekly.map {
            "\(Int($0.remainingPercent.clamped(to: 0 ... 100).rounded()))%"
        } ?? "—"
        button.image = StatusLabelRenderer.image(today: today, weekly: weekly)
        button.toolTip = "Today: \(today) tokens · Weekly: \(weekly) left"
        button.setAccessibilityLabel("Today, \(today) tokens. Weekly quota, \(weekly) remaining.")
    }

    private func observeModel() {
        withObservationTracking {
            _ = self.model.quota
            _ = self.model.activity
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeModel()
                self.modelDidChange()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = self.settings.theme
            _ = self.settings.recentSessionCount
            _ = self.settings.refreshInterval
            _ = self.settings.showsFullRequestContentOnHover
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSettings()
                self.model.updateBackgroundRefreshInterval(self.settings.backgroundRefreshDuration)
            }
        }
    }

    private func modelDidChange() {
        self.updateStatusButton()
        guard self.isRootMenuOpen else { return }
        self.updateVisibleSessionItems()
    }

    private func rebuildRootMenu() {
        self.discardRequestDetailMenus(in: self.rootMenu)
        for row in self.highlightedRows.values {
            row.setMenuHighlighted(false)
        }
        self.highlightedRows.removeAll()
        self.rootMenu.removeAllItems()
        self.sessionItems.removeAll()
        self.renderedSessionProjection = nil
        self.sessionExpansionItem = nil
        self.sessionExpansionView = nil
        self.submenuSessionIDs.removeAll()

        let showsFiveHour = self.model.quotaSnapshot?.session != nil
        let showsResetCredits = self.model.quotaSnapshot?.resetCredits != nil
        let accentColor = self.settings.theme.color
        let overviewHeight = DashboardOverviewView.preferredHeight(
            showsFiveHour: showsFiveHour,
            showsResetCredits: showsResetCredits)
        let overview = DashboardOverviewView(
            model: self.model,
            showsFiveHour: showsFiveHour,
            showsResetCredits: showsResetCredits,
            accentColor: accentColor)
            .frame(
                width: Self.menuWidth,
                height: overviewHeight,
                alignment: .top)
        let overviewHost = FixedMenuHostingView(
            rootView: AnyView(overview),
            width: Self.menuWidth,
            height: overviewHeight)
        let overviewItem = NSMenuItem()
        overviewItem.view = overviewHost
        overviewItem.isEnabled = false
        self.rootMenu.addItem(overviewItem)

        let activityHeight = ActivitySummarySection.preferredHeight + 1
        let activity = VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            ActivitySummarySection(
                state: self.model.activity,
                accentColor: accentColor,
                showsChevron: true)
        }
        .allowsHitTesting(false)
        .frame(width: Self.menuWidth, height: activityHeight, alignment: .top)
        let activityHost = FixedMenuHostingView(
            rootView: AnyView(activity),
            width: Self.menuWidth,
            height: activityHeight)
        let activityItem = NSMenuItem(
            title: "Activity",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        activityItem.target = self
        activityItem.isEnabled = true
        activityItem.view = activityHost
        activityItem.submenu = self.makeActivityDetailMenu(accentColor: accentColor)
        self.rootMenu.addItem(activityItem)
        self.rootMenu.addItem(.separator())

        self.rootMenu.addItem(.sectionHeader(title: "Recent Sessions"))
        self.addSessionItems()
        self.rootMenu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: nil, keyEquivalent: "")
        let refreshView = PersistentMenuActionRowView(
            width: Self.menuWidth,
            title: "Refresh Now",
            systemImageName: "arrow.clockwise",
            shortcut: "⌘R",
            accessibilityHelp: "Refresh without closing the menu. Command-R.")
        refreshView.onActivate = { [weak self] in
            self?.refreshNow()
        }
        refresh.view = refreshView
        refresh.isEnabled = true
        refresh.toolTip = "Refresh without closing the menu (⌘R)"
        self.rootMenu.addItem(refresh)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(self.showSettings),
            keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        self.rootMenu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(self.quit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        self.rootMenu.addItem(quit)
    }

    private func addSessionItems() {
        guard let snapshot = self.model.activitySnapshot, !snapshot.sessions.isEmpty else {
            let empty = NSMenuItem(title: "No sessions today", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            self.rootMenu.addItem(empty)
            return
        }

        let sessions = snapshot.sessionMenu(limit: nil).visibleSessions
        let projection = RenderedSessionProjection(
            ids: sessions.map(\.id),
            collapsedLimit: self.settings.recentSessionLimit)
        self.renderedSessionProjection = projection
        for (index, session) in sessions.enumerated() {
            let item = self.makeSessionItem(session)
            item.isHidden = !self.showsAllSessions && index >= projection.collapsedLimit
            self.sessionItems[session.id] = item
            self.rootMenu.addItem(item)
        }

        if sessions.count > projection.collapsedLimit {
            let title = self.sessionExpansionTitle(projection: projection)
            let expansion = PersistentMenuActionRowView(
                width: Self.menuWidth,
                title: title,
                systemImageName: self.showsAllSessions ? "chevron.up" : "chevron.down",
                accessibilityHelp: "Expand or collapse recent sessions without closing the menu.")
            expansion.onActivate = { [weak self] in
                self?.toggleSessionExpansion()
            }
            let expansionItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            expansionItem.isEnabled = true
            expansionItem.view = expansion
            self.sessionExpansionItem = expansionItem
            self.sessionExpansionView = expansion
            self.rootMenu.addItem(expansionItem)
        }
    }

    private func toggleSessionExpansion() {
        guard let projection = self.renderedSessionProjection else { return }
        self.showsAllSessions.toggle()
        for (index, sessionID) in projection.ids.enumerated() {
            self.sessionItems[sessionID]?.isHidden = !self.showsAllSessions
                && index >= projection.collapsedLimit
        }
        let title = self.sessionExpansionTitle(projection: projection)
        self.sessionExpansionItem?.title = title
        self.sessionExpansionView?.configure(
            title: title,
            systemImageName: self.showsAllSessions ? "chevron.up" : "chevron.down",
            accessibilityHelp: "Expand or collapse recent sessions without closing the menu.")
    }

    private func sessionExpansionTitle(projection: RenderedSessionProjection) -> String {
        if self.showsAllSessions {
            return "Show Recent \(projection.collapsedLimit)"
        }
        return "Show \(max(0, projection.ids.count - projection.collapsedLimit)) More…"
    }

    private func makeActivityDetailMenu(accentColor: Color) -> TokenBarMenu {
        let menu = TokenBarMenu(title: "Activity Detail")
        menu.autoenablesItems = false
        menu.minimumWidth = ActivityDetailView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detail = ActivityDetailView(model: self.model, accentColor: accentColor)
            .frame(
                width: ActivityDetailView.preferredWidth,
                height: ActivityDetailView.preferredHeight,
                alignment: .topLeading)
        let host = FixedMenuHostingView(
            rootView: AnyView(detail),
            width: ActivityDetailView.preferredWidth,
            height: ActivityDetailView.preferredHeight)
        let item = NSMenuItem(
            title: "Activity Detail",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.view = host
        menu.addItem(item)
        return menu
    }

    private func makeSessionItem(_ session: SessionSummary) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Session",
            action: #selector(self.sessionNoOp),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        self.configureSessionItem(item, session: session)

        let submenu = TokenBarMenu(title: session.menuTitle)
        submenu.autoenablesItems = false
        submenu.minimumWidth = Self.menuWidth
        submenu.delegate = self
        submenu.persistentActionDelegate = self
        submenu.addItem(NSMenuItem(title: "Loading turns…", action: nil, keyEquivalent: ""))
        self.submenuSessionIDs[ObjectIdentifier(submenu)] = session.id
        item.submenu = submenu
        return item
    }

    private func configureSessionItem(_ item: NSMenuItem, session: SessionSummary) {
        let title = session.menuTitle
        let detail = session.tokens.sessionMenuDetail
        let time = Date(timeIntervalSince1970: Double(session.endedAtMs) / 1000).menuClockText
        item.title = "Session"
        item.toolTip = "\(title)\n\(detail)\nEnded \(time)"

        let row = (item.view as? TokenMenuRowView) ?? TokenMenuRowView(width: Self.menuWidth)
        row.configure(
            title: title,
            cost: session.menuCostText,
            detail: detail,
            trailing: time,
            showsChevron: true)
        item.view = row
    }

    private func updateVisibleSessionItems() {
        guard let sessions = self.model.activitySnapshot?.sessions else { return }
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for (id, item) in self.sessionItems {
            guard let session = sessionsByID[id] else { continue }
            self.configureSessionItem(item, session: session)
            item.submenu?.title = session.menuTitle
        }
    }

    private func rebuildRequestMenu(_ menu: NSMenu, sessionID: String) {
        self.discardRequestDetailMenus(in: menu)
        menu.removeAllItems()
        guard let session = self.model.activitySnapshot?.sessions.first(where: { $0.id == sessionID }) else {
            let unavailable = NSMenuItem(title: "Session is no longer available", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
            return
        }

        menu.title = session.menuTitle
        menu.minimumWidth = Self.menuWidth
        menu.addItem(.sectionHeader(title: "Turns"))
        let copySession = NSMenuItem(
            title: "Copy Session",
            action: #selector(self.copySession(_:)),
            keyEquivalent: "")
        copySession.target = self
        copySession.representedObject = session
        copySession.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copySession)
        menu.addItem(.separator())

        let requests = session.requests.sorted {
            if $0.endedAtMs != $1.endedAtMs {
                return $0.endedAtMs > $1.endedAtMs
            }
            return $0.id < $1.id
        }
        if requests.isEmpty {
            let empty = NSMenuItem(title: "No turns", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for request in requests {
            menu.addItem(self.makeTurnItem(request))
        }
    }

    private func makeTurnItem(_ turn: RequestSummary) -> NSMenuItem {
        let physicalRequests = turn.physicalRequests.sorted {
            if $0.isSubagent != $1.isSubagent {
                return !$0.isSubagent
            }
            if $0.startedAtMs != $1.startedAtMs {
                return $0.startedAtMs < $1.startedAtMs
            }
            return $0.id < $1.id
        }
        let item = NSMenuItem(title: "Turn", action: nil, keyEquivalent: "")
        item.isEnabled = true

        let row = TokenMenuRowView(width: Self.menuWidth)
        row.configure(
            title: turn.menuRowTitle,
            cost: turn.menuCostText,
            detail: turn.tokens.requestMenuDetail,
            trailing: "\(turn.startedAt.menuClockText) · \(turn.menuDurationText)",
            showsChevron: physicalRequests.count > 1 || self.settings.showsFullRequestContentOnHover)
        item.view = row

        if physicalRequests.count > 1 {
            item.toolTip = "Hover to inspect the requests contributing to this turn"
            item.submenu = self.makeAgentRequestMenu(
                title: turn.menuTitle,
                requests: physicalRequests)
        } else if let request = physicalRequests.first {
            self.configureCopyInteraction(item: item, row: row, request: request)
            if self.settings.showsFullRequestContentOnHover {
                item.submenu = self.makeRequestDetailMenu(for: request)
            }
        }
        return item
    }

    private func makeAgentRequestMenu(
        title: String,
        requests: [RequestSummary]) -> TokenBarMenu
    {
        let menu = TokenBarMenu(title: title)
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
        menu.delegate = self
        menu.persistentActionDelegate = self
        menu.addItem(.sectionHeader(title: "Agent Requests"))

        for request in requests {
            let item = NSMenuItem(title: "Agent Request", action: nil, keyEquivalent: "")
            item.isEnabled = true
            let row = TokenMenuRowView(width: Self.menuWidth)
            row.configure(
                title: request.agentRequestMenuTitle,
                cost: request.menuCostText,
                detail: request.tokens.requestMenuDetail,
                trailing: "\(request.startedAt.menuClockText) · \(request.menuDurationText)",
                showsChevron: self.settings.showsFullRequestContentOnHover)
            item.view = row
            self.configureCopyInteraction(item: item, row: row, request: request)
            if self.settings.showsFullRequestContentOnHover {
                item.submenu = self.makeRequestDetailMenu(for: request)
            }
            menu.addItem(item)
        }
        return menu
    }

    private func configureCopyInteraction(
        item: NSMenuItem,
        row: TokenMenuRowView,
        request: RequestSummary)
    {
        item.target = self
        item.action = #selector(self.copyRequest(_:))
        item.representedObject = request
        item.toolTip = "Click to copy the Tokscale request locator"
        row.onActivate = { [weak self, weak item] in
            guard let item else { return }
            self?.copyRequest(item)
            item.menu?.cancelTracking()
            self?.rootMenu.cancelTracking()
        }
    }

    private func makeRequestDetailMenu(for request: RequestSummary) -> TokenBarMenu {
        let menu = TokenBarMenu(title: "Request Details")
        menu.autoenablesItems = false
        menu.minimumWidth = RequestDetailMenuView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detailView = RequestDetailMenuView()
        detailView.showLoading(
            promptPreview: request.promptPreview,
            outputPreview: request.outputPreview)
        let detailItem = NSMenuItem(
            title: "Request Details",
            action: #selector(self.requestDetailNoOp),
            keyEquivalent: "")
        detailItem.target = self
        detailItem.isEnabled = true
        detailItem.view = detailView
        menu.addItem(detailItem)

        self.requestDetailMenus[ObjectIdentifier(menu)] = RequestDetailMenuContext(
            request: request,
            view: detailView)
        return menu
    }

    private func prepareRequestDetailView(_ context: RequestDetailMenuContext) {
        if let detail = self.requestDetailCache[context.cacheKey] {
            context.view.show(
                prompt: detail.prompt ?? context.request.promptPreview,
                output: detail.output ?? context.request.outputPreview)
        } else {
            context.view.showLoading(
                promptPreview: context.request.promptPreview,
                outputPreview: context.request.outputPreview)
        }
    }

    private func loadRequestDetailIfNeeded(menuID: ObjectIdentifier) {
        guard let context = self.requestDetailMenus[menuID],
              self.requestDetailCache[context.cacheKey] == nil,
              self.requestDetailTasks[menuID] == nil
        else {
            return
        }

        let request = context.request
        let cacheKey = context.cacheKey
        let task = Task { @MainActor [weak self, weak detailView = context.view] in
            guard let self else { return }
            defer { self.requestDetailTasks[menuID] = nil }
            do {
                let detail = try await self.requestDetailService.fetchDetail(for: request)
                try Task.checkCancellation()
                self.cacheRequestDetail(detail, forKey: cacheKey)
                guard self.requestDetailMenus[menuID]?.cacheKey == cacheKey else { return }
                detailView?.show(
                    prompt: detail.prompt ?? request.promptPreview,
                    output: detail.output ?? request.outputPreview)
            } catch is CancellationError {
                // The parent menu was rebuilt or the app is terminating.
            } catch {
                guard self.requestDetailMenus[menuID]?.cacheKey == cacheKey else { return }
                detailView?.showError(
                    error.localizedDescription,
                    promptPreview: request.promptPreview,
                    outputPreview: request.outputPreview)
            }
        }
        self.requestDetailTasks[menuID] = task
    }

    private func cacheRequestDetail(_ detail: RequestDetail, forKey key: String) {
        if self.requestDetailCache[key] == nil {
            self.requestDetailCacheOrder.append(key)
        }
        self.requestDetailCache[key] = detail

        while self.requestDetailCacheOrder.count > Self.requestDetailCacheLimit {
            let expiredKey = self.requestDetailCacheOrder.removeFirst()
            self.requestDetailCache.removeValue(forKey: expiredKey)
        }
    }

    private func discardRequestDetailMenus(in menu: NSMenu) {
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            self.discardRequestDetailMenus(in: submenu)

            let menuID = ObjectIdentifier(submenu)
            guard self.requestDetailMenus.removeValue(forKey: menuID) != nil else { continue }
            self.requestDetailTasks.removeValue(forKey: menuID)?.cancel()
            self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
            submenu.delegate = nil
            (submenu as? TokenBarMenu)?.persistentActionDelegate = nil
        }
    }

    @objc private func sessionNoOp() {}

    @objc private func activityNoOp() {}

    @objc private func requestDetailNoOp() {}

    @objc private func showSettings() {
        if self.settingsWindowController == nil {
            self.settingsWindowController = SettingsWindowController(settings: self.settings)
        }
        self.settingsWindowController?.show()
    }

    @objc private func refreshNow() {
        Task { @MainActor [weak self] in
            await self?.model.refreshAll()
        }
    }

    @objc private func copySession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionSummary else { return }
        self.copyToPasteboard(session.tokscaleCopyText)
    }

    @objc private func copyRequest(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? RequestSummary else { return }
        self.copyToPasteboard(request.tokscaleCopyText)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct RequestDetailMenuContext {
    let request: RequestSummary
    let view: RequestDetailMenuView

    var cacheKey: String {
        self.request.tokscaleCopyText
    }
}

private extension Date {
    var menuClockText: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: self)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

private final class FixedMenuHostingView: NSHostingView<AnyView> {
    private var fixedSize: NSSize

    init(rootView: AnyView, width: CGFloat, height: CGFloat) {
        self.fixedSize = NSSize(width: width, height: height)
        super.init(rootView: rootView)
        self.frame = NSRect(origin: .zero, size: self.fixedSize)
    }

    required init(rootView: AnyView) {
        self.fixedSize = .zero
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        self.fixedSize
    }
}

enum StatusLabelRenderer {
    static func image(today: String, weekly: String) -> NSImage {
        let topLabel = "T" as NSString
        let bottomLabel = "W" as NSString
        let topValue = today as NSString
        let bottomValue = weekly as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]

        let labelWidth = ceil(max(
            topLabel.size(withAttributes: baseAttributes).width,
            bottomLabel.size(withAttributes: baseAttributes).width))
        let valueWidth = ceil(max(
            topValue.size(withAttributes: baseAttributes).width,
            bottomValue.size(withAttributes: baseAttributes).width))
        let columnGap: CGFloat = 2
        let contentWidth = labelWidth + columnGap + valueWidth
        let size = NSSize(width: max(30, contentWidth + 4), height: 20)
        let contentX = floor((size.width - contentWidth) / 2)

        let labelParagraph = NSMutableParagraphStyle()
        labelParagraph.alignment = .left
        var labelAttributes = baseAttributes
        labelAttributes[.paragraphStyle] = labelParagraph

        let valueParagraph = NSMutableParagraphStyle()
        valueParagraph.alignment = .right
        var valueAttributes = baseAttributes
        valueAttributes[.paragraphStyle] = valueParagraph

        let image = NSImage(size: size, flipped: false) { _ in
            let labelRect = NSRect(x: contentX, y: 0, width: labelWidth, height: 10)
            let valueRect = NSRect(
                x: contentX + labelWidth + columnGap,
                y: 0,
                width: valueWidth,
                height: 10)
            topLabel.draw(
                in: labelRect.offsetBy(dx: 0, dy: 10),
                withAttributes: labelAttributes)
            bottomLabel.draw(in: labelRect, withAttributes: labelAttributes)
            topValue.draw(
                in: valueRect.offsetBy(dx: 0, dy: 10),
                withAttributes: valueAttributes)
            bottomValue.draw(in: valueRect, withAttributes: valueAttributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
