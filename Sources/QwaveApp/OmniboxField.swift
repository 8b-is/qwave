import AppKit

/// Address/search field. Select-all on focus, like every browser.
final class OmniboxField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        font = .systemFont(ofSize: 13, weight: .regular)
        textColor = .labelColor
        toolTip = "Search or enter web address"
        setAccessibilityLabel("Address and Search Bar")
        setAccessibilityHelp("Type a URL or search query and press Return")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            currentEditor()?.selectAll(nil)
        }
        return accepted
    }
}
