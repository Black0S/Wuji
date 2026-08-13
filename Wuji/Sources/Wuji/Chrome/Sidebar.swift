import AppKit

/// L'espace courant, tel que la sidebar a besoin de le connaître : un nom et une forme.
struct SpaceSnapshot {
    let name: String
    let symbol: String
    let color: NSColor?
}

/// Une ligne de la sidebar. Volontairement pauvre : ni `Tab`, ni `TabFolder`, ni index —
/// une **identité** et de quoi dessiner. C'est la frontière entre le modèle et son rendu.
enum SidebarItem {
    case tab(id: UUID, title: String, host: String, isLoading: Bool, favicon: NSImage?, depth: Int)
    case folder(id: UUID, name: String, isExpanded: Bool, count: Int)
    /// Entre le bloc épinglé et le reste. Sans lui, deux listes de titres identiques se
    /// lisent comme une seule.
    case separator

    var id: UUID? {
        switch self {
        case .tab(let id, _, _, _, _, _): return id
        case .folder(let id, _, _, _):    return id
        case .separator:                  return nil
        }
    }
}

/// Où l'on dépose un onglet en fin de glissement.
enum SidebarDrop {
    case before(UUID)
    case into(UUID)
    case end
}

/// La sidebar **ancrée**. Le contenu commence après elle, il ne passe pas dessous —
/// la page n'est jamais partiellement masquée.
@MainActor
final class Sidebar: ThemedView {

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onToggleFolder: ((UUID) -> Void)?
    var onTabMenu: ((UUID, NSEvent) -> Void)?
    var onFolderMenu: ((UUID, NSEvent) -> Void)?
    var onDropTab: ((UUID, SidebarDrop) -> Void)?
    var onNew: (() -> Void)?
    /// La sidebar ne connaît pas la liste des espaces : elle signale le clic et rend la
    /// vue d'ancrage, c'est l'application qui déroule le panneau.
    var onSpaceClick: ((NSView) -> Void)?

    private let spaceSwitcher = SpaceSwitcher()
    private let list = NSView()
    private let newTabButton = FooterButton(symbol: "plus", title: "Nouvel onglet", shortcut: "⌘T")

    /// Repères de dépôt : un trait pour « entre deux lignes », un fond pour « dans ce
    /// dossier ». Deux formes distinctes parce que ce sont deux gestes distincts — un
    /// repère unique obligerait à deviner lequel des deux va se produire.
    private let dropLine = NSView()
    private let dropHighlight = NSView()

    private var items: [SidebarItem] = []
    private var rows: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(spaceSwitcher)
        addSubview(list)
        addSubview(newTabButton)

        dropHighlight.wantsLayer = true
        dropHighlight.layer?.cornerRadius = Tokens.Radius.pill - 4
        dropHighlight.layer?.cornerCurve = .continuous
        dropHighlight.isHidden = true
        list.addSubview(dropHighlight)

        dropLine.wantsLayer = true
        dropLine.isHidden = true
        list.addSubview(dropLine)

