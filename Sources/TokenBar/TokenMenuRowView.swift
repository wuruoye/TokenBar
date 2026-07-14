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
            self.costField,
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold))
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

        let leading: CGFloat = 16
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
        let measuredTrailingWidth = ceil(
            (self.trailingField.stringValue as NSString).size(withAttributes: [
                .font: self.trailingField.font ?? NSFont.systemFont(ofSize: 10.5),
            ]).width)
        let trailingWidth = min(112, measuredTrailingWidth + 6)
        let trailingX = availableRight - trailingWidth
        self.trailingField.frame = NSRect(
            x: trailingX,
            y: 22,
            width: trailingWidth,
            height: 16)

        let titleRight = self.trailingField.stringValue.isEmpty
            ? availableRight
            : trailingX - 8
        self.titleField.frame = NSRect(
            x: leading,
            y: 21,
            width: max(0, titleRight - leading),
            height: 17)
        let hasCost = !self.costField.stringValue.isEmpty
        let measuredCostWidth = hasCost
            ? ceil((self.costField.stringValue as NSString).size(withAttributes: [
                .font: self.costField.font ?? NSFont.systemFont(ofSize: 10.5),
            ]).width) + 8
            : 0
        let costWidth = min(72, measuredCostWidth)
        self.costField.frame = NSRect(
            x: leading,
            y: 4,
            width: costWidth,
            height: 15)
        let detailX = hasCost ? leading + costWidth - 6 : leading
        self.detailField.frame = NSRect(
            x: detailX,
            y: 4,
            width: max(0, availableRight - detailX),
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
        showsChevron: Bool)
    {
        self.titleField.stringValue = title
        self.costField.stringValue = cost ?? ""
        self.costField.isHidden = cost == nil
        self.detailField.stringValue = cost == nil ? detail : "· \(detail)"
        self.trailingField.stringValue = trailing
        self.showsChevron = showsChevron
        self.chevronView.isHidden = !showsChevron
        self.setAccessibilityLabel(title)
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
            self.costField.textColor = .selectedMenuItemTextColor
            self.detailField.textColor = .selectedMenuItemTextColor.withAlphaComponent(0.78)
            self.trailingField.textColor = .selectedMenuItemTextColor.withAlphaComponent(0.78)
            self.chevronView.contentTintColor = .selectedMenuItemTextColor
        } else {
            self.titleField.textColor = .labelColor
            self.costField.textColor = TokenBarVisualStyle.costAccentNSColor
            self.detailField.textColor = .secondaryLabelColor
            self.trailingField.textColor = .secondaryLabelColor
            self.chevronView.contentTintColor = .tertiaryLabelColor
        }
    }
}
