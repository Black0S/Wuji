import AppKit

/// Une entrée de feuille d'action.
///
/// `children` remplace le sous-menu : au lieu d'ouvrir un second panneau flottant à côté
/// du premier, la feuille se replie sur ses enfants avec un retour. Un seul rectangle à
/// l'écran, une seule chose à viser.
struct ActionItem {
    let title: String
    var symbol: String?
    var shortcut: String?
    var isEnabled = true
    var isDestructive = false
    var children: [ActionItem]?
    var action: (@MainActor () -> Void)?

    static let separator = ActionItem(title: "—", isEnabled: false)
    var isSeparator: Bool { title == "—" && action == nil && children == nil && !isEnabled }
}

/// La feuille d'action : même carte, mêmes tokens, même ombre que le reste du chrome.
///
/// Elle remplace `NSMenu` partout dans l'application. Le menu système impose son propre
/// matériau translucide, son ombre et ses métriques : à côté d'une direction artistique
/// arrêtée en flat, il fait apparaître deux vocabulaires dans la même fenêtre. Une
/// surface de plus à maintenir coûte moins cher que cette incohérence.
@MainActor
final class ActionSheet: ThemedView {

    private let card = NSView()
    private var rows: [ActionRow] = []
    private var separators: [NSView] = []

    /// En-tête facultatif : une question et sa conséquence. Il transforme la même carte en
    /// demande de confirmation, plutôt que d'appeler `NSAlert` — l'alerte système arrive
    /// avec son matériau translucide, son icône d'application et ses boutons, trois
    /// vocabulaires étrangers d'un coup.
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var hasHeader = false
    private var isCentered = false

    /// Champ de saisie, pour les feuilles qui demandent un mot plutôt qu'un choix.
    private let field = InsetTextField()
    private var hasField = false

    /// Pile de navigation : la racine, puis chaque niveau ouvert.
    private var stack: [[ActionItem]] = []
    private var items: [ActionItem] { stack.last ?? [] }
    private var selection = 0
    private var anchor: NSPoint = .zero

    private static let cardWidth: CGFloat = 264
    private static let rowHeight: CGFloat = 32
    private static let padding: CGFloat = 6

    var isOpen: Bool { !isHidden }

    nonisolated(unsafe) private var keyMonitor: Any?

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

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        card.addSubview(titleLabel)
        card.addSubview(messageLabel)

        field.isBordered = false
        // Pas de fond propre : le champ se pose sur celui de la carte et ne se signale
        // que par son filet. Deux valeurs de fond empilées faisaient lire deux surfaces
        // là où il n'y en a qu'une.
        field.drawsBackground = false
        field.contentInset = Tokens.Space.m
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.isHidden = true
        field.target = self
        field.action = #selector(commitField)
        card.addSubview(field)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                return self.handle(keyCode: keyCode)
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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

    // MARK: - Ouverture

    /// `point` est exprimé dans les coordonnées de cette vue.
    func present(_ items: [ActionItem], at point: NSPoint) {
        hasHeader = false
        hasField = false
        isCentered = false
        stack = [items]
        anchor = point
        selection = firstSelectable(from: 0, step: 1) ?? 0
        isHidden = false
        rebuild()
    }

    /// Ancrage sous une vue — pour un bouton de barre, où la feuille doit tomber juste
    /// en dessous et alignée à droite.
    func present(_ items: [ActionItem], below view: NSView) {
        let origin = convert(NSPoint(x: view.bounds.maxX, y: 0), from: view)
        present(items, at: NSPoint(x: origin.x - Self.cardWidth, y: origin.y - Tokens.Space.xs))
    }

    /// Une confirmation : la question, sa conséquence, puis les deux issues.
    ///
    /// L'action destructrice est **en premier et nommée par son verbe** — « Supprimer »,
    /// pas « OK ». On lit ce qu'on est en train de faire, pas un acquiescement.
    func presentConfirmation(title: String, message: String, confirm: String,
                             onConfirm: @escaping @MainActor () -> Void) {
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        hasHeader = true
        hasField = false
        isCentered = true
        stack = [[
            ActionItem(title: confirm, symbol: "trash", isDestructive: true, action: onConfirm),
            ActionItem(title: "Annuler", symbol: "xmark")
        ]]
        selection = 1
        isHidden = false
        rebuild()
    }

