import AppKit
import Testing
@testable import TokenBar

@Suite(.serialized)
@MainActor
struct TokenBarMenuShortcutTests {
    @Test
    func `command R triggers persistent refresh without a native menu action`() throws {
        let delegate = RefreshDelegate()
        let menu = TokenBarMenu()
        menu.persistentActionDelegate = delegate

        #expect(menu.handlePersistentShortcut(try Self.keyEvent("r")))
        #expect(delegate.refreshCount == 1)
    }

    @Test
    func `modified and unrelated shortcuts remain available to AppKit`() throws {
        let delegate = RefreshDelegate()
        let menu = TokenBarMenu()
        menu.persistentActionDelegate = delegate

        #expect(!menu.handlePersistentShortcut(try Self.keyEvent("r", modifiers: [.command, .shift])))
        #expect(!menu.handlePersistentShortcut(try Self.keyEvent("x")))
        #expect(delegate.refreshCount == 0)
    }

    @Test
    func `key repeat is consumed without starting duplicate refreshes`() throws {
        let delegate = RefreshDelegate()
        let menu = TokenBarMenu()
        menu.persistentActionDelegate = delegate

        #expect(menu.handlePersistentShortcut(try Self.keyEvent("r", isRepeat: true)))
        #expect(delegate.refreshCount == 0)
    }

    private static func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = .command,
        isRepeat: Bool = false) throws -> NSEvent
    {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: characters == "r" ? 15 : 7))
    }
}

private final class RefreshDelegate: TokenBarMenuPersistentActionDelegate {
    private(set) var refreshCount = 0

    func performPersistentRefresh() {
        self.refreshCount += 1
    }
}
