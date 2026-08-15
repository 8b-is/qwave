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
        // Diff by space id: reuse the chip already showing a given space
        // (updating name/color/count/active in place), create chips only for
        // new ids, drop chips for ids that vanished, and reorder to match.
        var existing: [UUID?: SpaceChipView] = [:]
        for case let chip as SpaceChipView in spacesStack.arrangedSubviews {
            existing[chip.spaceID] = chip
        }

        var newViews: [SpaceChipView] = []
        for model in spaces {
            let chip: SpaceChipView
            if let reused = existing[model.id] {
                chip = reused
                chip.apply(model: model)
            } else {
                chip = SpaceChipView(model: model)
                chip.widthAnchor.constraint(equalTo: spacesStack.widthAnchor).isActive = true
            }
            chip.onSelect = { [weak self] in self?.onSelectSpace?(model.id) }
            newViews.append(chip)
        }

        reconcile(spacesStack, to: newViews)
    }

    private func rebuildTabs() {
        // Diff by tab id, mirroring `rebuildSpaces`: reuse rows in place,
        // insert/remove only for real changes, reorder to match the model.
        var existing: [UUID: SidebarTabRow] = [:]
        for case let row as SidebarTabRow in tabsStack.arrangedSubviews {
            existing[row.tabID] = row
        }

        var newViews: [SidebarTabRow] = []
        for model in tabs {
            let row: SidebarTabRow
            if let reused = existing[model.id] {
                row = reused
                row.apply(model: model, isSelected: model.id == selectedID)
            } else {
                row = SidebarTabRow(model: model, isSelected: model.id == selectedID)
                row.widthAnchor.constraint(equalTo: tabsStack.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            }
            row.onSelect = { [weak self] in self?.onSelectTab?(model.id) }
            row.onClose = { [weak self] in self?.onCloseTab?(model.id) }
            newViews.append(row)
        }

        reconcile(tabsStack, to: newViews)
    }

    /// Make `stack`'s arranged subviews equal `newViews` in order, dropping
    /// views no longer present and moving reused views into position.
    private func reconcile(_ stack: NSStackView, to newViews: [NSView]) {
        let keep = Set(newViews.map(ObjectIdentifier.init))
        for view in stack.arrangedSubviews where !keep.contains(ObjectIdentifier(view)) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (i, view) in newViews.enumerated() {
            if i < stack.arrangedSubviews.count, stack.arrangedSubviews[i] === view { continue }
            stack.removeArrangedSubview(view)
            stack.insertArrangedSubview(view, at: i)
        }
    }
}

/// A Space chip: color dot, name, tab count. Reads as a radio button so
/// VoiceOver announces the active Space among the group.
private final class SpaceChipView: NSView {
    var onSelect: (() -> Void)?

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var model: SpaceChipModel

    /// The space id this chip currently renders — the diffing key for reuse.
    var spaceID: UUID? { model.id }

    init(model: SpaceChipModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

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
        dot.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        count.setAccessibilityElement(false)

        apply(model: model)
    }

    /// Re-render this chip for a (possibly new) model in place, matching the
    /// visual and accessibility state of a freshly-constructed chip.
    func apply(model: SpaceChipModel) {
        self.model = model
        layer?.backgroundColor =
            model.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        dot.layer?.backgroundColor =
            (NSColor(hexString: model.colorHex) ?? .systemGray).cgColor
        label.stringValue = model.name
        label.font = .systemFont(ofSize: 13, weight: model.isActive ? .semibold : .regular)
        count.stringValue = model.tabCount > 0 ? "\(model.tabCount)" : ""
        setAccessibilityLabel("\(model.name) space, \(model.tabCount) tabs")
        setAccessibilityValue(model.isActive ? "selected" : nil)
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
    private let stripe = NSView()
    private let favicon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var model: TabDisplayModel
    private var isSelected: Bool

    /// The tab id this row currently renders — the diffing key for reuse.
    var tabID: UUID { model.id }

    init(model: TabDisplayModel, isSelected: Bool) {
        self.model = model
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6

        stripe.wantsLayer = true
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.layer?.cornerRadius = 1.5
        addSubview(stripe)

        favicon.imageScaling = .scaleProportionallyDown
        favicon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favicon)

        label.lineBreakMode = .byTruncatingTail
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
        favicon.setAccessibilityElement(false)
        label.setAccessibilityElement(false)

        apply(model: model, isSelected: isSelected)
    }

    /// Re-render this row for a (possibly new) model in place, matching the
    /// visual and accessibility state of a freshly-constructed row.
    func apply(model: TabDisplayModel, isSelected: Bool) {
        self.model = model
        self.isSelected = isSelected

        layer?.backgroundColor =
            isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        if model.isEphemeral {
            stripe.layer?.backgroundColor = NSColor.systemPurple.cgColor
        } else if let hex = model.containerColorHex, let color = NSColor(hexString: hex) {
            stripe.layer?.backgroundColor = color.cgColor
        } else {
            stripe.layer?.backgroundColor = NSColor.clear.cgColor
        }

        favicon.image =
            model.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        favicon.contentTintColor = model.favicon == nil ? .tertiaryLabelColor : nil

        var title = model.title
        if model.isPinned { title = "📌 " + title }
        if model.isHibernated { title = "💤 " + title }
        if model.isLoading { title = "⋯ " + title }
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)

        setAccessibilityLabel(model.title.isEmpty ? "Untitled" : model.title)
        setAccessibilityValue(isSelected ? "selected" : nil)
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
