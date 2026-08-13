import AppKit

/// Un espace, tel que le panneau a besoin de le connaître.
struct SpaceRowSnapshot {
    let name: String
    let symbol: String
    let tabCount: Int
}

@MainActor
protocol SpacesPanelDelegate: AnyObject {
    func spacesPanel(_ panel: SpacesPanel, didSelect index: Int)
    func spacesPanel(_ panel: SpacesPanel, didPick symbol: String)
    func spacesPanel(_ panel: SpacesPanel, didRename index: Int, to name: String)
    func spacesPanel(_ panel: SpacesPanel, didMove index: Int, to destination: Int)
    func spacesPanel(_ panel: SpacesPanel, didDelete index: Int)
    /// Le panneau ne construit pas le menu : il signale le clic droit et laisse
    /// l'application ouvrir la feuille d'action, la même que partout ailleurs.
    func spacesPanel(_ panel: SpacesPanel, menuFor index: Int, canDelete: Bool, at event: NSEvent)
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
                                                                 tabCount: -1),
                                       isCurrent: false)
    private var rows: [SpaceRow] = []
    private var symbolButtons: [SymbolButton] = []
    private var canDelete = false

    private static let cardWidth: CGFloat = 248
    private static let rowHeight: CGFloat = 34
    private static let symbolStrip: CGFloat = 44
    /// Écart vertical entre deux lignes. Sans lui, le contour de la ligne courante vient
    /// toucher le fond de la ligne survolée : deux surfaces collées se lisent comme une.
    private static let rowGap: CGFloat = 3

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

        newSpaceRow.onMouseDown = { [weak self] _, _ in
            guard let self else { return }
            self.dismiss()
            self.delegate?.spacesPanelDidRequestNew(self)
        }
        card.addSubview(newSpaceRow)

        for symbol in Space.symbols {
            let button = SymbolButton(symbol: symbol)
            button.onClick = { [weak self] in
                guard let self else { return }
                self.delegate?.spacesPanel(self, didPick: symbol)
            }
            card.addSubview(button)
            symbolButtons.append(button)
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

    func present(spaces: [SpaceRowSnapshot], current: Int, symbol: String, anchor: NSView) {
        // Sous le sélecteur qui l'a ouvert, aligné sur son bord gauche.
        let originInSelf = convert(NSPoint(x: 0, y: 0), from: anchor)
        anchorPoint = NSPoint(x: originInSelf.x, y: originInSelf.y - Tokens.Space.xs)
        isHidden = false
        reload(spaces: spaces, current: current, symbol: symbol)
    }

    /// Recharge le contenu sans déplacer le panneau : indispensable après un choix de
    /// couleur ou un déplacement, sinon l'état change dans la sidebar et pas dans le
    /// panneau qui vient de servir à le changer.
    func reload(spaces: [SpaceRowSnapshot], current: Int, symbol: String) {
        // Un espace ne peut pas être supprimé s'il est le dernier : il faut bien que les
        // onglets vivent quelque part.
        canDelete = spaces.count > 1
        rows.forEach { $0.removeFromSuperview() }
        rows = spaces.enumerated().map { index, snapshot in
            let row = SpaceRow(snapshot: snapshot, isCurrent: index == current)
            row.onMouseDown = { [weak self] _, event in self?.beginTracking(at: index, event: event) }
            row.onContextMenu = { [weak self] event in
                guard let self else { return }
                self.delegate?.spacesPanel(self, menuFor: index, canDelete: self.canDelete, at: event)
            }
            row.onRename = { [weak self] name in
                guard let self else { return }
                self.delegate?.spacesPanel(self, didRename: index, to: name)
            }
            card.addSubview(row)
            return row
        }
        symbolButtons.forEach { $0.isSelected = $0.symbol == symbol }
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

        let listHeight = CGFloat(rows.count + 1) * (Self.rowHeight + Self.rowGap) + Tokens.Space.s * 2
        let cardHeight = listHeight + Self.symbolStrip
        card.frame = NSRect(x: anchorPoint.x, y: anchorPoint.y - cardHeight,
                            width: Self.cardWidth, height: cardHeight)

        var cursor = cardHeight - Tokens.Space.s
        let inset = Tokens.Space.s
        for row in rows {
            cursor -= Self.rowHeight + Self.rowGap
            row.frame = NSRect(x: inset, y: cursor + Self.rowGap,
                               width: Self.cardWidth - inset * 2, height: Self.rowHeight)
        }
        cursor -= Self.rowHeight + Self.rowGap
        newSpaceRow.frame = NSRect(x: inset, y: cursor + Self.rowGap,
                                   width: Self.cardWidth - inset * 2, height: Self.rowHeight)

        separator.frame = NSRect(x: 0, y: Self.symbolStrip, width: Self.cardWidth, height: 1)
        layoutStrip(symbolButtons, height: Self.symbolStrip, bottom: 0, diameter: 22, gap: 8)
    }

    private func layoutStrip(_ views: [NSView], height: CGFloat, bottom: CGFloat,
                             diameter: CGFloat, gap: CGFloat) {
        let total = CGFloat(views.count) * diameter + CGFloat(views.count - 1) * gap
        var x = (Self.cardWidth - total) / 2
        for view in views {
            view.frame = NSRect(x: x, y: bottom + (height - diameter) / 2,
                                width: diameter, height: diameter)
            x += diameter + gap
        }
    }

    // MARK: - Sélection et réordonnancement

    /// Clic et glisser partagent le même appui : on ne sait lequel c'est qu'après coup.
    ///
    /// La boucle de suivi vit ici, et non dans la ligne : réordonner détruit et recrée
    /// les lignes, donc une ligne qui suivrait son propre glissement disparaîtrait au
    /// premier déplacement, avec les événements qu'elle attendait encore.
    private func beginTracking(at index: Int, event: NSEvent) {
        guard let window else { return }
        var origin = index
        var moved = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self, let event else { stop.pointee = true; return }

            if event.type == .leftMouseUp {
                stop.pointee = true
                guard !moved else { return }
                self.dismiss()
                self.delegate?.spacesPanel(self, didSelect: origin)
                return
            }

            let point = self.convert(event.locationInWindow, from: nil)
            let target = self.rowIndex(at: point)
            guard target != origin, self.rows.indices.contains(target) else { return }
            moved = true
            self.delegate?.spacesPanel(self, didMove: origin, to: target)
            origin = target
        }
    }

    private func rowIndex(at point: NSPoint) -> Int {
        let top = card.frame.maxY - Tokens.Space.s
        let offset = Int((top - point.y) / Self.rowHeight)
        return min(max(offset, 0), max(rows.count - 1, 0))
    }

    /// Le renommage se fait sur place, donc le panneau doit rester ouvert : c'est lui qui
    /// détient la ligne à transformer en champ.
    func beginRename(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].beginRename(in: window)
    }
}

