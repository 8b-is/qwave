import AppKit
import BrowserCore

/// The omnibox suggestions dropdown: a non-activating borderless panel with
/// a table, attached below the omnibox as a child window. It NEVER becomes
/// key — the omnibox keeps first responder and forwards arrow/return/escape
/// from its field editor (see BrowserWindowController's NSTextFieldDelegate).
@MainActor
final class OmniboxSuggestionsController: NSObject {
    var onCommit: ((OmniboxSuggestion) -> Void)?

    private(set) var suggestions: [OmniboxSuggestion] = []
    private(set) var highlightedIndex = -1

    private let panel: NSPanel
    private let table = NSTableView()
    private weak var host: NSWindow?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false

        let container = NSVisualEffectView()
        container.material = .menu
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ suggestions: [OmniboxSuggestion], below field: NSView) {
        guard !suggestions.isEmpty, let window = field.window else {
            hide()
            return
        }
        self.suggestions = suggestions
        highlightedIndex = -1
        table.reloadData()
        table.deselectAll(nil)

        let fieldFrameInWindow = field.convert(field.bounds, to: nil)
        let fieldFrameOnScreen = window.convertToScreen(fieldFrameInWindow)
        let height = CGFloat(suggestions.count) * (table.rowHeight + table.intercellSpacing.height) + 8
        let width = max(fieldFrameOnScreen.width, 420)
        panel.setFrame(
            NSRect(
                x: fieldFrameOnScreen.minX,
                y: fieldFrameOnScreen.minY - height - 4,
                width: width,
                height: height
            ),
            display: false
        )

        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
            host = window
        }
        panel.orderFront(nil)
    }

    func hide() {
        suggestions = []
        highlightedIndex = -1
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    /// Arrow-key movement forwarded from the omnibox's field editor.
    func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        highlightedIndex = (highlightedIndex + delta + count + 1) % (count + 1) - 1
        if highlightedIndex >= 0 {
            table.selectRowIndexes(IndexSet(integer: highlightedIndex), byExtendingSelection: false)
            table.scrollRowToVisible(highlightedIndex)
        } else {
            table.deselectAll(nil)
        }
    }

    var highlighted: OmniboxSuggestion? {
        suggestions.indices.contains(highlightedIndex) ? suggestions[highlightedIndex] : nil
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard suggestions.indices.contains(row) else { return }
        onCommit?(suggestions[row])
    }
}

extension OmniboxSuggestionsController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let suggestion = suggestions[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        let title = suggestion.title.isEmpty ? (suggestion.url.host ?? "") : suggestion.title
        let composed = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        )
        composed.append(NSAttributedString(
            string: "  \(suggestion.url.absoluteString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        text.attributedStringValue = composed
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool { true }
}