        newTabButton.onClick = { [weak self] in self?.onNew?() }
        spaceSwitcher.onClick = { [weak self] view in self?.onSpaceClick?(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(space: SpaceSnapshot) {
        spaceSwitcher.update(space)
    }

    func update(items newItems: [SidebarItem], selected: UUID?) {
        items = newItems
        rows.forEach { $0.removeFromSuperview() }
        rows = newItems.map { item in
            switch item {
            case .tab(let id, let title, let host, let isLoading, let favicon, let depth):
                let row = TabRow(title: title, host: host, isLoading: isLoading,
                                 favicon: favicon, depth: depth, isSelected: id == selected)
                row.onMouseDown = { [weak self] event in self?.beginTracking(id: id, event: event) }
                row.onClose = { [weak self] in self?.onCloseTab?(id) }
                row.onContextMenu = { [weak self] event in self?.onTabMenu?(id, event) }
                list.addSubview(row)
                return row

            case .folder(let id, let name, let isExpanded, let count):
                let row = FolderRow(name: name, isExpanded: isExpanded, count: count)
                row.onClick = { [weak self] in self?.onToggleFolder?(id) }
                row.onContextMenu = { [weak self] event in self?.onFolderMenu?(id, event) }
                list.addSubview(row)
                return row

            case .separator:
                let line = NSView()
                line.wantsLayer = true
                list.addSubview(line)
                return line
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor
        dropLine.layer?.backgroundColor = Tokens.textPrimary.cgColor
        dropHighlight.layer?.backgroundColor = Tokens.selectionFill.cgColor

        let width = bounds.width
        let rowHeight = Tokens.Chrome.rowHeight
        let inset = Tokens.Space.s

        // Sous les feux de circulation, que macOS place lui-même.
        var top = bounds.height - Tokens.Chrome.trafficLights

        spaceSwitcher.frame = NSRect(x: inset, y: top - rowHeight,
                                     width: width - inset * 2, height: rowHeight)
        top -= rowHeight + Tokens.Space.s

        // « Nouvel onglet » entre l'espace et la liste : l'action se lit avec l'espace
        // auquel elle ajoute, et la liste garde le bas de la colonne pour elle seule.
        newTabButton.frame = NSRect(x: inset, y: top - rowHeight,
                                    width: width - inset * 2, height: rowHeight)
        top -= rowHeight + Tokens.Space.m

        list.frame = NSRect(x: 0, y: Tokens.Space.s, width: width,
                            height: max(0, top - Tokens.Space.s))

        var cursor = list.bounds.height
        for (index, row) in rows.enumerated() {
            if case .separator = items[index] {
                cursor -= Tokens.Space.m
                row.layer?.backgroundColor = Tokens.separator.cgColor
                row.frame = NSRect(x: inset, y: cursor + Tokens.Space.m / 2,
                                   width: width - inset * 2, height: 1)
                continue
            }
            cursor -= rowHeight
            row.frame = NSRect(x: inset, y: cursor, width: width - inset * 2, height: rowHeight - 2)
        }
    }

    // MARK: - Glisser-déposer

    /// Clic et glisser partagent le même appui : on ne sait lequel c'est qu'après coup.
    ///
    /// La boucle de suivi vit ici et non dans la ligne : déposer reconstruit toute la
    /// liste, donc une ligne qui suivrait son propre glissement disparaîtrait en cours de
    /// route, avec les événements qu'elle attendait encore.
    private func beginTracking(id: UUID, event: NSEvent) {
        guard let window else { return }
        let start = list.convert(event.locationInWindow, from: nil)
        var moved = false
        var drop: SidebarDrop?

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self, let event else { stop.pointee = true; return }

            if event.type == .leftMouseUp {
                stop.pointee = true
                self.clearDropMarks()
                if moved {
                    if let drop { self.onDropTab?(id, drop) }
                } else {
                    self.onSelectTab?(id)
                }
                return
            }

            let point = self.list.convert(event.locationInWindow, from: nil)
            // Quelques points de course avant de basculer en glissement, sinon un clic
            // avec la main qui tremble déplacerait un onglet.
            guard moved || abs(point.y - start.y) >= 4 else { return }
            moved = true
            drop = self.dropTarget(at: point, dragging: id)
            self.showDropMark(for: drop)
        }
    }

    private func dropTarget(at point: NSPoint, dragging id: UUID) -> SidebarDrop? {
        for (index, item) in items.enumerated() {
            guard rows.indices.contains(index) else { continue }
            let frame = rows[index].frame
            guard point.y >= frame.minY, point.y <= frame.maxY else { continue }

            switch item {
            case .folder(let folderID, _, _, _):
                // La bande centrale fait entrer dans le dossier, les bords insèrent
                // autour : sans cette distinction, on ne pourrait jamais déposer juste
                // au-dessus d'un dossier.
                let margin = frame.height * 0.3
                if point.y > frame.minY + margin, point.y < frame.maxY - margin {
                    return .into(folderID)
                }
                return point.y > frame.midY ? insertion(from: index) : insertion(from: index + 1)

            case .tab(let tabID, _, _, _, _, _):
                guard tabID != id else { return nil }
                return point.y > frame.midY ? .before(tabID) : insertion(from: index + 1)

            case .separator:
                return insertion(from: index + 1)
            }
        }
        return .end
    }

    /// Traduit « à partir de la ligne n » en cible, en sautant dossiers et séparateurs, et
    /// en tombant sur la fin de liste quand il n'y a plus d'onglet après.
    private func insertion(from index: Int) -> SidebarDrop {
        for item in items.dropFirst(index) {
            if case .tab(let id, _, _, _, _, _) = item { return .before(id) }
        }
        return .end
    }

    private func showDropMark(for drop: SidebarDrop?) {
        clearDropMarks()
        guard let drop else { return }
        switch drop {
        case .into(let folderID):
            guard let index = items.firstIndex(where: { $0.id == folderID }),
                  rows.indices.contains(index) else { return }
            dropHighlight.frame = rows[index].frame
            dropHighlight.isHidden = false

        case .before(let tabID):
            guard let index = items.firstIndex(where: { $0.id == tabID }),
                  rows.indices.contains(index) else { return }
            let frame = rows[index].frame
            dropLine.frame = NSRect(x: frame.minX, y: frame.maxY, width: frame.width, height: 2)
            dropLine.isHidden = false

        case .end:
            guard let last = rows.last else { return }
            dropLine.frame = NSRect(x: last.frame.minX, y: last.frame.minY - 2,
                                    width: last.frame.width, height: 2)
            dropLine.isHidden = false
        }
    }

    private func clearDropMarks() {
        dropLine.isHidden = true
        dropHighlight.isHidden = true
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
    private var tint: NSColor?

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
        tint = space.color
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
        // La couleur ne touche que le symbole : le nom reste monochrome, sa lisibilité
        // ne doit pas dépendre d'une teinte choisie par l'utilisateur.
        glyph.contentTintColor = tint ?? Tokens.textPrimary
        label.textColor = Tokens.textPrimary
        chevron.contentTintColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let left = Tokens.Space.s + 14 + Tokens.Space.m
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: bounds.width - left - 28, height: 16)
        chevron.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }


    /// La fenêtre est déplaçable par son fond, ce qui est commode sur les zones vides de
    /// la sidebar — mais désastreux sur une ligne : le glissement déplacerait la fenêtre
    /// au lieu de l'onglet. Chaque ligne interactive doit donc s'en défendre.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?(self) }
}

/// Un dossier. Le chevron dit l'état, le compte dit ce qu'il y a dedans quand il est
/// replié — sans lui, un dossier fermé ne dirait rien de ce qu'il contient.
@MainActor
private final class FolderRow: ThemedView {

    var onClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private let chevron = NSImageView()
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(name: String, isExpanded: Bool, count tabCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: isExpanded ? "Replier" : "Déplier")
        glyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        label.stringValue = name
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        count.stringValue = isExpanded ? "" : "\(tabCount)"
        count.font = .systemFont(ofSize: 12, weight: .regular)
        count.alignment = .right
        [chevron, glyph, label, count].forEach { addSubview($0) }
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
        layer?.backgroundColor = isHovered ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        chevron.contentTintColor = Tokens.textSecondary
        glyph.contentTintColor = Tokens.textSecondary
        label.textColor = Tokens.textPrimary
        count.textColor = Tokens.textSecondary

        chevron.frame = NSRect(x: Tokens.Space.xs, y: (bounds.height - 10) / 2, width: 10, height: 10)
        glyph.frame = NSRect(x: Tokens.Space.m + 4, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let left = Tokens.Space.m + 4 + 14 + Tokens.Space.s
        count.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 15) / 2, width: 22, height: 15)
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: count.frame.minX - left - Tokens.Space.xs, height: 16)
    }


    /// La fenêtre est déplaçable par son fond, ce qui est commode sur les zones vides de
    /// la sidebar — mais désastreux sur une ligne : le glissement déplacerait la fenêtre
    /// au lieu de l'onglet. Chaque ligne interactive doit donc s'en défendre.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}

