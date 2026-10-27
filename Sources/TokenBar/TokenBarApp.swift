import AppKit

/// TokenBar lives in the menu bar and opens Settings from its menu. A SwiftUI
/// `App` whose only scene is `Settings` opens that window at every launch.
@main
enum TokenBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = TokenBarAppDelegate()
        application.delegate = delegate
        application.mainMenu = self.mainMenu()
        application.run()
    }

    /// Never shown for a menu bar app, but it carries the shortcuts that
    /// Settings' text fields and window rely on.
    @MainActor
    private static func mainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit TokenBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
