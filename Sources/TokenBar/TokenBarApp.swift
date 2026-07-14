import SwiftUI
import TokenBarCore

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(TokenBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            TokenBarSettingsView(settings: .shared)
        }
    }
}
