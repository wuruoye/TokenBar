import AppKit
import SwiftUI
import TokenBarCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let loginItem: LoginItemController

    init(
        settings: TokenBarSettings = .shared,
        loginItem: LoginItemController = .shared,
        memoryTelemetry: MemoryTelemetryController? = nil,
        activitySync: ActivitySyncController? = nil,
        syncNow: @escaping () -> Void = {},
        testResetAnimation: @escaping () -> Void = {})
    {
        self.loginItem = loginItem
        let hostingController = NSHostingController(
            rootView: TokenBarSettingsView(
                settings: settings,
                loginItem: loginItem,
                memoryTelemetry: memoryTelemetry,
                activitySync: activitySync,
                syncNow: syncNow,
                testResetAnimation: testResetAnimation))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TokenBar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 820))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        self.loginItem.refresh()
        if self.window?.isVisible != true {
            self.window?.center()
        }
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