    /// Une saisie : la même carte, avec un champ à la place du message.
    ///
    /// Le renommage sur place serait plus direct, mais la sidebar reconstruit ses lignes
    /// dès qu'un onglet de fond finit de charger — l'édition n'y survivrait pas.
    func presentPrompt(title: String, value: String, confirm: String,
                       onConfirm: @escaping @MainActor (String) -> Void) {
        titleLabel.stringValue = title
        messageLabel.stringValue = ""
        field.stringValue = value
        hasHeader = true
        hasField = true
        isCentered = true
        promptAction = onConfirm
        stack = [[
            ActionItem(title: confirm, symbol: "checkmark",
                       action: { [weak self] in self?.commitField() }),
            ActionItem(title: "Annuler", symbol: "xmark")
        ]]
        selection = 0
        isHidden = false
        rebuild()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private var promptAction: (@MainActor (String) -> Void)?

    @objc private func commitField() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = promptAction
        dismiss()
        guard !value.isEmpty else { return }
        action?(value)
    }

    func dismiss() {
        guard isOpen else { return }
        isHidden = true
        stack = []
    }

    // MARK: - Construction

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        rows = []
        separators = []

        for (index, item) in items.enumerated() {
            if item.isSeparator {
                let line = NSView()
                line.wantsLayer = true
                card.addSubview(line)
                separators.append(line)
                rows.append(ActionRow(item: item, isBack: false))
                rows.last?.isHidden = true
                continue
            }
            let row = ActionRow(item: item, isBack: item.children != nil && stack.count > 1 && index == 0)
            row.onHover = { [weak self] in
                guard let self, self.selection != index else { return }
                self.selection = index
                self.refreshSelection()
            }
            row.onClick = { [weak self] in self?.activate(index) }
            card.addSubview(row)
            rows.append(row)
        }
        refreshSelection()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        card.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        card.layer?.borderColor = Tokens.chromeHairline.cgColor
        separators.forEach { $0.layer?.backgroundColor = Tokens.separator.cgColor }

        titleLabel.isHidden = !hasHeader
        messageLabel.isHidden = !hasHeader || hasField
        field.isHidden = !hasField
        field.textColor = Tokens.textPrimary
        field.wantsLayer = true
        field.layer?.cornerRadius = Tokens.Radius.pill - 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Tokens.chromeHairline.cgColor
        titleLabel.textColor = Tokens.textPrimary
        messageLabel.textColor = Tokens.textSecondary

        let textWidth = Self.cardWidth - Tokens.Space.l * 2
        let messageHeight: CGFloat
        if hasField {
            messageHeight = 34
        } else if hasHeader {
            messageHeight = messageLabel.sizeThatFits(NSSize(width: textWidth,
                                                            height: .greatestFiniteMagnitude)).height
        } else {
            messageHeight = 0
        }
        let headerHeight = hasHeader ? Tokens.Space.l + 20 + Tokens.Space.xs + messageHeight + Tokens.Space.l : 0

        let height = items.reduce(Self.padding * 2 + headerHeight) { total, item in
            total + (item.isSeparator ? Tokens.Space.m : Self.rowHeight)
        }

        // Rabattue dans la fenêtre : une feuille qui déborde par le bas est une feuille
        // qu'on ne peut pas lire jusqu'au bout.
        let x = isCentered
            ? (bounds.width - Self.cardWidth) / 2
            : min(max(Tokens.Space.s, anchor.x), max(Tokens.Space.s, bounds.width - Self.cardWidth - Tokens.Space.s))
        let y = isCentered
            ? (bounds.height - height) / 2
            : max(Tokens.Space.s, min(anchor.y - height, bounds.height - height - Tokens.Space.s))
        card.frame = NSRect(x: x, y: y, width: Self.cardWidth, height: height)

