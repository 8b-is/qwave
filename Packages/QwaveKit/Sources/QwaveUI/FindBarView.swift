import AppKit

/// In-page find bar: search field + previous/next/done. Toggled by Cmd-F.
public final class FindBarView: NSView {
    public let searchField = NSSearchField()

    /// (query, forward)
    public var onSearch: ((String, Bool) -> Void)?
    public var onClose: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "Find in page"
        searchField.target = self
        searchField.action = #selector(searchCommitted(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let previousButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Find Previous") ?? NSImage(),
            target: self,
            action: #selector(findPreviousClicked(_:))
        )
        let nextButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Find Next") ?? NSImage(),
            target: self,
            action: #selector(findNextClicked(_:))
        )
        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked(_:)))
        for button in [previousButton, nextButton, doneButton] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        let stack = NSStackView(views: [searchField, previousButton, nextButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    @objc private func searchCommitted(_ sender: Any?) {
        let query = searchField.stringValue
        if query.isEmpty {
            onClose?()
        } else {
            onSearch?(query, true)
        }
    }

    @objc private func findNextClicked(_ sender: Any?) {
        onSearch?(searchField.stringValue, true)
    }

    @objc private func findPreviousClicked(_ sender: Any?) {
        onSearch?(searchField.stringValue, false)
    }

    @objc private func doneClicked(_ sender: Any?) {
        onClose?()
    }

    override public func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
