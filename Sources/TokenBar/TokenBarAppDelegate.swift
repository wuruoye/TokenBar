import AppKit
import TokenBarCore
import TokenBarWidgetData

@MainActor
final class TokenBarAppDelegate: NSObject, NSApplicationDelegate {
    let memoryTelemetryController = MemoryTelemetryController()
    let activitySyncController = ActivitySyncController(
        settings: .shared,
        credentials: TokenBarAppDelegate.activitySyncCredentials())
    private let openAIPricingCatalog = OpenAIPricingCatalogUpdater()
    private let anthropicPricingCatalog = AnthropicPricingCatalogUpdater()
    private let openRouterPricingCatalog = OpenRouterPricingCatalogUpdater()
    private lazy var model: DashboardModel = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENBAR_DEMO_MODE"] == "1" {
            return DashboardModel(
                quotaService: DemoQuotaProvider(),
                additionalQuotaServices: [
                    DemoClaudeQuotaProvider(),
                    DemoGrokQuotaProvider(),
                    DemoAntigravityQuotaProvider(),
                ],
                activityService: DemoActivityProvider(),
                cache: nil)
        }
        #endif
        let memoryDatabaseURL = self.memoryTelemetryController.paths.databaseURL
        let localActivity = ActivityService(
            memoryDatabaseURLProvider: { [weak settings = self.settings] in
                await MainActor.run {
                    settings?.monitorsCodexMemory == true ? memoryDatabaseURL : nil
                }
            },
            openAIPricingCatalog: self.openAIPricingCatalog,
            anthropicPricingCatalog: self.anthropicPricingCatalog,
            openRouterPricingCatalog: self.openRouterPricingCatalog)
        let synchronizedActivity = SynchronizedActivityService(
            local: localActivity,
            configuration: { [weak activitySyncController = self.activitySyncController] in
                await activitySyncController?.configuration()
            },
            report: { [weak activitySyncController = self.activitySyncController] report in
                await activitySyncController?.accept(report)
            })
        return DashboardModel(
            quotaService: CodexQuotaService(),
            additionalQuotaServices: [
                ClaudeQuotaService(),
                GrokQuotaService(),
                AntigravityQuotaService(),
            ],
            activityService: synchronizedActivity,
            quotaCache: QuotaSnapshotCache(),
            weeklyQuotaUsageCache: WeeklyQuotaUsageCache())
    }()
    private let settings = TokenBarSettings.shared
    private let confettiOverlayController = ScreenConfettiOverlayController()
    private var requestDetailService: (any RequestDetailProviding)?
    private var statusController: TokenBarStatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var previewTask: Task<Void, Never>?
    private var pendingUnreadTaskLinks: [URL] = []

    /// Debug previews and demo runs are unsigned builds, so reading the real
    /// Keychain item would ask the user for their password.
    private static func activitySyncCredentials() -> any ActivitySyncCredentialStoring {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["TOKENBAR_DEMO_MODE"] == "1"
            || environment.keys.contains(where: { $0.hasPrefix("TOKENBAR_RENDER_") })
        {
            return DemoActivitySyncCredentialStore()
        }
        #endif
        return KeychainActivitySyncCredentialStore()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let previewPath = environment["TOKENBAR_RENDER_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.render(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_MENU_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderMenu(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_ROWS_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderRows(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_ACTIVITY_DETAIL_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderActivityDetail(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_MEMORY_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderMemory(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_REQUEST_DETAIL_PREVIEW"] {
            try? DemoPreviewRenderer.renderRequestDetail(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_SETTINGS_PREVIEW"] {
            try? DemoPreviewRenderer.renderSettings(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_DESKTOP_CARD_PREVIEW"] {
            try? DemoPreviewRenderer.renderDesktopCard(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_STATUS_PREVIEW"] {
            try? DemoPreviewRenderer.renderStatus(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        #endif
        if self.settings.monitorsCodexMemory {
            self.memoryTelemetryController.start()
        }
        #if DEBUG
        let requestDetailService: any RequestDetailProviding = environment["TOKENBAR_DEMO_MODE"] == "1"
            ? DemoRequestDetailProvider()
            : CodexRequestDetailService()
        #else
        let requestDetailService: any RequestDetailProviding = CodexRequestDetailService()
        #endif
        self.requestDetailService = requestDetailService
        let controller = TokenBarStatusItemController(
            model: self.model,
            settings: self.settings,
            memoryTelemetry: self.memoryTelemetryController,
            activitySync: self.activitySyncController,
            showSettings: { [weak self] in
                self?.showSettings()
            },
            requestDetailService: requestDetailService)
        self.statusController = controller
        self.application(NSApplication.shared, open: self.pendingUnreadTaskLinks)
        self.pendingUnreadTaskLinks = []
        self.model.quotaResetHandler = { [weak self] event in
            self?.handleQuotaReset(event)
        }
        controller.start()
    }

    /// The widget opens a clicked task through a `tokenbar://` link, which also
    /// launches TokenBar first when it is not running.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let statusController = self.statusController else {
            self.pendingUnreadTaskLinks += urls
            return
        }
        for url in urls {
            guard let link = UnreadTaskLink.parse(url) else { continue }
            statusController.openUnreadTask(
                platform: TokenPlatform(rawValue: link.platform),
                id: link.taskID)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.previewTask?.cancel()
        self.previewTask = nil
        self.memoryTelemetryController.stop()
        self.model.quotaResetHandler = nil
        self.model.stop()
        self.confettiOverlayController.dismiss()
        self.statusController?.tearDown()
        self.statusController = nil
        self.settingsWindowController?.close()
        self.settingsWindowController = nil
        self.requestDetailService = nil
    }

    private func showSettings() {
        if self.settingsWindowController == nil {
            self.settingsWindowController = SettingsWindowController(
                settings: self.settings,
                memoryTelemetry: self.memoryTelemetryController,
                activitySync: self.activitySyncController,
                syncNow: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.model.refreshActivity()
                    }
                },
                testResetAnimation: { [weak self] in
                    self?.testResetAnimation()
                })
        }
        self.settingsWindowController?.show()
    }

    func testResetAnimation() {
        let platform = self.statusController == nil ? TokenPlatform.codex : self.model.scope.platform
        let origin = self.statusController?.celebrationOriginPoint(for: platform)
        self.confettiOverlayController.play(originInScreen: origin)
    }

    private func handleQuotaReset(_ event: QuotaResetEvent) {
        guard self.settings.resetCelebration.includes(event.window) else { return }
        let origin = self.statusController?.celebrationOriginPoint(for: event.platform)
        self.confettiOverlayController.play(originInScreen: origin)
    }
}
