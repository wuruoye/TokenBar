import AppKit

@MainActor
final class RequestDetailMenuView: NSView {
    static let preferredWidth: CGFloat = 500
    static let preferredHeight: CGFloat = 360

    private let fixedSize: NSSize
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    init(
        width: CGFloat = RequestDetailMenuView.preferredWidth,
        height: CGFloat = RequestDetailMenuView.preferredHeight)
    {
        self.fixedSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(origin: .zero, size: self.fixedSize))

        self.autoresizingMask = [.width]
        self.scrollView.frame = self.bounds
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.borderType = .noBorder
        self.scrollView.drawsBackground = false
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.hasVerticalScroller = true
        self.scrollView.autohidesScrollers = true
        self.scrollView.scrollerStyle = .overlay

        self.textView.frame = self.bounds
        self.textView.autoresizingMask = [.width]
        self.textView.drawsBackground = false
        self.textView.isEditable = false
        self.textView.isSelectable = true
        self.textView.isRichText = true
        self.textView.importsGraphics = false
        self.textView.usesFindPanel = false
        self.textView.isHorizontallyResizable = false
        self.textView.isVerticallyResizable = true
        self.textView.minSize = NSSize(width: 0, height: self.fixedSize.height)
        self.textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        self.textView.textContainerInset = NSSize(width: 16, height: 14)
        self.textView.textContainer?.widthTracksTextView = true
        self.textView.textContainer?.containerSize = NSSize(
            width: self.fixedSize.width,
            height: .greatestFiniteMagnitude)

        self.scrollView.documentView = self.textView
        self.addSubview(self.scrollView)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel("Request Details")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        self.fixedSize
    }

    func showLoading(promptPreview: String?, outputPreview: String?) {
        self.updateContent(
            status: "Loading full content…",
            prompt: promptPreview,
            output: outputPreview)
    }

    func show(prompt: String?, output: String?) {
        self.updateContent(status: nil, prompt: prompt, output: output)
    }

    func showError(_ message: String, promptPreview: String?, outputPreview: String?) {
        self.updateContent(
            status: "Full content unavailable · \(message)",
            prompt: promptPreview,
            output: outputPreview)
    }

    private func updateContent(status: String?, prompt: String?, output: String?) {
        let content = NSMutableAttributedString()
        if let status {
            content.append(self.attributedStatus(status))
            content.append(NSAttributedString(string: "\n\n"))
        }
        content.append(self.attributedSection(title: "PROMPT", content: prompt))
        content.append(NSAttributedString(string: "\n\n"))
        content.append(self.attributedSection(title: "OUTPUT", content: output))

        self.textView.textStorage?.setAttributedString(content)
        self.textView.scrollToBeginningOfDocument(nil)
        self.setAccessibilityHelp(status ?? "Full prompt and output for this request")
    }

    private func attributedStatus(_ status: String) -> NSAttributedString {
        NSAttributedString(
            string: status,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    private func attributedSection(title: String, content: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.5,
            ])
        result.append(NSAttributedString(string: "\n"))

        let isPlaceholder = content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        let body = isPlaceholder ? "Not captured" : (content ?? "")
        result.append(NSAttributedString(
            string: body,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: isPlaceholder ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]))
        return result
    }
}
