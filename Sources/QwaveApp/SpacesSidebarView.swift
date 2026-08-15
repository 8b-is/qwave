import AppKit
import BrowserCore

/// One space entry in the sidebar header.
struct SpaceChipModel: Equatable {
    /// `nil` = the default, container-less space.
    let id: UUID?
    let name: String
    let colorHex: String
    let tabCount: Int
    let isActive: Bool
}

/// Arc-style vertical sidebar: a column of Spaces at the top, and, beneath the
/// active Space, its tabs listed vertically. Reuses `TabDisplayModel` for the
/// tab rows so the model mirrors the horizontal `TabBarView` exactly. The
/// horizontal strip is untouched — this lives alongside it, toggleable.
final class SpacesSidebarView: NSView {
    /// Selecting a Space (nil = default space).
    var onSelectSpace: ((UUID?) -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    /// New tab in the active Space (nil = default space).
    var onNewTab: ((UUID?) -> Void)?

    private let spacesStack = NSStackView()
    private let tabsStack = NSStackView()
    private let tabsScroll = NSScrollView()
    private let newTabButton = NSButton()

    private var spaces: [SpaceChipModel] = []
    private var tabs: [TabDisplayModel] = []
    private var selectedID: UUID?
    /// The space whose tabs the row list currently shows.
    private var listSpaceID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        let header = NSTextField(labelWithString: "Spaces")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        spacesStack.orientation = .vertical
        spacesStack.spacing = 3
        spacesStack.alignment = .leading
        spacesStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spacesStack)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        tabsStack.orientation = .vertical
        tabsStack.spacing = 2
        tabsStack.alignment = .leading
        tabsStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        tabsStack.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSClipView()
        clip.documentView = tabsStack
        tabsScroll.contentView = clip
        tabsScroll.hasVerticalScroller = true
        tabsScroll.drawsBackground = false
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabsScroll)

        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab in Space")
        newTabButton.imagePosition = .imageLeading
        newTabButton.title = " New Tab"
        newTabButton.font = .systemFont(ofSize: 12)
        newTabButton.bezelStyle = .texturedRounded
        newTabButton.isBordered = false
        newTabButton.alignment = .left
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.setAccessibilityLabel("New Tab in Space")
        addSubview(newTabButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            spacesStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            spacesStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            spacesStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            divider.topAnchor.constraint(equalTo: spacesStack.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            tabsScroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            tabsScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tabsScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tabsScroll.bottomAnchor.constraint(equalTo: newTabButton.topAnchor, constant: -4),

            tabsStack.topAnchor.constraint(equalTo: clip.topAnchor),
            tabsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            tabsStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            newTabButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            newTabButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            newTabButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Spaces Sidebar")
    }

    @objc private func newTabClicked() {
        onNewTab?(listSpaceID)
    }

    // MARK: - Updates

    func update(
        spaces: [SpaceChipModel],
        tabs: [TabDisplayModel],
        selectedID: UUID?,
        listSpaceID: UUID?
    ) {
        guard spaces != self.spaces || tabs != self.tabs
            || selectedID != self.selectedID || listSpaceID != self.listSpaceID
        else { return }
        self.spaces = spaces
        self.tabs = tabs
        self.selectedID = selectedID
        self.listSpaceID = listSpaceID
        rebuildSpaces()
        rebuildTabs()
    }

    private func rebuildSpaces() {
        spacesStack.arrangedSubviews.forEach { view in
            spacesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for model in spaces {
            let chip = SpaceChipView(model: model)
            chip.onSelect = { [weak self] in self?.onSelectSpace?(model.id) }
            spacesStack.addArrangedSubview(chip)
            chip.widthAnchor.constraint(equalTo: spacesStack.widthAnchor).isActive = true
        }
    }

    private func rebuildTabs() {
        tabsStack.arrangedSubviews.forEach { view in
            tabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for model in tabs {
            let row = SidebarTabRow(model: model, isSelected: model.id == selectedID)
            row.onSelect = { [weak self] in self?.onSelectTab?(model.id) }
            row.onClose = { [weak self] in self?.onCloseTab?(model.id) }
            tabsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tabsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
    }
}

/// A Space chip: color dot, name, tab count. Reads as a radio button so
/// VoiceOver announces the active Space among the group.
private final class SpaceChipView: NSView {
    var onSelect: (() -> Void)?

    init(model: SpaceChipModel) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6
        layer?.backgroundColor =
            model.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor =
            (NSColor(hexString: model.colorHex) ?? .systemGray).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        let label = NSTextField(labelWithString: model.name)
        label.font = .systemFont(ofSize: 13, weight: model.isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let count = NSTextField(labelWithString: model.tabCount > 0 ? "\(model.tabCount)" : "")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .tertiaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(model.name) space, \(model.tabCount) tabs")
        if model.isActive { setAccessibilityValue("selected") }
        dot.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        count.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

/// One vertical tab row: accent stripe, favicon, title, close button. A leaner
/// sibling of the horizontal strip's item (no drag-reorder — deferred).
private final class SidebarTabRow: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let closeButton = NSButton()

    init(model: TabDisplayModel, isSelected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6
        layer?.backgroundColor =
            isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        let stripe = NSView()
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

        let favicon = NSImageView()
        favicon.image =
            model.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        favicon.contentTintColor = model.favicon == nil ? .tertiaryLabelColor : nil
        favicon.imageScaling = .scaleProportionallyDown
        favicon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favicon)

        var title = model.title
        if model.isPinned { title = "📌 " + title }
        if model.isHibernated { title = "💤 " + title }
        if model.isLoading { title = "⋯ " + title }
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stripe.centerYAnchor.constraint(equalTo: centerYAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3),
            stripe.heightAnchor.constraint(equalToConstant: 16),
            favicon.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 6),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 14),
            favicon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: favicon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(model.title.isEmpty ? "Untitled" : model.title)
        if isSelected { setAccessibilityValue("selected") }
        favicon.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        closeButton.setAccessibilityLabel("Close \(model.title.isEmpty ? "tab" : model.title)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
