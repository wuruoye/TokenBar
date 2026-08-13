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

    private struct SyncSettingsSignature: Equatable {
        let enabled: Bool
        let serverURL: String
        let deviceName: String
        let deviceID: String
        let credentialRevision: Int

        @MainActor
        init(_ settings: TokenBarSettings, activitySync: ActivitySyncController) {
            self.enabled = settings.syncEnabled
            self.serverURL = settings.syncServerURL
            self.deviceName = settings.syncDeviceName
            self.deviceID = settings.syncDeviceID
            self.credentialRevision = activitySync.configurationRevision
        }
    }

    private let model: DashboardModel
    private let settings: TokenBarSettings
    private let memoryTelemetry: MemoryTelemetryController
    private let activitySync: ActivitySyncController
    private let requestDetailService: any RequestDetailProviding
    private let sessionLauncher: SessionLauncher
    private let showSettingsAction: () -> Void
    private let statusItem: NSStatusItem
    private let rootMenu = TokenBarMenu()
    private var statusLabelLayout: StatusLabelLayout?
    private var nextMenuScopeOverride: DashboardScope?
    private var sessionItems: [NSMenuItem] = []
    private var renderedSessionProjection: RenderedSessionProjection?
    private var renderedSessions: [SessionSummary] = []
    private var renderedMenuScope: DashboardScope?
    private var submenuSessionIDs: [ObjectIdentifier: String] = [:]
    private var requestDetailMenus: [ObjectIdentifier: RequestDetailMenuContext] = [:]
    private var requestDetailTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var requestDetailCache: [String: RequestDetail] = [:]
    private var requestDetailCacheOrder: [String] = []
    private var sessionExpansionItem: NSMenuItem?
    private var sessionExpansionView: PersistentMenuActionRowView?
    private var sessionEmptyItem: NSMenuItem?
    private var memoryItem: NSMenuItem?
    private var overviewHost: FixedMenuHostingView?
    private var highlightedRows: [ObjectIdentifier: any TokenMenuHighlighting] = [:]
    private var showsAllSessions = false
    private var isRootMenuOpen = false
    private var startupTask: Task<Void, Never>?
    private var shortcutMonitor: MenuTrackingShortcutMonitor?
    private var syncSettingsSignature: SyncSettingsSignature

    init(
        model: DashboardModel,
        settings: TokenBarSettings = .shared,
        memoryTelemetry: MemoryTelemetryController,
        activitySync: ActivitySyncController,
        showSettings: @escaping () -> Void,
        requestDetailService: any RequestDetailProviding = CodexRequestDetailService(),
        sessionLauncher: SessionLauncher = SessionLauncher())
    {
        self.model = model
        self.settings = settings
        self.memoryTelemetry = memoryTelemetry
        self.activitySync = activitySync
        self.showSettingsAction = showSettings
        self.requestDetailService = requestDetailService
        self.sessionLauncher = sessionLauncher
        self.syncSettingsSignature = SyncSettingsSignature(
            settings,
            activitySync: activitySync)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.rootMenu.autoenablesItems = false
        self.rootMenu.minimumWidth = Self.menuWidth
        self.rootMenu.delegate = self
        self.rootMenu.persistentActionDelegate = self
        self.statusItem.menu = self.rootMenu
        self.configureStatusButton()
        self.model.updateBackgroundRefreshInterval(settings.backgroundRefreshDuration)
        self.model.updateStatisticsTimeZone(settings.statisticsTimeZone)
        self.model.updateQuotaRefreshEnabled(settings.showsClaude, for: .claude)
        self.model.updateQuotaRefreshEnabled(settings.showsGrok, for: .grok)
        self.rebuildRootMenu()
        self.observeModel()
        self.observeScope()
        self.observeSettings()
    }

    func start() {
        self.startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.start()
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            let demoScope = environment["TOKENBAR_DEMO_SCOPE"]
                .flatMap(DashboardScope.init(rawValue:)) ?? .codex
            if environment["TOKENBAR_DEMO_OPEN_MENU"] == "1" {
                self.nextMenuScopeOverride = demoScope
                try? await Task.sleep(for: .milliseconds(250))
                self.statusItem.button?.performClick(nil)
            }
            #endif
        }
    }

    func tearDown() {
        self.startupTask?.cancel()
        self.startupTask = nil
        self.removeShortcutMonitor()
        self.discardRequestDetailMenus(in: self.rootMenu)
        self.rootMenu.delegate = nil
        self.rootMenu.persistentActionDelegate = nil
        self.statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(self.statusItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.rootMenu {
            let requestedScope = self.nextMenuScopeOverride ?? self.scopeForCurrentStatusClick()
            self.nextMenuScopeOverride = nil
            if let requestedScope {
                self.model.scope = requestedScope
            }
            if !self.visibleScopes.contains(self.model.scope) {
                self.model.scope = .codex
            }
            self.rebuildRootMenu()
            return
        }

        let menuID = ObjectIdentifier(menu)
        if let context = self.requestDetailMenus[menuID] {
            self.prepareRequestDetailView(context)
            return
        }

        guard let sessionID = self.submenuSessionIDs[menuID] else { return }
        self.rebuildRequestMenu(menu, sessionScopedID: sessionID)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.rootMenu {
            self.isRootMenuOpen = true
            self.installShortcutMonitor()
            Task { @MainActor [weak self] in
                await self?.model.refreshAll(forceQuota: false)
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
            self.removeShortcutMonitor()
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

    private func installShortcutMonitor() {
        self.removeShortcutMonitor()
        let monitor = MenuTrackingShortcutMonitor(events: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isRootMenuOpen else { return false }
            return self.rootMenu.handlePersistentShortcut(event)
        }
        monitor.start()
        self.shortcutMonitor = monitor
    }

    private func removeShortcutMonitor() {
        self.shortcutMonitor?.stop()
        self.shortcutMonitor = nil
    }

    private func configureStatusButton() {
        guard let button = self.statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        self.updateStatusButton()
    }

    private var visibleScopes: [DashboardScope] {
        DashboardScope.visibleScopes(
            showsClaude: self.settings.showsClaude,
            showsGrok: self.settings.showsGrok)
    }

    private func updateStatusButton() {
        guard let button = self.statusItem.button else { return }
        let codex = self.statusValues(for: .codex)
        let claude = self.settings.showsClaude ? self.statusValues(for: .claude) : nil
        let grok = self.settings.showsGrok ? self.statusValues(for: .grok) : nil
        let layout = StatusLabelRenderer.layout(
            codexToday: codex.today,
            codexWeekly: codex.weekly,
            claudeToday: claude?.today,
            claudeWeekly: claude?.weekly,
            grokToday: grok?.today,
            grokWeekly: grok?.weekly)
        self.statusLabelLayout = layout
        button.image = layout.image

        var toolTips = [
            "Codex · Today: \(codex.today) tokens · Weekly: \(codex.weekly) left",
        ]
        var accessibilityLabels = [
            "Codex. Today, \(codex.today) tokens. Weekly quota, \(codex.weekly) remaining.",
        ]
        if let claude {
            toolTips.append(
                "Claude Code · Today: \(claude.today) tokens · Weekly: \(claude.weekly) left")
            accessibilityLabels.append(
                "Claude Code. Today, \(claude.today) tokens. Weekly quota, \(claude.weekly) remaining.")
        }
        if let grok {
            toolTips.append(
                "Grok Build · Today: \(grok.today) tokens · Weekly: \(grok.weekly) left")
            accessibilityLabels.append(
                "Grok Build. Today, \(grok.today) tokens. Weekly quota, \(grok.weekly) remaining.")
        }
        button.toolTip = toolTips.joined(separator: "\n")
        button.setAccessibilityLabel(accessibilityLabels.joined(separator: " "))
    }

    private func statusValues(for platform: TokenPlatform) -> (today: String, weekly: String) {
        let today = self.model.activitySnapshot?
            .scoped(to: platform).today.tokens.total.statusBarCompactCount ?? "—"
        let weekly = self.model.quotaState(for: platform).value?.weekly.map {
            "\(Int($0.remainingPercent.clamped(to: 0 ... 100).rounded()))%"
        } ?? "—"
        return (today, weekly)
    }

    func celebrationOriginPoint(for platform: TokenPlatform) -> CGPoint? {
        guard let button = self.statusItem.button,
              let window = button.window,
              let image = button.image,
              let layout = self.statusLabelLayout
        else {
            return nil
        }

        let imageX = layout.centerX(for: platform) ?? image.size.width / 2
        let imageMinX = button.bounds.midX - image.size.width / 2
        let buttonPoint = CGPoint(x: imageMinX + imageX, y: button.bounds.midY)
        let windowPoint = button.convert(buttonPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func scopeForCurrentStatusClick() -> DashboardScope? {
        guard self.visibleScopes.count > 1,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              let button = self.statusItem.button,
              let window = button.window,
              let image = button.image,
              let layout = self.statusLabelLayout
        else {
            return nil
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = button.convert(windowPoint, from: nil)
        guard button.bounds.contains(point) else { return nil }
        let imageMinX = button.bounds.midX - image.size.width / 2
        return layout.scope(at: point.x - imageMinX)
    }

    private func observeModel() {
        withObservationTracking {
            _ = self.model.quotas
            _ = self.model.activity
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeModel()
                self.modelDidChange()
            }
        }
    }

    private func observeScope() {
        withObservationTracking {
            _ = self.model.scope
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeScope()
                guard self.isRootMenuOpen else { return }
                self.updateMemoryVisibility(scope: self.model.scope)
                guard self.renderedMenuScope != self.model.scope else {
                    return
                }
                self.updateOverviewHeight()
                self.updateVisibleSessionItems()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = self.settings.theme
            _ = self.settings.recentSessionCount
            _ = self.settings.refreshInterval
            _ = self.settings.statisticsTimeZone
            _ = self.settings.showsClaude
            _ = self.settings.showsGrok
            _ = self.settings.showsFullRequestContentOnHover
            _ = self.settings.syncEnabled
            _ = self.settings.syncServerURL
            _ = self.settings.syncDeviceName
            _ = self.settings.syncDeviceID
            _ = self.activitySync.configurationRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSettings()
                let syncSettingsSignature = SyncSettingsSignature(
                    self.settings,
                    activitySync: self.activitySync)
                if syncSettingsSignature != self.syncSettingsSignature {
                    self.syncSettingsSignature = syncSettingsSignature
                    Task { @MainActor [weak self] in
                        await self?.model.restartActivityRefresh()
                    }
                }
                self.model.updateBackgroundRefreshInterval(self.settings.backgroundRefreshDuration)
                if self.model.updateStatisticsTimeZone(self.settings.statisticsTimeZone) {
                    Task { @MainActor [weak self] in
                        await self?.model.refreshActivity()
                    }
                }
                let claudeQuotaSettingChanged = self.model.updateQuotaRefreshEnabled(
                    self.settings.showsClaude,
                    for: .claude)
                if claudeQuotaSettingChanged, self.settings.showsClaude {
                    Task { @MainActor [weak self] in
                        await self?.model.refreshQuota(for: .claude)
                    }
                }
                let grokQuotaSettingChanged = self.model.updateQuotaRefreshEnabled(
                    self.settings.showsGrok,
                    for: .grok)
                if grokQuotaSettingChanged, self.settings.showsGrok {
                    Task { @MainActor [weak self] in
                        await self?.model.refreshQuota(for: .grok)
                    }
                }
                if !self.visibleScopes.contains(self.model.scope) {
                    self.model.scope = .codex
                }
                self.updateStatusButton()
                if self.isRootMenuOpen {
                    self.rebuildRootMenu()
                }
            }
        }
    }

    private func modelDidChange() {
        self.updateStatusButton()
        guard self.isRootMenuOpen else { return }
        self.updateOverviewHeight()
        self.updateVisibleSessionItems()
    }

    private func updateOverviewHeight() {
        let quota = self.model.quotaState(for: self.model.scope.platform).value
        self.overviewHost?.updateHeight(DashboardOverviewView.contentHeight(quota: quota))
    }

    private func selectScope(_ scope: DashboardScope) {
        guard scope != self.model.scope else { return }
        let window = self.overviewHost?.window
        window?.disableScreenUpdatesUntilFlush()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            let quota = self.model.quotaState(for: scope.platform).value
            self.overviewHost?.updateHeight(DashboardOverviewView.contentHeight(quota: quota))
            self.updateMemoryVisibility(scope: scope)
            self.updateSessionProjectionAndVisibility(scope: scope)
            self.model.scope = scope
            window?.layoutIfNeeded()
        }
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
        self.renderedSessions.removeAll()
        self.renderedMenuScope = nil
        self.sessionExpansionItem = nil
        self.sessionExpansionView = nil
        self.sessionEmptyItem = nil
        self.memoryItem = nil
        self.overviewHost = nil
        self.submenuSessionIDs.removeAll()

        let accentColor = self.settings.theme.color
        let headerHeight = DashboardOverviewView.headerHeight(
            showsClaude: self.settings.showsClaude,
            showsGrok: self.settings.showsGrok)
        let header = DashboardHeaderView(
            model: self.model,
            showsClaude: self.settings.showsClaude,
            showsGrok: self.settings.showsGrok,
            accentColor: accentColor,
            onSelectScope: { [weak self] scope in
                self?.selectScope(scope)
            })
            .frame(
                width: Self.menuWidth,
                height: headerHeight,
                alignment: .top)
        let headerHost = FixedMenuHostingView(
            rootView: AnyView(header),
            width: Self.menuWidth,
            height: headerHeight)
        let headerItem = NSMenuItem()
        headerItem.view = headerHost
        headerItem.isEnabled = true
        self.rootMenu.addItem(headerItem)

        let quota = self.model.quotaState(for: self.model.scope.platform).value
        let overviewHeight = DashboardOverviewView.contentHeight(quota: quota)
        let overview = DashboardOverviewContentView(
            model: self.model,
            accentColor: accentColor)
            .frame(width: Self.menuWidth, alignment: .top)
        let overviewHost = FixedMenuHostingView(
            rootView: AnyView(overview),
            width: Self.menuWidth,
            height: overviewHeight)
        self.overviewHost = overviewHost
        let overviewItem = NSMenuItem()
        overviewItem.view = overviewHost
        overviewItem.isEnabled = true
        self.rootMenu.addItem(overviewItem)

        let activityHeight = ActivitySummarySection.preferredHeight + 1
        let activity = MenuActivitySummaryView(
            model: self.model,
            accentColor: accentColor)
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

        let memoryHeight = MemorySummarySection.preferredHeight + 1
        let memory = MenuMemorySummaryView(
            model: self.model,
            telemetry: self.memoryTelemetry,
            accentColor: accentColor)
            .allowsHitTesting(false)
            .frame(width: Self.menuWidth, height: memoryHeight, alignment: .top)
        let memoryHost = FixedMenuHostingView(
            rootView: AnyView(memory),
            width: Self.menuWidth,
            height: memoryHeight)
        let memoryItem = NSMenuItem(
            title: "Codex Memory",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        memoryItem.target = self
        memoryItem.isEnabled = true
        memoryItem.view = memoryHost
        memoryItem.submenu = self.makeMemoryDetailMenu(accentColor: accentColor)
        memoryItem.isHidden = !self.model.scope.supportsCodexMemory
        self.memoryItem = memoryItem
        self.rootMenu.addItem(memoryItem)
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
        let sessions = self.model.activitySnapshot?
            .sessionMenu(limit: nil).visibleSessions ?? []
        let empty = NSMenuItem(title: "No sessions today", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        empty.isHidden = !sessions.isEmpty
        self.sessionEmptyItem = empty
        self.rootMenu.addItem(empty)

        let maximumPlatformSessionCount = Dictionary(grouping: sessions, by: \.platformID)
            .values
            .map(\.count)
            .max() ?? 0
        let slotCount = max(self.settings.recentSessionLimit, maximumPlatformSessionCount)
        for _ in 0 ..< slotCount {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.sessionItems.append(item)
            self.rootMenu.addItem(item)
        }

        let expansion = PersistentMenuActionRowView(
            width: Self.menuWidth,
            title: "Show More…",
            systemImageName: "chevron.down",
            accessibilityHelp: "Expand or collapse recent sessions without closing the menu.")
        expansion.onActivate = { [weak self] in
            self?.toggleSessionExpansion()
        }
        let expansionItem = NSMenuItem(title: "Show More…", action: nil, keyEquivalent: "")
        expansionItem.isEnabled = true
        expansionItem.isHidden = true
        expansionItem.view = expansion
        self.sessionExpansionItem = expansionItem
        self.sessionExpansionView = expansion
        self.rootMenu.addItem(expansionItem)
        self.updateSessionProjectionAndVisibility()
    }

    private func toggleSessionExpansion() {
        guard let projection = self.renderedSessionProjection else { return }
        self.showsAllSessions.toggle()
        for (index, item) in self.sessionItems.enumerated() {
            item.isHidden = index >= projection.ids.count
                || (!self.showsAllSessions && index >= projection.collapsedLimit)
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

    private func makeMemoryDetailMenu(accentColor: Color) -> TokenBarMenu {
        let menu = TokenBarMenu(title: "Codex Memory")
        menu.autoenablesItems = false
        menu.minimumWidth = MemoryDetailView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detail = MemoryDetailView(
            model: self.model,
            telemetry: self.memoryTelemetry,
            accentColor: accentColor)
            .frame(
                width: MemoryDetailView.preferredWidth,
                height: MemoryDetailView.preferredHeight,
                alignment: .topLeading)
        let host = FixedMenuHostingView(
            rootView: AnyView(detail),
            width: MemoryDetailView.preferredWidth,
            height: MemoryDetailView.preferredHeight)
        let item = NSMenuItem(
            title: "Codex Memory",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.view = host
        menu.addItem(item)
        return menu
    }

    private func updateMemoryVisibility(scope: DashboardScope) {
        let isHidden = !scope.supportsCodexMemory
        if self.memoryItem?.isHidden != isHidden {
            self.memoryItem?.isHidden = isHidden
        }
    }

    private func makeSessionItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Session",
            action: #selector(self.openSession(_:)),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.view = TokenMenuRowView(width: Self.menuWidth)

        let submenu = TokenBarMenu(title: "Session")
        submenu.autoenablesItems = false
        submenu.minimumWidth = Self.menuWidth
        submenu.delegate = self
        submenu.persistentActionDelegate = self
        submenu.addItem(NSMenuItem(title: "Loading turns…", action: nil, keyEquivalent: ""))
        item.submenu = submenu
        return item
    }

    private func configureSessionItem(_ item: NSMenuItem, session: SessionSummary) {
        let title = session.menuTitle
        let detail = session.menuDetail
        let time = Date(timeIntervalSince1970: Double(session.endedAtMs) / 1000).menuClockText
        let isRemote = session.isSynchronizedRemote
        item.representedObject = session
        item.action = isRemote ? nil : #selector(self.openSession(_:))

        let row = (item.view as? TokenMenuRowView) ?? TokenMenuRowView(width: Self.menuWidth)
        row.configure(
            title: title,
            cost: session.menuCostText,
            detail: detail,
            trailing: time,
            showsChevron: true,
            badge: session.menuServiceTierBadge)
        row.toolTip = isRemote
            ? "\(title)\n\(detail)\nEnded \(time)\nSynced session (read-only) · Hover to inspect turns"
            : "\(title)\n\(detail)\nEnded \(time)\nClick to open in "
                + "\(session.platformID.displayName) · Hover to inspect turns"
        row.onActivate = isRemote ? nil : { [weak self, weak item] in
            guard let self else { return }
            item?.menu?.cancelTracking()
            self.rootMenu.cancelTracking()
            self.openSessionInApp(session)
        }
        item.view = row
    }

    private func updateVisibleSessionItems() {
        self.updateSessionProjectionAndVisibility()
    }

    private func updateSessionProjectionAndVisibility(scope: DashboardScope? = nil) {
        let scope = scope ?? self.model.scope
        self.renderedMenuScope = scope
        let visibleSessions = self.model.activitySnapshot?
            .scoped(to: scope.platform)
            .sessionMenu(limit: nil).visibleSessions ?? []
        let projection = RenderedSessionProjection(
            ids: visibleSessions.map(\.platformScopedID),
            collapsedLimit: self.settings.recentSessionLimit)
        self.renderedSessionProjection = projection
        let sessionsChanged = self.renderedSessions != visibleSessions

        for (index, item) in self.sessionItems.enumerated() {
            if sessionsChanged, index < visibleSessions.count {
                let session = visibleSessions[index]
                self.configureSessionItem(item, session: session)
                if let submenu = item.submenu {
                    if submenu.title != session.menuTitle {
                        submenu.title = session.menuTitle
                    }
                    self.submenuSessionIDs[ObjectIdentifier(submenu)] = session.platformScopedID
                }
            } else if sessionsChanged {
                item.representedObject = nil
                if let submenu = item.submenu {
                    self.submenuSessionIDs.removeValue(forKey: ObjectIdentifier(submenu))
                }
            }
            let isHidden = index >= visibleSessions.count
                || (!self.showsAllSessions && index >= projection.collapsedLimit)
            if item.isHidden != isHidden {
                item.isHidden = isHidden
            }
        }
        self.renderedSessions = visibleSessions

        let hasSessions = !projection.ids.isEmpty
        let emptyTitle = "No \(scope.displayName) sessions today"
        if self.sessionEmptyItem?.title != emptyTitle {
            self.sessionEmptyItem?.title = emptyTitle
        }
        if self.sessionEmptyItem?.isHidden != hasSessions {
            self.sessionEmptyItem?.isHidden = hasSessions
        }

        let canExpand = projection.ids.count > projection.collapsedLimit
            && self.sessionItems.count > projection.collapsedLimit
        if self.sessionExpansionItem?.isHidden != !canExpand {
            self.sessionExpansionItem?.isHidden = !canExpand
        }
        guard canExpand else { return }
        let title = self.sessionExpansionTitle(projection: projection)
        self.sessionExpansionItem?.title = title
        self.sessionExpansionView?.configure(
            title: title,
            systemImageName: self.showsAllSessions ? "chevron.up" : "chevron.down",
            accessibilityHelp: "Expand or collapse recent sessions without closing the menu.")
    }

    private func rebuildRequestMenu(_ menu: NSMenu, sessionScopedID: String) {
        self.discardRequestDetailMenus(in: menu)
        menu.removeAllItems()
        guard let session = self.model.activitySnapshot?.sessions
            .first(where: { $0.platformScopedID == sessionScopedID })
        else {
            let unavailable = NSMenuItem(title: "Session is no longer available", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
            return
        }

        menu.title = session.menuTitle
        menu.minimumWidth = Self.menuWidth
        menu.addItem(.sectionHeader(title: "Turns"))
        if session.isSynchronizedRemote {
            let readOnly = NSMenuItem(
                title: "Synced session · Read-only on this Mac",
                action: nil,
                keyEquivalent: "")
            readOnly.isEnabled = false
            menu.addItem(readOnly)
        }
        let copySession = NSMenuItem(
            title: "Copy Session",
            action: #selector(self.copySession(_:)),
            keyEquivalent: "")
        copySession.target = self
        copySession.representedObject = session
        copySession.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: nil)
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
        let isRemote = turn.isSynchronizedRemote

        let row = TokenMenuRowView(width: Self.menuWidth)
        row.configure(
            title: turn.menuRowTitle,
            cost: turn.menuCostText,
            detail: turn.menuDetail,
            trailing: "\(turn.startedAt.menuClockText) · \(turn.menuDurationText)",
            showsChevron: physicalRequests.count > 1
                || (self.settings.showsFullRequestContentOnHover && !isRemote),
            badge: turn.menuServiceTierBadge)
        item.view = row

        if physicalRequests.count > 1 {
            item.toolTip = isRemote
                ? "Synced turn (read-only) · Hover to inspect contributing requests"
                : "Hover to inspect the requests contributing to this turn"
            item.submenu = self.makeAgentRequestMenu(
                title: turn.menuTitle,
                requests: physicalRequests)
        } else if let request = physicalRequests.first {
            if isRemote {
                item.toolTip = "Synced request details are not uploaded"
            } else {
                self.configureCopyInteraction(item: item, row: row, request: request)
            }
            if self.settings.showsFullRequestContentOnHover, !isRemote {
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
                detail: request.menuDetail,
                trailing: "\(request.startedAt.menuClockText) · \(request.menuDurationText)",
                showsChevron: self.settings.showsFullRequestContentOnHover
                    && !request.isSynchronizedRemote,
                badge: request.menuServiceTierBadge)
            item.view = row
            if request.isSynchronizedRemote {
                item.toolTip = "Synced request details are not uploaded"
            } else {
                self.configureCopyInteraction(item: item, row: row, request: request)
            }
            if self.settings.showsFullRequestContentOnHover,
               !request.isSynchronizedRemote
            {
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

    @objc private func activityNoOp() {}

    @objc private func requestDetailNoOp() {}

    @objc private func showSettings() {
        self.showSettingsAction()
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

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionSummary else { return }
        self.openSessionInApp(session)
    }

    private func openSessionInApp(_ session: SessionSummary) {
        do {
            try self.sessionLauncher.open(session)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Open Session"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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

    func updateHeight(_ height: CGFloat) {
        guard self.fixedSize.height != height else { return }
        self.fixedSize.height = height
        self.setFrameSize(self.fixedSize)
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
        self.superview?.needsLayout = true
    }

}

private struct MenuActivitySummaryView: View {
    @Bindable var model: DashboardModel
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            ActivitySummarySection(
                state: self.model.visibleActivity,
                accentColor: self.accentColor,
                showsChevron: true)
        }
    }
}

private struct MenuMemorySummaryView: View {
    @Bindable var model: DashboardModel
    @Bindable var telemetry: MemoryTelemetryController
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            MemorySummarySection(
                usage: self.model.visibleActivitySnapshot?.memoryUsage,
                receiverState: self.telemetry.receiverState,
                configurationState: self.telemetry.configurationState,
                accentColor: self.accentColor)
        }
    }
}

@MainActor
struct StatusLabelLayout {
    struct Region {
        let scope: DashboardScope
        let startX: CGFloat
        let centerX: CGFloat
    }

    let image: NSImage
    let regions: [Region]

    func scope(at imageX: CGFloat) -> DashboardScope {
        self.regions.last(where: { imageX >= $0.startX })?.scope ?? .codex
    }

    func centerX(for platform: TokenPlatform) -> CGFloat? {
        self.regions.first(where: { $0.scope.platform == platform })?.centerX
    }
}

@MainActor
enum StatusLabelRenderer {
    static func layout(
        codexToday: String,
        codexWeekly: String,
        claudeToday: String? = nil,
        claudeWeekly: String? = nil,
        grokToday: String? = nil,
        grokWeekly: String? = nil) -> StatusLabelLayout
    {
        var values: [(scope: DashboardScope, today: String, weekly: String)] = [
            (.codex, codexToday, codexWeekly),
        ]
        if let claudeToday, let claudeWeekly {
            values.append((.claude, claudeToday, claudeWeekly))
        }
        if let grokToday, let grokWeekly {
            values.append((.grok, grokToday, grokWeekly))
        }
        let images = values.map { value in
            self.image(
                platform: value.scope.platform,
                today: value.today,
                weekly: value.weekly)
        }
        let gap: CGFloat = 7
        let size = NSSize(
            width: images.map(\.size.width).reduce(0, +)
                + gap * CGFloat(max(0, images.count - 1)),
            height: images.map(\.size.height).max() ?? 20)
        let image = NSImage(size: size, flipped: false) { _ in
            var imageX: CGFloat = 0
            for providerImage in images {
                providerImage.draw(
                    in: NSRect(
                        x: imageX,
                        y: floor((size.height - providerImage.size.height) / 2),
                        width: providerImage.size.width,
                        height: providerImage.size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
                imageX += providerImage.size.width + gap
            }
            return true
        }
        image.isTemplate = true
        var regions: [StatusLabelLayout.Region] = []
        var imageX: CGFloat = 0
        for (index, value) in values.enumerated() {
            let providerImage = images[index]
            regions.append(StatusLabelLayout.Region(
                scope: value.scope,
                startX: index == 0 ? 0 : imageX - gap / 2,
                centerX: imageX + providerImage.size.width / 2))
            imageX += providerImage.size.width + gap
        }
        return StatusLabelLayout(image: image, regions: regions)
    }

    static func image(
        platform: TokenPlatform? = nil,
        today: String,
        weekly: String) -> NSImage
    {
        let topValue = today as NSString
        let bottomValue = weekly as NSString
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.black,
        ]

        let valueWidth = ceil(max(
            topValue.size(withAttributes: baseAttributes).width,
            bottomValue.size(withAttributes: baseAttributes).width))
        let platformIcon = platform.flatMap { platform in
            PlatformStatusIcon.image(for: platform)
        }
        let iconWidth: CGFloat = platformIcon == nil ? 0 : 15
        let iconGap: CGFloat = platformIcon == nil ? 0 : 4
        let contentWidth = iconWidth + iconGap + valueWidth
        let size = NSSize(width: max(30, contentWidth + 4), height: 20)
        let contentX = floor((size.width - contentWidth) / 2)
        let textX = contentX + iconWidth + iconGap

        let valueParagraph = NSMutableParagraphStyle()
        valueParagraph.alignment = .left
        var valueAttributes = baseAttributes
        valueAttributes[.paragraphStyle] = valueParagraph

        let image = NSImage(size: size, flipped: false) { _ in
            if let platformIcon {
                platformIcon.draw(
                    in: NSRect(
                        x: contentX,
                        y: floor((size.height - iconWidth) / 2),
                        width: iconWidth,
                        height: iconWidth),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1)
            }
            let valueRect = NSRect(x: textX, y: 0, width: valueWidth, height: 10)
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

@MainActor
enum PlatformStatusIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [TokenPlatform: NSImage] = [:]

    private static let resourceBundle: Bundle = {
        if let bundleURL = Bundle.main.url(
            forResource: "TokenBar_TokenBar",
            withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        return Bundle.module
    }()

    static func image(for platform: TokenPlatform) -> NSImage? {
        if let cached = self.cache[platform] {
            return cached
        }
        if platform == .grok,
           let symbol = NSImage(
               systemSymbolName: "xmark",
               accessibilityDescription: "Grok")?
               .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
        {
            symbol.size = self.size
            symbol.isTemplate = true
            self.cache[platform] = symbol
            return symbol
        }
        guard let resourceName = self.resourceName(for: platform),
              let url = self.resourceBundle.url(
                  forResource: resourceName,
                  withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.size = self.size
        image.isTemplate = true
        self.cache[platform] = image
        return image
    }

    private static func resourceName(for platform: TokenPlatform) -> String? {
        switch platform {
        case .codex: "ProviderIcon-codex"
        case .claude: "ProviderIcon-claude"
        default: nil
        }
    }
}