// MARK: - Lignes

/// Une ligne d'espace : pastille, nom, nombre d'onglets.
@MainActor
private final class SpaceRow: ThemedView, NSTextFieldDelegate {

    var onMouseDown: ((Int, NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onRename: ((String) -> Void)?

    private let glyph = NSImageView()
    private let label = InsetTextField.label()
    private let count = InsetTextField.label(size: 12, alignment: .right)
    private let isCurrent: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isRenaming = false

    init(snapshot: SpaceRowSnapshot, isCurrent: Bool) {
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
        label.focusRingType = .none
        label.delegate = self
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
        // En édition, la ligne devient le champ : fond relevé et filet, comme n'importe
        // quelle surface saisissable du reste de l'interface.
        layer?.backgroundColor = isRenaming ? Tokens.rowSelected.cgColor
            : ((isCurrent || isHovered) ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = isRenaming ? 1 : 0
        layer?.borderColor = Tokens.chromeHairline.cgColor
        glyph.contentTintColor = Tokens.textPrimary
        label.textColor = Tokens.textPrimary
        count.textColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.m, y: (bounds.height - 15) / 2, width: 15, height: 15)
        let left = Tokens.Space.m + 15 + Tokens.Space.m
        // Cadres pleine hauteur : une étiquette sur une seule ligne se centre dans son
        // cadre, alors qu'un cadre à hauteur fixe la laisse flotter d'un point ou deux
        // au-dessus du glyphe. C'est peu et ça se voit.
        count.frame = NSRect(x: bounds.width - 44, y: 0, width: 36, height: bounds.height)
        label.frame = NSRect(x: left, y: 0,
                             width: count.frame.minX - left - Tokens.Space.s, height: bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming else { return }
        onMouseDown?(0, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    // MARK: - Renommage

    /// Renommage sur place plutôt qu'en boîte de dialogue : le nom se relit dans son
    /// contexte, à côté des autres espaces, ce qu'une fenêtre modale interdit.
    func beginRename(in window: NSWindow?) {
        isRenaming = true
        label.isEditable = true
        label.isSelectable = true
        // Ni bordure ni fond du système : le cadre d'édition, c'est la ligne elle-même,
        // qui prend un filet. Le champ bezelé apportait son dégradé et son arrondi, deux
        // héritages d'un vocabulaire qu'on n'utilise nulle part ailleurs.
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        needsLayout = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    private func endRename() {
        guard isRenaming else { return }
        isRenaming = false
        label.isEditable = false
        label.isSelectable = false
        needsLayout = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let name = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
        guard !name.isEmpty else { return }
        onRename?(name)
    }
}

/// Un choix de forme. La forme est ce qui distingue un espace quand la couleur ne peut
/// pas être vue — elle n'est pas un ornement à côté de la pastille colorée.
@MainActor
private final class SymbolButton: ThemedView {

    let symbol: String
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsLayout = true } }

    private let glyph = NSImageView()

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        glyph.contentTintColor = isSelected ? Tokens.textPrimary : Tokens.textSecondary
        glyph.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