/// Un onglet. La favicon est la seule couleur admise dans le chrome — et c'est cohérent :
/// elle appartient au site, pas à l'interface (spec §4.6).
@MainActor
private final class TabRow: ThemedView {

    var onMouseDown: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let isSelected: Bool
    private let depth: Int
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, host: String, isLoading: Bool, favicon: NSImage?,
         depth: Int, isSelected: Bool) {
        self.isSelected = isSelected
        self.depth = depth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        if let favicon {
            icon.image = favicon
        } else {
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = Tokens.textSecondary
        }
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        label.stringValue = isLoading ? "· \(title)" : title
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

        let indent = CGFloat(depth) * 16
        let iconSize: CGFloat = 16
        icon.frame = NSRect(x: Tokens.Space.s + indent, y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
        let left = Tokens.Space.s + indent + iconSize + Tokens.Space.m
        label.frame = NSRect(x: left, y: (bounds.height - 16) / 2,
                             width: max(0, bounds.width - left - 26), height: 16)
        close.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }


    /// La fenêtre est déplaçable par son fond, ce qui est commode sur les zones vides de
    /// la sidebar — mais désastreux sur une ligne : le glissement déplacerait la fenêtre
    /// au lieu de l'onglet. Chaque ligne interactive doit donc s'en défendre.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
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


    /// La fenêtre est déplaçable par son fond, ce qui est commode sur les zones vides de
    /// la sidebar — mais désastreux sur une ligne : le glissement déplacerait la fenêtre
    /// au lieu de l'onglet. Chaque ligne interactive doit donc s'en défendre.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
