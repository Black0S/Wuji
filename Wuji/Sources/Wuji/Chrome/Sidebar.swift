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

/// L'espace courant, tel que la sidebar a besoin de le connaître : un nom et une forme.
struct SpaceSnapshot {
    let name: String
    let symbol: String
}

/// La sidebar **ancrée**. Le contenu commence après elle, il ne passe pas dessous —
/// c'est la différence avec un panneau flottant, et elle est structurante : la page n'est
/// jamais partiellement masquée.
///
/// Contrepartie assumée : révéler la sidebar redimensionne la vue web, donc la page se
/// remet en page. À juger à l'usage — c'est le principal risque de ce layout.
@MainActor
final class Sidebar: ThemedView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    /// La sidebar ne connaît pas la liste des espaces : elle signale le clic et rend la
    /// vue d'ancrage, c'est l'application qui déroule le menu.
    var onSpaceClick: ((NSView) -> Void)?

    private let spaceSwitcher = SpaceSwitcher()
    private let list = NSView()
    private let newTabButton = FooterButton(symbol: "plus", title: "Nouvel onglet", shortcut: "⌘T")
    private var rows: [TabRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(spaceSwitcher)
        addSubview(list)
        addSubview(newTabButton)
        newTabButton.onClick = { [weak self] in self?.onNew?() }
        spaceSwitcher.onClick = { [weak self] view in self?.onSpaceClick?(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(space: SpaceSnapshot) {
        spaceSwitcher.update(space)
    }

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

        let width = bounds.width
        let rowHeight = Tokens.Chrome.rowHeight
        let inset = Tokens.Space.s

        // Sous les feux de circulation, que macOS place lui-même.
        var top = bounds.height - Tokens.Chrome.trafficLights
        let bottom = Tokens.Space.s + rowHeight + Tokens.Space.s

        spaceSwitcher.frame = NSRect(x: inset, y: top - rowHeight,
                                     width: width - inset * 2, height: rowHeight)
        top -= rowHeight + Tokens.Space.m

        newTabButton.frame = NSRect(x: inset, y: Tokens.Space.s,
                                    width: width - inset * 2, height: rowHeight)

        list.frame = NSRect(x: 0, y: bottom, width: width, height: max(0, top - bottom))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset,
                               y: list.bounds.height - CGFloat(index + 1) * rowHeight,
                               width: width - inset * 2,
                               height: rowHeight - 2)
        }
    }
}

// MARK: - Lignes

/// Le sélecteur d'espace, en tête de sidebar : la forme de l'espace courant, son nom, et
/// un chevron qui annonce qu'il y a un choix derrière.
@MainActor
private final class SpaceSwitcher: ThemedView {

    var onClick: ((NSView) -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down",
                                accessibilityDescription: "Changer d'espace")
        glyph.imageScaling = .scaleProportionallyDown
        [glyph, label, chevron].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ space: SpaceSnapshot) {
        glyph.image = NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
        label.stringValue = space.name
        needsLayout = true
    }

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
        layer?.backgroundColor = isHovered ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        glyph.contentTintColor = Tokens.textPrimary
        label.textColor = Tokens.textPrimary
        chevron.contentTintColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let left = Tokens.Space.s + 14 + Tokens.Space.m
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: bounds.width - left - 28, height: 16)
        chevron.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }

    override func mouseDown(with event: NSEvent) { onClick?(self) }
}

/// Un onglet. La favicon est la seule couleur admise dans le chrome — et c'est cohérent :
/// elle appartient au site, pas à l'interface (spec §4.6).
@MainActor
private final class TabRow: ThemedView {

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

/// Bouton plein-largeur du bas de liste, avec son raccourci à droite.
@MainActor
private final class FooterButton: ThemedView {
    var onClick: (() -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    init(symbol: String, title: String, shortcut key: String) {
        super.init(frame: .zero)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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
        label.textColor = Tokens.textSecondary
        shortcut.textColor = Tokens.textSecondary
        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: Tokens.Space.s + 14 + Tokens.Space.s, y: (bounds.height - 16) / 2,
                             width: bounds.width - 90, height: 16)
        shortcut.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 15) / 2, width: 36, height: 15)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
