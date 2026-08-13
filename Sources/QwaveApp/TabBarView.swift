import AppKit
import BrowserCore

struct TabDisplayModel: Equatable {
    let id: UUID
    let title: String
    let isPinned: Bool
    let isHibernated: Bool
    let isLoading: Bool
    let isEphemeral: Bool
    let containerColorHex: String?
    let favicon: NSImage?
}

/// Custom tab strip: scrollable row of tab items plus a new-tab button whose
/// context menu offers container/ephemeral tabs.
final class TabBarView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewContainerTab: ((UUID) -> Void)?
    /// Drag-reorder commit: (fromIndex, toIndex) in the model's terms.
    var onReorder: ((Int, Int) -> Void)?
    /// Supplies (id, name) pairs for the new-tab context menu.
    var containerProvider: (() -> [(UUID, String)])?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let newTabButton = NSButton()

    private var models: [TabDisplayModel] = []
    private var selectedID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = stack
        scrollView.contentView = clipView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTabButton.bezelStyle = .texturedRounded
        newTabButton.isBordered = false
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked(_:))
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.menu = nil
        addSubview(newTabButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 26),
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
        ])
    }

    @objc private func newTabClicked(_ sender: NSButton) {
        guard let event = NSApp.currentEvent else {
            onNewTab?()
            return
        }
        if event.modifierFlags.contains(.option) || event.type == .rightMouseUp {
            showNewTabMenu(under: sender)
        } else {
            onNewTab?()
        }
    }

    private func showNewTabMenu(under button: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Tab", action: #selector(menuNewTab(_:)), keyEquivalent: "").target = self
        let ephemeralItem = menu.addItem(withTitle: "New Ephemeral Tab", action: #selector(menuNewEphemeralTab(_:)), keyEquivalent: "")
        ephemeralItem.target = self
        if let containers = containerProvider?(), !containers.isEmpty {
            menu.addItem(.separator())
            for (id, name) in containers {
                let item = menu.addItem(withTitle: "New \(name) Tab", action: #selector(menuNewContainerTab(_:)), keyEquivalent: "")
                item.representedObject = id
                item.target = self
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func menuNewTab(_ sender: Any?) { onNewTab?() }

    @objc private func menuNewEphemeralTab(_ sender: Any?) {
        onNewContainerTab?(ContainerRegistry.ephemeralProfileID)
    }

    @objc private func menuNewContainerTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onNewContainerTab?(id)
    }

    // MARK: - Updates

    func update(tabs: [TabDisplayModel], selectedID: UUID?) {
        guard tabs != models || selectedID != self.selectedID else { return }
        models = tabs
        self.selectedID = selectedID

        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, model) in tabs.enumerated() {
            let item = TabItemView(model: model, isSelected: model.id == selectedID)
            item.onSelect = { [weak self] in self?.onSelect?(model.id) }
            item.onClose = { [weak self] in self?.onClose?(model.id) }
            item.onDragEnded = { [weak self, weak item] event in
                guard let self, let item else { return }
                self.commitReorder(of: item, from: index, with: event)
            }
            stack.addArrangedSubview(item)
            NSLayoutConstraint.activate([
                item.widthAnchor.constraint(equalToConstant: model.isPinned ? 120 : 180),
                item.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
    }

    /// Maps the drop x-position onto an index in the strip. The model is
    /// only mutated here, on mouse-up — no mid-drag rebuilds, so the view
    /// receiving the drag stays alive for the whole gesture.
    private func commitReorder(of item: TabItemView, from index: Int, with event: NSEvent) {
        let dropX = stack.convert(event.locationInWindow, from: nil).x
        var target = stack.arrangedSubviews.count - 1
        for (i, view) in stack.arrangedSubviews.enumerated() where dropX < view.frame.midX {
            target = i
            break
        }
        guard target != index else { return }
        onReorder?(index, target)
    }
}

/// One tab in the strip.
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Fired on mouse-up after a real drag (threshold exceeded).
    var onDragEnded: ((NSEvent) -> Void)?

    private let favicon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let stripe = NSView()
    private let isSelected: Bool

    private var dragOrigin: NSPoint?
    private var isDragging = false

    init(model: TabDisplayModel, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        layer?.cornerRadius = 6
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        stripe.wantsLayer = true
        stripe.translatesAutoresizingMaskIntoConstraints = false
        if model.isEphemeral {
            stripe.layer?.backgroundColor = NSColor.systemPurple.cgColor
        } else if let hex = model.containerColorHex, let color = NSColor(hexString: hex) {
            stripe.layer?.backgroundColor = color.cgColor
        } else {
            stripe.layer?.backgroundColor = NSColor.clear.cgColor
        }
        stripe.layer?.cornerRadius = 1.5
        addSubview(stripe)

        favicon.image = model.favicon
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        favicon.contentTintColor = model.favicon == nil ? .tertiaryLabelColor : nil
        favicon.imageScaling = .scaleProportionallyDown
        favicon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favicon)

        var title = model.title
        if model.isPinned { title = "📌 " + title }
        if model.isHibernated { title = "💤 " + title }
        if model.isLoading { title = "⋯ " + title }
        label.stringValue = title
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stripe.centerYAnchor.constraint(equalTo: centerYAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3),
            stripe.heightAnchor.constraint(equalToConstant: 16),
            favicon.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 5),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 14),
            favicon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: favicon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    // Select on mouse-down (browser feel); a drag past the threshold turns
    // the gesture into a reorder, committed on mouse-up.
    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        isDragging = false
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        if !isDragging, abs(event.locationInWindow.x - dragOrigin.x) > 5 {
            isDragging = true
            alphaValue = 0.6
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            alphaValue = 1.0
            onDragEnded?(event)
        }
        dragOrigin = nil
        isDragging = false
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }
}

extension NSColor {
    /// "#RRGGBB" → color.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