        var cursor = height - Self.padding
        if hasHeader {
            cursor = height - Tokens.Space.l - 20
            titleLabel.frame = NSRect(x: Tokens.Space.l, y: cursor, width: textWidth, height: 20)
            cursor -= Tokens.Space.s + messageHeight
            let box = NSRect(x: Tokens.Space.l, y: cursor, width: textWidth, height: messageHeight)
            if hasField {
                field.frame = box
            } else {
                messageLabel.frame = box
            }
            cursor -= Tokens.Space.l
        }
        var separatorIndex = 0
        for (index, item) in items.enumerated() {
            if item.isSeparator {
                cursor -= Tokens.Space.m
                if separators.indices.contains(separatorIndex) {
                    separators[separatorIndex].frame = NSRect(x: 0, y: cursor + Tokens.Space.m / 2,
                                                              width: Self.cardWidth, height: 1)
                    separatorIndex += 1
                }
                continue
            }
            cursor -= Self.rowHeight
            rows[index].frame = NSRect(x: Self.padding, y: cursor,
                                       width: Self.cardWidth - Self.padding * 2, height: Self.rowHeight)
        }
    }

    // MARK: - Activation

    private func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.isEnabled else { return }

        if let children = item.children {
            // On empile, avec un retour en tête : sans lui, entrer dans un niveau serait
            // un aller sans retour et il faudrait refermer pour se reprendre.
            var page: [ActionItem] = [ActionItem(title: item.title, symbol: "chevron.left",
                                                 children: [], action: { [weak self] in self?.pop() })]
            page.append(.separator)
            page.append(contentsOf: children)
            stack.append(page)
            selection = firstSelectable(from: 0, step: 1) ?? 0
            rebuild()
            return
        }

        let action = item.action
        dismiss()
        action?()
    }

    private func pop() {
        guard stack.count > 1 else { return dismiss() }
        stack.removeLast()
        selection = firstSelectable(from: 0, step: 1) ?? 0
        rebuild()
    }

    // MARK: - Clavier

    private func handle(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 53:  dismiss(); return true                       // esc
        case 125: move(by: 1); return true                     // bas
        case 126: move(by: -1); return true                    // haut
        case 36, 76: activate(selection); return true          // entrée
        case 123: pop(); return true                           // gauche : remonter d'un niveau
        default: return false
        }
    }

    private func move(by delta: Int) {
        guard let next = firstSelectable(from: selection + delta, step: delta) else { return }
        selection = next
        refreshSelection()
    }

    /// Saute les séparateurs et les entrées désactivées, et boucle en bout de liste.
    private func firstSelectable(from index: Int, step: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        var candidate = (index + items.count) % items.count
        for _ in 0..<items.count {
            let item = items[candidate]
            if !item.isSeparator, item.isEnabled { return candidate }
            candidate = (candidate + (step >= 0 ? 1 : -1) + items.count) % items.count
        }
        return nil
    }

    private func refreshSelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selection }
    }
}

/// Une ligne : glyphe, libellé, raccourci. Le chevron de droite annonce un niveau derrière.
@MainActor
private final class ActionRow: ThemedView {

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { needsLayout = true } }

    private let glyph = NSImageView()
    private let label = InsetTextField.label()
    private let shortcut = InsetTextField.label(size: 12, alignment: .right)
    private let chevron = NSImageView()
    private let isEnabled: Bool
    private let isDestructive: Bool
    private var trackingArea: NSTrackingArea?

    init(item: ActionItem, isBack: Bool) {
        isEnabled = item.isEnabled
        isDestructive = item.isDestructive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        if let symbol = item.symbol {
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)

        label.stringValue = item.title
        label.font = .systemFont(ofSize: 13, weight: isBack ? .medium : .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        shortcut.stringValue = item.shortcut ?? ""
        shortcut.font = .systemFont(ofSize: 12, weight: .regular)
        shortcut.alignment = .right
        addSubview(shortcut)

        if item.children != nil, !isBack {
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        }
        chevron.imageScaling = .scaleProportionallyDown
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = (isSelected && isEnabled) ? Tokens.selectionFill.cgColor
                                                           : NSColor.clear.cgColor
        let primary = isDestructive ? Tokens.Security.insecure : Tokens.textPrimary
        // L'état désactivé passe par l'opacité et non par une teinte : « Différencier
        // sans couleur » doit rester vrai ici aussi.
        alphaValue = isEnabled ? 1 : 0.35
        glyph.contentTintColor = isDestructive ? primary : Tokens.textSecondary
        label.textColor = primary
        shortcut.textColor = Tokens.textSecondary
        chevron.contentTintColor = Tokens.textSecondary

        let glyphSize: CGFloat = 15
        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - glyphSize) / 2,
                             width: glyphSize, height: glyphSize)
        let left = Tokens.Space.s + glyphSize + Tokens.Space.m
        let rightWidth: CGFloat = 56
        shortcut.frame = NSRect(x: bounds.width - rightWidth - Tokens.Space.s, y: 0,
                                width: rightWidth, height: bounds.height)
        chevron.frame = NSRect(x: bounds.width - 18, y: (bounds.height - 11) / 2, width: 11, height: 11)
        label.frame = NSRect(x: left, y: 0,
                             width: max(0, shortcut.frame.minX - left - Tokens.Space.xs),
                             height: bounds.height)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}
