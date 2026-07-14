import AppKit
import SwiftUI
import TokenBarCore

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: TokenBarSettings = .shared) {
        let hostingController = NSHostingController(
            rootView: TokenBarSettingsView(settings: settings))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TokenBar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 390))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if self.window?.isVisible != true {
            self.window?.center()
        }
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
