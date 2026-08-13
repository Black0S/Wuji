import AppKit

/// Un espace, tel que le panneau a besoin de le connaître.
struct SpaceRowSnapshot {
    let name: String
    let symbol: String
    let color: NSColor?
    let tabCount: Int
}

@MainActor
protocol SpacesPanelDelegate: AnyObject {
    func spacesPanel(_ panel: SpacesPanel, didSelect index: Int)
    func spacesPanel(_ panel: SpacesPanel, didPick tint: Space.Tint)
    func spacesPanelDidRequestNew(_ panel: SpacesPanel)
}

/// Le panneau des espaces : la liste, le nombre d'onglets de chacun, et la palette.
///
/// Panneau maison plutôt que `NSPopover` : le popover système impose son propre fond, son
/// ombre et sa flèche, tous étrangers au reste. Une surface flat de plus coûte moins cher
/// qu'une exception dans le design system.
@MainActor
final class SpacesPanel: ThemedView {

    weak var delegate: SpacesPanelDelegate?

    private let card = NSView()
    private let separator = NSView()
    private let newSpaceRow = SpaceRow(snapshot: SpaceRowSnapshot(name: "Nouvel espace",
                                                                 symbol: "plus",
                                                                 color: nil,
                                                                 tabCount: -1),
                                       isCurrent: false)
    private var rows: [SpaceRow] = []
    private var swatches: [Swatch] = []

    private static let cardWidth: CGFloat = 248
    private static let rowHeight: CGFloat = 34
    private static let swatchStrip: CGFloat = 44

    /// Ancrage : coin haut-gauche du panneau, en coordonnées de cette vue.
    private var anchorPoint: NSPoint = .zero

    var isOpen: Bool { !isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.card
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: card)
        addSubview(card)

        separator.wantsLayer = true
        card.addSubview(separator)

        newSpaceRow.onClick = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.delegate?.spacesPanelDidRequestNew(self)
        }
        card.addSubview(newSpaceRow)

        for tint in Space.Tint.allCases {
            let swatch = Swatch(tint: tint)
            swatch.onClick = { [weak self] in
                guard let self else { return }
                self.delegate?.spacesPanel(self, didPick: tint)
            }
            card.addSubview(swatch)
            swatches.append(swatch)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(local) { dismiss() }
    }

    // MARK: - Contenu

    func present(spaces: [SpaceRowSnapshot], current: Int, tint: Space.Tint, anchor: NSView) {
        // Sous le sélecteur qui l'a ouvert, aligné sur son bord gauche.
        let originInSelf = convert(NSPoint(x: 0, y: 0), from: anchor)
        anchorPoint = NSPoint(x: originInSelf.x, y: originInSelf.y - Tokens.Space.xs)
        isHidden = false
        reload(spaces: spaces, current: current, tint: tint)
    }

    /// Recharge le contenu sans déplacer le panneau : indispensable après un choix de
    /// couleur, sinon la pastille change dans la sidebar et pas dans le panneau qui vient
    /// de servir à la choisir.
    func reload(spaces: [SpaceRowSnapshot], current: Int, tint: Space.Tint) {
        rows.forEach { $0.removeFromSuperview() }
        rows = spaces.enumerated().map { index, snapshot in
            let row = SpaceRow(snapshot: snapshot, isCurrent: index == current)
            row.onClick = { [weak self] in
                guard let self else { return }
                self.dismiss()
                self.delegate?.spacesPanel(self, didSelect: index)
            }
            card.addSubview(row)
            return row
        }
        swatches.forEach { $0.isSelected = $0.tint == tint }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func dismiss() {
        guard isOpen else { return }
        isHidden = true
    }

    override func layout() {
        super.layout()
        card.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        card.layer?.borderColor = Tokens.chromeHairline.cgColor
        separator.layer?.backgroundColor = Tokens.separator.cgColor

        let listHeight = CGFloat(rows.count + 1) * Self.rowHeight + Tokens.Space.s * 2
        let cardHeight = listHeight + Self.swatchStrip
        card.frame = NSRect(x: anchorPoint.x, y: anchorPoint.y - cardHeight,
                            width: Self.cardWidth, height: cardHeight)

        var cursor = cardHeight - Tokens.Space.s
        for row in rows {
            cursor -= Self.rowHeight
            row.frame = NSRect(x: Tokens.Space.xs, y: cursor,
                               width: Self.cardWidth - Tokens.Space.s, height: Self.rowHeight)
        }
        cursor -= Self.rowHeight
        newSpaceRow.frame = NSRect(x: Tokens.Space.xs, y: cursor,
                                   width: Self.cardWidth - Tokens.Space.s, height: Self.rowHeight)

        separator.frame = NSRect(x: 0, y: Self.swatchStrip, width: Self.cardWidth, height: 1)

        // La palette, centrée dans son bandeau.
        let diameter: CGFloat = 18
        let gap: CGFloat = 10
        let total = CGFloat(swatches.count) * diameter + CGFloat(swatches.count - 1) * gap
        var x = (Self.cardWidth - total) / 2
        for swatch in swatches {
            swatch.frame = NSRect(x: x, y: (Self.swatchStrip - diameter) / 2,
                                  width: diameter, height: diameter)
            x += diameter + gap
        }
    }
}

// MARK: - Lignes

/// Une ligne d'espace : pastille, nom, nombre d'onglets.
@MainActor
private final class SpaceRow: ThemedView {

    var onClick: (() -> Void)?

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let tint: NSColor?
    private let isCurrent: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(snapshot: SpaceRowSnapshot, isCurrent: Bool) {
        self.tint = snapshot.color
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(systemSymbolName: snapshot.symbol, accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)

        label.stringValue = snapshot.name
        label.font = .systemFont(ofSize: 13, weight: isCurrent ? .medium : .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        // -1 sert de « pas de compte » pour la ligne d'ajout.
        count.stringValue = snapshot.tabCount >= 0 ? "\(snapshot.tabCount)" : ""
        count.font = .systemFont(ofSize: 12, weight: .regular)
        count.alignment = .right
        addSubview(count)
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
        layer?.backgroundColor = (isCurrent || isHovered) ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        // La couleur ne touche que le symbole. Le texte reste monochrome, sinon la
        // lisibilité dépendrait d'un choix de teinte fait par l'utilisateur.
        glyph.contentTintColor = tint ?? Tokens.textPrimary
        label.textColor = Tokens.textPrimary
        count.textColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.m, y: (bounds.height - 15) / 2, width: 15, height: 15)
        let left = Tokens.Space.m + 15 + Tokens.Space.m
        count.frame = NSRect(x: bounds.width - 44, y: (bounds.height - 15) / 2, width: 36, height: 15)
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: count.frame.minX - left - Tokens.Space.s, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Une pastille de la palette. « Sans couleur » est un cercle vide, pas une absence de
/// bouton : ne rien afficher rendrait le retour en arrière impossible.
@MainActor
private final class Swatch: ThemedView {

    let tint: Space.Tint
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(tint: Space.Tint) {
        self.tint = tint
        super.init(frame: .zero)
        setAccessibilityLabel(tint.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 2
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))

        if let color = tint.color {
            color.setFill()
            circle.fill()
        } else {
            Tokens.chromeHairline.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }

        guard isSelected else { return }
        // Anneau de sélection en dehors de la pastille : posé dessus, il masquerait la
        // couleur qu'on est en train de choisir.
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        Tokens.textPrimary.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
