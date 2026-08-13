import AppKit

/// Ce qu'une vue d'onglets a le droit de savoir. Volontairement pauvre : ni `WKWebView`,
/// ni `Tab`, ni index de navigation.
///
/// Un seul layout existe aujourd'hui — le vertical. Ce type reste malgré tout la frontière
/// entre le modèle et son rendu : c'est ce qui permettra d'ajouter l'horizontal ou le
/// Split View sans toucher au modèle (spec §2.2).
struct TabSnapshot {
    let title: String
    let host: String
    let isLoading: Bool
    let favicon: NSImage?
}

/// La sidebar **ancrée**. Le contenu commence après elle, il ne passe pas dessous —
/// c'est la différence avec un panneau flottant, et elle est structurante : la page n'est
/// jamais partiellement masquée.
///
/// Contrepartie assumée : révéler la sidebar redimensionne la vue web, donc la page se
/// remet en page. À juger à l'usage — c'est le principal risque de ce layout.
@MainActor
final class Sidebar: NSView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let spaceRow = SpaceRow()
    private let newTabShortcut = ShortcutRow(title: "New Tab", shortcut: "⌘T")
    private let list = NSView()
    private let newTabButton = FooterButton(symbol: "plus", title: "New Tab")
    private let footer = NSView()
    private var footerButtons: [NSButton] = []
    private var rows: [TabRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(spaceRow)
        addSubview(newTabShortcut)
        addSubview(list)
        addSubview(newTabButton)
        addSubview(footer)

        newTabButton.onClick = { [weak self] in self?.onNew?() }

        for symbol in ["arrow.down.circle", "plus", "ellipsis"] {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(footerAction(_:))
            footer.addSubview(button)
            footerButtons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [TabSnapshot], selected: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = tabs.enumerated().map { index, snapshot in
            let row = TabRow(snapshot: snapshot, isSelected: index == selected)
            row.onSelect = { [weak self] in self?.onSelect?(index) }
            row.onClose = { [weak self] in self?.onClose?(index) }
            list.addSubview(row)
            return row
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor
        footerButtons.forEach { $0.contentTintColor = Tokens.textSecondary }

        let width = bounds.width
        let rowHeight = Tokens.Chrome.rowHeight
        let inset = Tokens.Space.s

        // Sous les feux de circulation.
        var cursor = bounds.height - Tokens.Chrome.trafficLights
        spaceRow.frame = NSRect(x: inset, y: cursor - rowHeight, width: width - inset * 2, height: rowHeight)
        cursor -= rowHeight + Tokens.Space.m

        newTabShortcut.frame = NSRect(x: inset, y: cursor - rowHeight, width: width - inset * 2, height: rowHeight)
        cursor -= rowHeight + Tokens.Space.s

        let footerTop = Tokens.Chrome.footerHeight
        footer.frame = NSRect(x: 0, y: 0, width: width, height: footerTop)
        let buttonWidth = width / 4
        for (index, button) in footerButtons.enumerated() {
            button.frame = NSRect(x: inset + CGFloat(index) * buttonWidth, y: 0,
                                  width: buttonWidth, height: footerTop)
        }

        newTabButton.frame = NSRect(x: inset, y: footerTop + Tokens.Space.s,
                                    width: width - inset * 2, height: rowHeight)

        let listBottom = footerTop + Tokens.Space.s + rowHeight + Tokens.Space.s
        list.frame = NSRect(x: 0, y: listBottom, width: width, height: max(0, cursor - listBottom))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset,
                               y: list.bounds.height - CGFloat(index + 1) * rowHeight,
                               width: width - inset * 2,
                               height: rowHeight - 2)
        }
    }

    @objc private func footerAction(_ sender: NSButton) {
        guard footerButtons.firstIndex(of: sender) == 1 else { return }
        onNew?()
    }
}

// MARK: - Lignes

/// Le sélecteur d'espace. Statique dans le spike : les Spaces sont un sujet de v1.1,
/// la ligne n'est là que pour éprouver la densité verticale de la sidebar.
@MainActor
private final class SpaceRow: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "Personal")
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        [glyph, label, chevron].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glyph.contentTintColor = Tokens.textPrimary
        label.textColor = Tokens.textPrimary
        chevron.contentTintColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: Tokens.Space.s + 14 + Tokens.Space.s, y: (bounds.height - 16) / 2,
                             width: bounds.width - 80, height: 16)
        chevron.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }
}

/// Ligne « action + raccourci », comme le `New Tab ⌘T` de la maquette.
@MainActor
private final class ShortcutRow: NSView {
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init(title: String, shortcut key: String) {
        super.init(frame: .zero)
        glyph.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .regular)
        shortcut.stringValue = key
        shortcut.font = .systemFont(ofSize: 12, weight: .regular)
        shortcut.alignment = .right
        [glyph, label, shortcut].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glyph.contentTintColor = Tokens.textSecondary
        label.textColor = Tokens.textPrimary
        shortcut.textColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: Tokens.Space.s + 14 + Tokens.Space.s, y: (bounds.height - 16) / 2,
                             width: bounds.width - 100, height: 16)
        shortcut.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 15) / 2, width: 36, height: 15)
    }
}

/// Un onglet. La favicon est la seule couleur admise dans le chrome — et c'est cohérent :
/// elle appartient au site, pas à l'interface (spec §4.6).
@MainActor
private final class TabRow: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let isSelected: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(snapshot: TabSnapshot, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        if let favicon = snapshot.favicon {
            icon.image = favicon
        } else {
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = Tokens.textSecondary
        }
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        label.stringValue = snapshot.isLoading ? "· \(snapshot.title)" : snapshot.title
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer l'onglet")
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.target = self
        close.action = #selector(closeTab)
        close.isHidden = true
        addSubview(close)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsLayout = true }

    override func layout() {
        super.layout()
        // La ligne active est la seule surface surélevée de la sidebar : fond plus clair,
        // et un filet, parce qu'en flat rien d'autre ne la détache.
        layer?.backgroundColor = isSelected ? Tokens.rowSelected.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = Tokens.chromeHairline.cgColor
        label.textColor = isSelected ? Tokens.textPrimary : Tokens.textSecondary
        close.contentTintColor = Tokens.textSecondary
        // La croix n'apparaît qu'au survol : cinq croix alignées en permanence, c'est
        // cinq éléments de plus à l'écran pour une action rare (principe 5).
        close.isHidden = !isHovered

        let iconSize: CGFloat = 16
        icon.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
        let left = Tokens.Space.s + iconSize + Tokens.Space.m
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: bounds.width - left - 26, height: 16)
        close.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closeTab() { onClose?() }
}

/// Bouton plein-largeur du bas de liste.
@MainActor
private final class FooterButton: NSView {
    var onClick: (() -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .regular)
        [glyph, label].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glyph.contentTintColor = Tokens.textSecondary
        label.textColor = Tokens.textSecondary
        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: Tokens.Space.s + 14 + Tokens.Space.s, y: (bounds.height - 16) / 2,
                             width: bounds.width - 40, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
