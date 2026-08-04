import AppKit
import TokenBarCore

@MainActor
final class TokenBarAppDelegate: NSObject, NSApplicationDelegate {
    private lazy var model: DashboardModel = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENBAR_DEMO_MODE"] == "1" {
            return DashboardModel(
                quotaService: DemoQuotaProvider(),
                additionalQuotaServices: [DemoClaudeQuotaProvider(), DemoGrokQuotaProvider()],
                activityService: DemoActivityProvider(),
                cache: nil)
        }
        #endif
        return DashboardModel(
            quotaService: CodexQuotaService(),
            additionalQuotaServices: [ClaudeQuotaService(), GrokQuotaService()],
            quotaCache: QuotaSnapshotCache())
    }()
    private let settings = TokenBarSettings.shared
    private let confettiOverlayController = ScreenConfettiOverlayController()
    private var requestDetailService: (any RequestDetailProviding)?
    private var statusController: TokenBarStatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var previewTask: Task<Void, Never>?

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
        if let previewPath = environment["TOKENBAR_RENDER_STATUS_PREVIEW"] {
            try? DemoPreviewRenderer.renderStatus(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        #endif
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
            showSettings: { [weak self] in
                self?.showSettings()
            },
            requestDetailService: requestDetailService)
        self.statusController = controller
        self.model.quotaResetHandler = { [weak self] event in
            self?.handleQuotaReset(event)
        }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.previewTask?.cancel()
        self.previewTask = nil
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
