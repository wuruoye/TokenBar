import AppKit

@MainActor
protocol TokenMenuHighlighting: AnyObject {
    func setMenuHighlighted(_ highlighted: Bool)
}

@MainActor
final class TokenMenuRowView: NSView, TokenMenuHighlighting {
    static let rowHeight: CGFloat = 42

    var onActivate: (() -> Void)?

    private let fixedWidth: CGFloat
    private let titleField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private let costField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let trailingField = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var showsChevron = false
    private var isMenuHighlighted = false
    private var isPressed = false

    init(width: CGFloat) {
        self.fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))

        self.autoresizingMask = [.width]
        self.configureLabel(
            self.titleField,
            font: .systemFont(ofSize: 12.5, weight: .medium))
        self.configureLabel(
            self.badgeField,
            font: .systemFont(ofSize: 8.5, weight: .bold))
        self.badgeField.alignment = .center
        self.badgeField.lineBreakMode = .byClipping
        self.badgeField.cell?.truncatesLastVisibleLine = false
        self.badgeField.drawsBackground = true
        self.badgeField.wantsLayer = true
        self.badgeField.layer?.cornerRadius = 4
        self.badgeField.layer?.borderWidth = 0.5
        self.badgeField.layer?.masksToBounds = true
        self.badgeField.isHidden = true
        self.configureLabel(
            self.costField,
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
        self.costField.alignment = .right
        self.costField.lineBreakMode = .byClipping
        self.costField.cell?.truncatesLastVisibleLine = false
        self.configureLabel(
            self.detailField,
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular))
        self.configureLabel(
            self.trailingField,
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular))
        self.trailingField.alignment = .right

        self.chevronView.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        self.chevronView.imageScaling = .scaleProportionallyDown

        self.addSubview(self.titleField)
        self.addSubview(self.badgeField)
        self.addSubview(self.costField)
        self.addSubview(self.detailField)
        self.addSubview(self.trailingField)
        self.addSubview(self.chevronView)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.menuItem)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.updateColors()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.onActivate != nil, self.bounds.contains(point) else {
            return super.hitTest(point)
        }
        return self
    }

    override func layout() {
        super.layout()

        // Label cells inset text by 2pt, so 14 lines text up with the dashboard's 16pt edge.
        let leading: CGFloat = 14
        let trailing: CGFloat = 14
        let chevronWidth: CGFloat = self.showsChevron ? 8 : 0
        let chevronGap: CGFloat = self.showsChevron ? 10 : 0
        let chevronX = self.bounds.width - trailing - chevronWidth
        self.chevronView.frame = NSRect(
            x: chevronX,
            y: 15,
            width: chevronWidth,
            height: 12)

        let availableRight = self.bounds.width - trailing - chevronWidth - chevronGap

        // Top line: title and badge, with the cost at the right edge.
        let hasCost = !self.costField.stringValue.isEmpty
        let costWidth = hasCost
            ? min(84, self.measuredWidth(self.costField) + 6)
            : 0
        self.costField.frame = NSRect(
            x: availableRight - costWidth,
            y: 21,
            width: costWidth,
            height: 17)
        let titleRight = hasCost ? availableRight - costWidth - 8 : availableRight
        let titleAreaWidth = max(0, titleRight - leading)
        if self.badgeField.isHidden {
            self.titleField.frame = NSRect(
                x: leading,
                y: 21,
                width: titleAreaWidth,
                height: 17)
            self.badgeField.frame = .zero
        } else {
            let badgeWidth = min(50, self.measuredWidth(self.badgeField) + 12)
            let badgeGap: CGFloat = 6
            let maxTitleWidth = max(0, titleAreaWidth - badgeWidth - badgeGap)
            let titleWidth = min(maxTitleWidth, self.measuredWidth(self.titleField) + 6)
            self.titleField.frame = NSRect(
                x: leading,
                y: 21,
                width: titleWidth,
                height: 17)
            self.badgeField.frame = NSRect(
                x: leading + titleWidth + badgeGap,
                y: 23,
                width: badgeWidth,
                height: 13)
        }

        // Bottom line: details, with the time at the right edge.
        let trailingWidth = self.trailingField.stringValue.isEmpty
            ? 0
            : min(112, self.measuredWidth(self.trailingField) + 6)
        self.trailingField.frame = NSRect(
            x: availableRight - trailingWidth,
            y: 4,
            width: trailingWidth,
            height: 15)
        let detailRight = trailingWidth > 0 ? availableRight - trailingWidth - 6 : availableRight
        self.detailField.frame = NSRect(
            x: leading,
            y: 4,
            width: max(0, detailRight - leading),
            height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard self.isMenuHighlighted else { return }

        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: self.bounds.insetBy(dx: 5, dy: 2),
            xRadius: 5,
            yRadius: 5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, self.onActivate != nil else {
            super.mouseDown(with: event)
            return
        }
        self.isPressed = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp, let onActivate = self.onActivate else {
            super.mouseUp(with: event)
            return
        }
        let point = self.convert(event.locationInWindow, from: nil)
        let shouldActivate = self.isPressed && self.bounds.contains(point)
        self.isPressed = false
        if shouldActivate {
            onActivate()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate = self.onActivate else {
            return super.accessibilityPerformPress()
        }
        onActivate()
        return true
    }

    func configure(
        title: String,
        cost: String?,
        detail: String,
        trailing: String,
        showsChevron: Bool,
        badge: String? = nil)
    {
        self.titleField.stringValue = title
        self.badgeField.stringValue = badge ?? ""
        self.badgeField.isHidden = badge == nil
        self.costField.stringValue = cost ?? ""
        self.costField.isHidden = cost == nil
        self.detailField.stringValue = detail
        self.trailingField.stringValue = trailing
        self.showsChevron = showsChevron
        self.chevronView.isHidden = !showsChevron
        self.setAccessibilityLabel([title, badge].compactMap { $0 }.joined(separator: ", "))
        let accessibleDetail = [cost, detail, trailing].compactMap { $0 }.joined(separator: ". ")
        self.setAccessibilityHelp(accessibleDetail)
        self.needsLayout = true
    }

    func setMenuHighlighted(_ highlighted: Bool) {
        guard self.isMenuHighlighted != highlighted else { return }
        self.isMenuHighlighted = highlighted
        self.updateColors()
        self.needsDisplay = true
    }

    private func measuredWidth(_ field: NSTextField) -> CGFloat {
        ceil((field.stringValue as NSString).size(withAttributes: [
            .font: field.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ]).width)
    }

    private func configureLabel(_ field: NSTextField, font: NSFont) {
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.truncatesLastVisibleLine = true
    }

    private func updateColors() {
        if self.isMenuHighlighted {
            self.titleField.textColor = .selectedMenuItemTextColor
            self.badgeField.textColor = .selectedMenuItemTextColor
            self.badgeField.backgroundColor = .selectedMenuItemTextColor.withAlphaComponent(0.16)
            self.badgeField.layer?.borderColor = NSColor.selectedMenuItemTextColor.withAlphaComponent(0.28).cgColor
            self.costField.textColor = .selectedMenuItemTextColor
            self.detailField.textColor = .selectedMenuItemTextColor.withAlphaComponent(0.78)
            self.trailingField.textColor = .selectedMenuItemTextColor.withAlphaComponent(0.78)
            self.chevronView.contentTintColor = .selectedMenuItemTextColor
        } else {
            self.titleField.textColor = .labelColor
            let badgeAccent = TokenBarVisualStyle.tierBadgeAccentNSColor
            self.badgeField.textColor = badgeAccent
            self.badgeField.backgroundColor = badgeAccent.withAlphaComponent(0.13)
            self.badgeField.layer?.borderColor = badgeAccent.withAlphaComponent(0.26).cgColor
            self.costField.textColor = .labelColor
            self.detailField.textColor = .secondaryLabelColor
            self.trailingField.textColor = .secondaryLabelColor
            self.chevronView.contentTintColor = .tertiaryLabelColor
        }
    }
}
