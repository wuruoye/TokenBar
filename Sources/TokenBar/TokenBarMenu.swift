import AppKit

protocol TokenBarMenuPersistentActionDelegate: AnyObject {
    func performPersistentRefresh()
}

final class TokenBarMenu: NSMenu {
    weak var persistentActionDelegate: TokenBarMenuPersistentActionDelegate?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.isPersistentRefreshShortcut(event) else {
            return super.performKeyEquivalent(with: event)
        }
        if !event.isARepeat {
            self.persistentActionDelegate?.performPersistentRefresh()
        }
        return true
    }

    private static func isPersistentRefreshShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return relevantModifiers == .command
            && event.charactersIgnoringModifiers?.lowercased() == "r"
    }
}

@MainActor
final class PersistentMenuActionRowView: NSView, TokenMenuHighlighting {
    static let rowHeight: CGFloat = 26

    var onActivate: (() -> Void)?

    private let fixedWidth: CGFloat
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var isMenuHighlighted = false

    init(
        width: CGFloat,
        title: String,
        systemImageName: String,
        shortcut: String = "",
        accessibilityHelp: String)
    {
        self.fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))

        self.autoresizingMask = [.width]
        self.iconView.image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        self.iconView.imageScaling = .scaleProportionallyDown
        self.titleField.font = .menuFont(ofSize: 0)
        self.shortcutField.font = .menuFont(ofSize: 12)
        self.shortcutField.alignment = .right

        self.addSubview(self.iconView)
        self.addSubview(self.titleField)
        self.addSubview(self.shortcutField)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
        self.configure(
            title: title,
            systemImageName: systemImageName,
            shortcut: shortcut,
            accessibilityHelp: accessibilityHelp)

        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handleClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.fixedWidth, height: Self.rowHeight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self.bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        self.iconView.frame = NSRect(x: 16, y: 6, width: 14, height: 14)
        let hasShortcut = !self.shortcutField.stringValue.isEmpty
        self.shortcutField.isHidden = !hasShortcut
        self.shortcutField.frame = NSRect(x: self.bounds.width - 58, y: 5, width: 42, height: 16)
        self.titleField.frame = NSRect(
            x: 36,
            y: 4,
            width: self.bounds.width - (hasShortcut ? 102 : 52),
            height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard self.isMenuHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: self.bounds.insetBy(dx: 5, dy: 1),
            xRadius: 5,
            yRadius: 5).fill()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate = self.onActivate else { return false }
        onActivate()
        return true
    }

    func setMenuHighlighted(_ highlighted: Bool) {
        guard self.isMenuHighlighted != highlighted else { return }
        self.isMenuHighlighted = highlighted
        self.updateColors()
        self.needsDisplay = true
    }

    func configure(
        title: String,
        systemImageName: String,
        shortcut: String = "",
        accessibilityHelp: String)
    {
        self.titleField.stringValue = title
        self.shortcutField.stringValue = shortcut
        self.iconView.image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        self.setAccessibilityLabel(title)
        self.setAccessibilityHelp(accessibilityHelp)
        self.needsLayout = true
    }

    private func updateColors() {
        if self.isMenuHighlighted {
            self.iconView.contentTintColor = .selectedMenuItemTextColor
            self.titleField.textColor = .selectedMenuItemTextColor
            self.shortcutField.textColor = .selectedMenuItemTextColor.withAlphaComponent(0.78)
        } else {
            self.iconView.contentTintColor = .labelColor
            self.titleField.textColor = .labelColor
            self.shortcutField.textColor = .tertiaryLabelColor
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        self.onActivate?()
    }
}
