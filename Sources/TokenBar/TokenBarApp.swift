import SwiftUI
import TokenBarCore

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(TokenBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            TokenBarSettingsView(
                settings: .shared,
                memoryTelemetry: self.appDelegate.memoryTelemetryController,
                activitySync: self.appDelegate.activitySyncController,
                syncNow: {
                    Task { @MainActor in
                        await self.appDelegate.refreshActivity()
                    }
                },
                testResetAnimation: {
                    self.appDelegate.testResetAnimation()
                })
        }
    }
}
