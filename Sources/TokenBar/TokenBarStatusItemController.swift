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

    private struct SessionHistoryKey: Hashable {
        let date: String
        let statisticsTimeZone: String
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
    private var submenuSessions: [ObjectIdentifier: SessionSummary] = [:]
    private var requestDetailMenus: [ObjectIdentifier: RequestDetailMenuContext] = [:]
    private var requestDetailTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var requestDetailCache: [String: RequestDetail] = [:]
    private var requestDetailCacheOrder: [String] = []
    private var sessionExpansionItem: NSMenuItem?
    private var sessionExpansionView: PersistentMenuActionRowView?
    private var sessionEmptyItem: NSMenuItem?
    private var activityDetailItem: NSMenuItem?
    private var activitySessionMenu: TokenBarMenu?
    private var activitySessionItems: [NSMenuItem] = []
    private var renderedActivitySessionProjection: RenderedSessionProjection?
    private var renderedActivitySessions: [SessionSummary] = []
    private var activitySessionExpansionItem: NSMenuItem?
    private var activitySessionExpansionView: PersistentMenuActionRowView?
    private var activitySessionEmptyItem: NSMenuItem?
    private var selectedSessionDate: String?
    private var sessionHistory: [SessionHistoryKey: [SessionSummary]] = [:]
    private var sessionHistoryErrors: [SessionHistoryKey: String] = [:]
    private var loadingSessionHistoryKey: SessionHistoryKey?
    private var sessionHistoryTask: Task<Void, Never>?
    private var memoryItem: NSMenuItem?
    private var overviewHost: FixedMenuHostingView?
    private var highlightedRows: [ObjectIdentifier: any TokenMenuHighlighting] = [:]
    private var showsAllSessions = false
    private var showsAllActivitySessions = false
    private var isRootMenuOpen = false
    private var startupTask: Task<Void, Never>?
    private var shortcutMonitor: MenuTrackingShortcutMonitor?
    private var syncSettingsSignature: SyncSettingsSignature
    private var monitorsCodexMemory: Bool

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
        self.monitorsCodexMemory = settings.monitorsCodexMemory
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
        self.sessionHistoryTask?.cancel()
        self.sessionHistoryTask = nil
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

        guard let session = self.submenuSessions[menuID] else { return }
        self.rebuildRequestMenu(menu, session: session)
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
            await self?.refreshAllIncludingSelectedSessions()
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
            _ = self.settings.usesWeekdayWeeklyPacing
            _ = self.settings.showsFullRequestContentOnHover
            _ = self.settings.monitorsCodexMemory
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
                if self.monitorsCodexMemory != self.settings.monitorsCodexMemory {
                    self.monitorsCodexMemory = self.settings.monitorsCodexMemory
                    if self.monitorsCodexMemory {
                        self.memoryTelemetry.start()
                    } else {
                        self.memoryTelemetry.stop()
                    }
                    Task { @MainActor [weak self] in
                        await self?.model.restartActivityRefresh()
                    }
                }
                self.model.updateBackgroundRefreshInterval(self.settings.backgroundRefreshDuration)
                if self.model.updateStatisticsTimeZone(self.settings.statisticsTimeZone) {
                    self.resetSessionHistory()
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
            self.updateActivitySessionProjectionAndVisibility(scope: scope)
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
        self.activityDetailItem = nil
        self.activitySessionMenu = nil
        self.activitySessionItems.removeAll()
        self.renderedActivitySessionProjection = nil
        self.renderedActivitySessions.removeAll()
        self.activitySessionExpansionItem = nil
        self.activitySessionExpansionView = nil
        self.activitySessionEmptyItem = nil
        self.memoryItem = nil
        self.overviewHost = nil
        self.submenuSessions.removeAll()

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
            usesWeekdayWeeklyPacing: self.settings.usesWeekdayWeeklyPacing,
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

        if self.settings.monitorsCodexMemory {
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
        }
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
        self.normalizeSelectedSessionDate()
        let menu = TokenBarMenu(title: "Activity Detail")
        menu.autoenablesItems = false
        menu.minimumWidth = ActivityDetailView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detail = ActivityDetailView(
            model: self.model,
            usesWeekdayWeeklyPacing: self.settings.usesWeekdayWeeklyPacing,
            accentColor: accentColor,
            initialSelectedDate: self.selectedSessionDate,
            onSelectDate: { [weak self] date in
                self?.selectActivityDate(date)
            })
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

        let sessionMenu = TokenBarMenu(title: self.activitySessionHeaderTitle)
        sessionMenu.autoenablesItems = false
        sessionMenu.minimumWidth = Self.menuWidth
        sessionMenu.delegate = self
        sessionMenu.persistentActionDelegate = self
        item.submenu = sessionMenu
        self.activityDetailItem = item
        self.activitySessionMenu = sessionMenu
        menu.addItem(item)
        self.addActivitySessionItems(to: sessionMenu)
        return menu
    }

    private func addActivitySessionItems(to menu: TokenBarMenu) {
        let empty = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        self.activitySessionEmptyItem = empty
        menu.addItem(empty)

        let maximumDailySessionCount = self.model.activitySnapshot?
            .sourceSnapshots
            .flatMap(\.days)
            .map(\.sessionCount)
            .max()
            ?? self.model.activitySnapshot?.days.map(\.sessionCount).max()
            ?? 0
        let slotCount = max(self.settings.recentSessionLimit, maximumDailySessionCount)
        for _ in 0 ..< slotCount {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.activitySessionItems.append(item)
            menu.addItem(item)
        }

        let expansion = PersistentMenuActionRowView(
            width: Self.menuWidth,
            title: "Show More…",
            systemImageName: "chevron.down",
            accessibilityHelp: "Expand or collapse sessions for the selected Activity date without closing the menu.")
        expansion.onActivate = { [weak self] in
            self?.toggleActivitySessionExpansion()
        }
        let expansionItem = NSMenuItem(title: "Show More…", action: nil, keyEquivalent: "")
        expansionItem.isEnabled = true
        expansionItem.isHidden = true
        expansionItem.view = expansion
        self.activitySessionExpansionItem = expansionItem
        self.activitySessionExpansionView = expansion
        menu.addItem(expansionItem)

        self.updateActivitySessionProjectionAndVisibility()
        self.loadSessionHistoryIfNeeded()
    }

    private func toggleActivitySessionExpansion() {
        guard let projection = self.renderedActivitySessionProjection else { return }
        self.showsAllActivitySessions.toggle()
        for (index, item) in self.activitySessionItems.enumerated() {
            item.isHidden = index >= projection.ids.count
                || (!self.showsAllActivitySessions && index >= projection.collapsedLimit)
        }
        let title = self.activitySessionExpansionTitle(projection: projection)
        self.activitySessionExpansionItem?.title = title
        self.activitySessionExpansionView?.configure(
            title: title,
            systemImageName: self.showsAllActivitySessions ? "chevron.up" : "chevron.down",
            accessibilityHelp: "Expand or collapse sessions for the selected Activity date without closing the menu.")
    }

    private func activitySessionExpansionTitle(
        projection: RenderedSessionProjection) -> String
    {
        if self.showsAllActivitySessions {
            return "Show First \(projection.collapsedLimit)"
        }
        return "Show \(max(0, projection.ids.count - projection.collapsedLimit)) More…"
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
        let isHidden = !self.settings.monitorsCodexMemory || !scope.supportsCodexMemory
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
        item.submenu = self.makeSessionSubmenu(title: "Session")
        return item
    }

    private func makeSessionSubmenu(title: String) -> TokenBarMenu {
        let submenu = TokenBarMenu(title: title)
        submenu.autoenablesItems = false
        submenu.minimumWidth = Self.menuWidth
        submenu.delegate = self
        submenu.persistentActionDelegate = self
        submenu.addItem(NSMenuItem(title: "Loading turns…", action: nil, keyEquivalent: ""))
        return submenu
    }

    private func bindSessionSubmenu(_ item: NSMenuItem, to session: SessionSummary) {
        let sessionID = session.platformScopedID
        var submenu = item.submenu
        if let current = submenu {
            let menuID = ObjectIdentifier(current)
            if let previousSession = self.submenuSessions[menuID],
               previousSession.platformScopedID != sessionID
            {
                self.discardRequestDetailMenus(in: current)
                self.submenuSessions.removeValue(forKey: menuID)
                self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
                current.delegate = nil
                (current as? TokenBarMenu)?.persistentActionDelegate = nil
                item.submenu = nil
                submenu = nil
            }
        }
        if submenu == nil {
            let replacement = self.makeSessionSubmenu(title: session.menuDisplayTitle)
            item.submenu = replacement
            submenu = replacement
        }
        guard let submenu else { return }
        submenu.title = session.menuDisplayTitle
        self.submenuSessions[ObjectIdentifier(submenu)] = session
    }

    private func unbindSessionSubmenu(_ item: NSMenuItem) {
        guard let submenu = item.submenu else { return }
        self.discardRequestDetailMenus(in: submenu)
        let menuID = ObjectIdentifier(submenu)
        self.submenuSessions.removeValue(forKey: menuID)
        self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
        submenu.delegate = nil
        (submenu as? TokenBarMenu)?.persistentActionDelegate = nil
        item.submenu = nil
    }

    private func configureSessionItem(_ item: NSMenuItem, session: SessionSummary) {
        let title = session.menuDisplayTitle
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
        self.updateActivitySessionProjectionAndVisibility()
        self.loadSessionHistoryIfNeeded()
    }

    private func updateSessionProjectionAndVisibility(scope: DashboardScope? = nil) {
        let scope = scope ?? self.model.scope
        self.renderedMenuScope = scope
        let visibleSessions = self.model.activitySnapshot?
            .scoped(to: scope.platform)
            .sessionMenu(limit: nil).visibleSessions ?? []
        self.ensureSessionItemCapacity(visibleSessions.count)
        let projection = RenderedSessionProjection(
            ids: visibleSessions.map(\.platformScopedID),
            collapsedLimit: self.settings.recentSessionLimit)
        self.renderedSessionProjection = projection
        let sessionsChanged = self.renderedSessions != visibleSessions

        for (index, item) in self.sessionItems.enumerated() {
            if sessionsChanged, index < visibleSessions.count {
                let session = visibleSessions[index]
                self.configureSessionItem(item, session: session)
                self.bindSessionSubmenu(item, to: session)
            } else if sessionsChanged {
                item.representedObject = nil
                self.unbindSessionSubmenu(item)
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
        self.sessionEmptyItem?.toolTip = nil
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

    private var availableSessionDates: [String] {
        Array(Set(self.model.activitySnapshot?.days.map(\.date) ?? [])).sorted()
    }

    private var latestSessionDate: String? {
        self.availableSessionDates.last
    }

    private var selectedSessionHistoryKey: SessionHistoryKey? {
        guard let selectedSessionDate else { return nil }
        return SessionHistoryKey(
            date: selectedSessionDate,
            statisticsTimeZone: self.settings.statisticsTimeZone.rawValue)
    }

    private var selectedSessionHistoryError: String? {
        guard let key = self.selectedSessionHistoryKey else { return nil }
        return self.sessionHistoryErrors[key]
    }

    private func normalizeSelectedSessionDate() {
        let dates = self.availableSessionDates
        guard !dates.isEmpty else {
            self.selectedSessionDate = nil
            return
        }
        if let selectedSessionDate, dates.contains(selectedSessionDate) {
            return
        }
        self.selectedSessionDate = dates.last
    }

    private func activitySessionsForSelectedDate(scope: DashboardScope) -> [SessionSummary] {
        guard let selectedSessionDate else { return [] }
        let sessions: [SessionSummary]
        if selectedSessionDate == self.latestSessionDate {
            sessions = self.model.activitySnapshot?.sessions ?? []
        } else if let key = self.selectedSessionHistoryKey {
            sessions = self.sessionHistory[key] ?? []
        } else {
            sessions = []
        }
        return sessions
            .filter { $0.platformID == scope.platform }
            .sorted {
                if $0.endedAtMs != $1.endedAtMs {
                    return $0.endedAtMs > $1.endedAtMs
                }
                return $0.platformScopedID < $1.platformScopedID
            }
    }

    private var activitySessionHeaderTitle: String {
        guard let selectedSessionDate else { return "Sessions" }
        if selectedSessionDate == self.latestSessionDate {
            return "Sessions · Today"
        }
        return "Sessions · \(selectedSessionDate)"
    }

    private func activitySessionEmptyTitle(scope: DashboardScope) -> String {
        guard let selectedSessionDate else {
            return "No \(scope.displayName) session dates available"
        }
        if self.loadingSessionHistoryKey == self.selectedSessionHistoryKey {
            return "Loading \(scope.displayName) sessions for \(selectedSessionDate)…"
        }
        if self.selectedSessionHistoryError != nil {
            return "Couldn’t load \(scope.displayName) sessions for \(selectedSessionDate)"
        }
        if selectedSessionDate == self.latestSessionDate {
            return "No \(scope.displayName) sessions today"
        }
        return "No \(scope.displayName) sessions on \(selectedSessionDate)"
    }

    private func updateActivitySessionProjectionAndVisibility(
        scope: DashboardScope? = nil)
    {
        guard self.activitySessionMenu != nil else { return }
        let scope = scope ?? self.model.scope
        self.normalizeSelectedSessionDate()
        let visibleSessions = self.activitySessionsForSelectedDate(scope: scope)
        self.ensureActivitySessionItemCapacity(visibleSessions.count)
        let projection = RenderedSessionProjection(
            ids: visibleSessions.map(\.platformScopedID),
            collapsedLimit: self.settings.recentSessionLimit)
        self.renderedActivitySessionProjection = projection
        let sessionsChanged = self.renderedActivitySessions != visibleSessions

        for (index, item) in self.activitySessionItems.enumerated() {
            if sessionsChanged, index < visibleSessions.count {
                let session = visibleSessions[index]
                self.configureSessionItem(item, session: session)
                self.bindSessionSubmenu(item, to: session)
            } else if sessionsChanged {
                item.representedObject = nil
                self.unbindSessionSubmenu(item)
            }
            let isHidden = index >= visibleSessions.count
                || (!self.showsAllActivitySessions && index >= projection.collapsedLimit)
            if item.isHidden != isHidden {
                item.isHidden = isHidden
            }
        }
        self.renderedActivitySessions = visibleSessions

        self.activitySessionMenu?.title = self.activitySessionHeaderTitle
        let hasSessions = !projection.ids.isEmpty
        let emptyTitle = self.activitySessionEmptyTitle(scope: scope)
        if self.activitySessionEmptyItem?.title != emptyTitle {
            self.activitySessionEmptyItem?.title = emptyTitle
        }
        self.activitySessionEmptyItem?.toolTip = self.selectedSessionHistoryError
        if self.activitySessionEmptyItem?.isHidden != hasSessions {
            self.activitySessionEmptyItem?.isHidden = hasSessions
        }

        let canExpand = projection.ids.count > projection.collapsedLimit
            && self.activitySessionItems.count > projection.collapsedLimit
        if self.activitySessionExpansionItem?.isHidden != !canExpand {
            self.activitySessionExpansionItem?.isHidden = !canExpand
        }
        guard canExpand else { return }
        let title = self.activitySessionExpansionTitle(projection: projection)
        self.activitySessionExpansionItem?.title = title
        self.activitySessionExpansionView?.configure(
            title: title,
            systemImageName: self.showsAllActivitySessions ? "chevron.up" : "chevron.down",
            accessibilityHelp: "Expand or collapse sessions for the selected Activity date without closing the menu.")
    }

    private func ensureSessionItemCapacity(_ count: Int) {
        guard self.sessionItems.count < count else { return }
        let insertionIndex = self.sessionExpansionItem
            .flatMap { self.rootMenu.items.firstIndex(of: $0) }
            ?? self.rootMenu.items.count
        for offset in 0 ..< (count - self.sessionItems.count) {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.sessionItems.append(item)
            self.rootMenu.insertItem(item, at: insertionIndex + offset)
        }
    }

    private func ensureActivitySessionItemCapacity(_ count: Int) {
        guard self.activitySessionItems.count < count,
              let menu = self.activitySessionMenu
        else {
            return
        }
        let insertionIndex = self.activitySessionExpansionItem
            .flatMap { menu.items.firstIndex(of: $0) }
            ?? menu.items.count
        for offset in 0 ..< (count - self.activitySessionItems.count) {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.activitySessionItems.append(item)
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    private func selectActivityDate(_ date: String) {
        guard self.availableSessionDates.contains(date) else { return }
        let didChange = self.selectedSessionDate != date
        if didChange {
            self.sessionHistoryTask?.cancel()
            self.sessionHistoryTask = nil
            self.loadingSessionHistoryKey = nil
            self.selectedSessionDate = date
            self.showsAllActivitySessions = false
        }
        self.updateActivitySessionProjectionAndVisibility()
        self.loadSessionHistoryIfNeeded(debounce: didChange)
    }

    private func loadSessionHistoryIfNeeded(
        force: Bool = false,
        debounce: Bool = false)
    {
        self.normalizeSelectedSessionDate()
        guard let selectedSessionDate,
              selectedSessionDate != self.latestSessionDate,
              let key = self.selectedSessionHistoryKey
        else {
            self.sessionHistoryTask?.cancel()
            self.sessionHistoryTask = nil
            self.loadingSessionHistoryKey = nil
            self.updateActivitySessionProjectionAndVisibility()
            return
        }
        if force {
            self.sessionHistoryTask?.cancel()
            self.sessionHistoryTask = nil
            self.loadingSessionHistoryKey = nil
            self.sessionHistory.removeValue(forKey: key)
        } else if self.sessionHistory[key] != nil {
            return
        }
        guard self.loadingSessionHistoryKey != key else { return }

        self.sessionHistoryTask?.cancel()
        self.sessionHistoryErrors.removeValue(forKey: key)
        self.loadingSessionHistoryKey = key
        self.updateActivitySessionProjectionAndVisibility()
        self.sessionHistoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(250))
                }
                let sessions = try await self.model.sessions(on: selectedSessionDate)
                try Task.checkCancellation()
                guard self.loadingSessionHistoryKey == key else { return }
                self.sessionHistory[key] = sessions
            } catch is CancellationError {
                return
            } catch {
                guard self.loadingSessionHistoryKey == key else { return }
                self.sessionHistoryErrors[key] = error.localizedDescription
            }
            guard self.loadingSessionHistoryKey == key else { return }
            self.loadingSessionHistoryKey = nil
            self.sessionHistoryTask = nil
            self.updateActivitySessionProjectionAndVisibility()
        }
    }

    private func resetSessionHistory() {
        self.sessionHistoryTask?.cancel()
        self.sessionHistoryTask = nil
        self.loadingSessionHistoryKey = nil
        self.sessionHistory.removeAll()
        self.sessionHistoryErrors.removeAll()
    }

    #if DEBUG
    func selectScopeForTesting(_ scope: DashboardScope) {
        self.selectScope(scope)
    }

    func firstSessionSubmenuForTesting() -> NSMenu? {
        self.sessionItems.first?.submenu
    }

    func selectActivityDateForTesting(_ date: String) {
        self.selectActivityDate(date)
    }

    func selectedSessionDateForTesting() -> String? {
        self.selectedSessionDate
    }

    func renderedActivitySessionIDsForTesting() -> [String] {
        self.renderedActivitySessions.map(\.platformScopedID)
    }

    func activitySessionMenuForTesting() -> NSMenu? {
        self.activitySessionMenu
    }

    func activityDetailDirectSessionCountForTesting() -> Int {
        self.activityDetailItem?.menu?.items.compactMap {
            $0.representedObject as? SessionSummary
        }.count ?? 0
    }

    func activityDetailShowsSessionMenuOnHoverForTesting() -> Bool {
        self.activityDetailItem?.submenu === self.activitySessionMenu
    }

    func firstActivitySessionSubmenuForTesting() -> NSMenu? {
        self.activitySessionItems.first?.submenu
    }

    func isLoadingSessionHistoryForTesting() -> Bool {
        self.loadingSessionHistoryKey != nil
    }
    #endif

    private func rebuildRequestMenu(_ menu: NSMenu, session: SessionSummary) {
        self.discardRequestDetailMenus(in: menu)
        menu.removeAllItems()

        menu.title = session.menuDisplayTitle
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
            await self?.refreshAllIncludingSelectedSessions()
        }
    }

    private func refreshAllIncludingSelectedSessions() async {
        await self.model.refreshAll()
        guard self.selectedSessionDate != self.latestSessionDate else { return }
        self.loadSessionHistoryIfNeeded(force: true)
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
