import AppKit

/// Address/search field. Select-all on focus, like every browser.
final class OmniboxField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            currentEditor()?.selectAll(nil)
        }
        return accepted
    }
}
