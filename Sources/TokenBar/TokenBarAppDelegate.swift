import AppKit
import TokenBarCore

@MainActor
final class TokenBarAppDelegate: NSObject, NSApplicationDelegate {
    private lazy var model: DashboardModel = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENBAR_DEMO_MODE"] == "1" {
            return DashboardModel(
                quotaService: DemoQuotaProvider(),
                activityService: DemoActivityProvider(),
                cache: nil)
        }
        #endif
        return DashboardModel()
    }()
    private var statusController: TokenBarStatusItemController?
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
        let controller = TokenBarStatusItemController(
            model: self.model,
            requestDetailService: requestDetailService)
        self.statusController = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.previewTask?.cancel()
        self.previewTask = nil
        self.model.stop()
        self.statusController?.tearDown()
        self.statusController = nil
    }
}
