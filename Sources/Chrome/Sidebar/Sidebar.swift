import AppKit

@MainActor
final class Sidebar: ThemedView {

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onToggleFolder: ((UUID) -> Void)?
    var onTabMenu: ((UUID, NSEvent) -> Void)?
    var onFolderMenu: ((UUID, NSEvent) -> Void)?
    var onDropTab: ((UUID, SidebarDrop) -> Void)?
    /// L'onglet marqué actif, pour savoir quand le faire revenir sous les yeux.
    private var selectedID: UUID?

    /// De quel côté la prochaine liste doit entrer, quand on change d'espace.
    ///
    /// **Le même geste que ranger un onglet, pour le même propos.** Changer d'espace
    /// remplace toute la colonne d'un coup : sans mouvement, on ne sait pas si l'on a
    /// changé d'espace ou si les onglets ont disparu. Le glissement dit d'où vient la
    /// nouvelle liste, exactement comme le déplacement des voisins dit où l'onglet qu'on
    /// traîne va se ranger.
    private var slideFrom: CGFloat = 0
    var onNew: (() -> Void)?
    var onDownloads: (() -> Void)?
    /// La sidebar ne connaît pas la liste des espaces : elle signale le clic et rend la
    /// vue d'ancrage, c'est l'application qui déroule le panneau.
    var onSpaceClick: ((NSView) -> Void)?

    private let spaceSwitcher = SpaceSwitcher()
    private let list = NSView()

    /// Décalage de défilement de la liste, en points. Zéro = première ligne en haut.
    ///
    /// Un `NSScrollView` aurait été le réflexe, et il aurait fallu lui apprendre le
    /// glisser-déposer maison : les lignes se placent à la main, avec des emplacements
    /// figés au début du déplacement. Un décalage à ajouter au curseur coûte trois lignes
    /// et laisse tout le reste intact.
    private var scrollOffset: CGFloat = 0
    private let newTabButton = FooterButton(symbol: "plus", title: "Nouvel onglet", shortcut: "⌘T")
    private let downloadsButton = DownloadButton()

    /// Le seul repère de dépôt restant : le fond qui s'allume sur un dossier. Entre deux
    /// lignes, c'est le **trou** ouvert par les voisins qui fait office de repère — un
    /// trait en plus du trou dirait deux fois la même chose.
    private let dropHighlight = NSView()

    private var items: [SidebarItem] = []
    private var rows: [NSView] = []

    /// Ce qui est en cours de glissement. `gapIndex` est la place que la ligne prendrait
    /// si on relâchait maintenant : c'est **le trou dans la liste** qui sert de repère,
    /// pas un trait. Une ligne qui s'écarte dit où l'onglet va atterrir sans qu'on ait à
    /// interpréter un symbole.
    private var draggingID: UUID?
    private var gapIndex: Int?
    private var proxy: NSImageView?

    /// Les emplacements figés au début du glissement, ligne glissée exclue.
    ///
    /// C'est **la** correction qui rend le geste précis : viser sur les cadres vivants
    /// crée une boucle — ouvrir le trou déplace les voisines, donc la ligne survolée
    /// change, donc le trou se redéplace, et la cible oscille. On mesure donc contre une
    /// disposition qui ne bouge plus, pendant que l'affichage, lui, s'anime.
    private struct Slot {
        let itemIndex: Int
        let minY: CGFloat
        let maxY: CGFloat
        let folderID: UUID?
    }
    private var slots: [Slot] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(spaceSwitcher)
        addSubview(list)
        addSubview(newTabButton)

        dropHighlight.wantsLayer = true
        dropHighlight.layer?.cornerRadius = Tokens.Row.radius
        dropHighlight.layer?.cornerCurve = .continuous
        dropHighlight.isHidden = true
        list.addSubview(dropHighlight)

        addSubview(downloadsButton)
        downloadsButton.onClick = { [weak self] in self?.onDownloads?() }
        newTabButton.onClick = { [weak self] in self?.onNew?() }
        spaceSwitcher.onClick = { [weak self] view in self?.onSpaceClick?(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(space: SpaceSnapshot) {
        spaceSwitcher.update(space)
    }

    /// Annonce que la prochaine liste vient d'un espace situé avant (`-1`) ou après (`1`).
    func slideNext(direction: Int) {
        slideFrom = CGFloat(direction) * bounds.width
    }

    /// `nil` quand rien ne se télécharge : le bouton redevient un simple accès à la page.
    func updateDownloads(progress: Double?) {
        downloadsButton.progress = progress
    }

    func update(items newItems: [SidebarItem], selected: UUID?) {
        // **La colonne se met à jour ; elle ne se refait que si sa forme a changé.**
        //
        // Elle était reconstruite de fond en comble à chaque événement de WebKit — adresse,
        // titre, chargement, favicon —, soit plusieurs dizaines de fois par seconde pendant
        // qu'une page arrive : autant de vues détruites et recréées, pour des lignes qui
        // restaient les mêmes. C'est ce qui coûtait le plus cher dans toute l'interface, et
        // ça ne se voyait nulle part parce que le résultat était juste.
        // Un glissement en attente passe par le chemin long : c'est lui qui repose les
        // lignes, et le chemin court se contente de mettre à jour leur contenu — le
        // mouvement resterait alors en réserve et partirait plus tard, sur un changement
        // qui n'a rien demandé.
        if slideFrom == 0, items.map(\.shape) == newItems.map(\.shape), rows.count == newItems.count {
            items = newItems
            for (index, item) in newItems.enumerated() {
                switch item {
                case .tab(let id, let title, let host, let isLoading, let favicon, _, let isPlaying):
                    (rows[index] as? TabRow)?.update(title: title, host: host,
                                                     isLoading: isLoading, isPlaying: isPlaying,
                                                     favicon: favicon, isSelected: id == selected)
                case .folder(_, let name, let isExpanded, let count):
                    (rows[index] as? FolderRow)?.update(name: name, isExpanded: isExpanded,
                                                        count: count)
                }
            }
            // La ligne active doit rester sous les yeux quand elle change, y compris sur
            // ce chemin : c'est le cas le plus fréquent — changer d'onglet ne change pas
            // la forme de la colonne.
            if selectedID != selected {
                selectedID = selected
                if let selected, let index = newItems.firstIndex(where: { $0.id == selected }) {
                    reveal(index: index)
                    positionRows(animated: false)
                }
            }
            return
        }
        selectedID = selected

        items = newItems
        rows.forEach { $0.removeFromSuperview() }
        rows = newItems.map { item in
            switch item {
            case .tab(let id, let title, let host, let isLoading, let favicon, let depth,
                      let isPlaying):
                let row = TabRow(title: title, host: host, isLoading: isLoading,
                                 isPlaying: isPlaying,
                                 favicon: favicon, depth: depth, isSelected: id == selected)
                row.onMouseDown = { [weak self] event in
                    self?.beginTracking(id: id, isFolder: false, event: event)
                }
                row.onClose = { [weak self] in self?.onCloseTab?(id) }
                row.onContextMenu = { [weak self] event in self?.onTabMenu?(id, event) }
                list.addSubview(row)
                return row

            case .folder(let id, let name, let isExpanded, let count):
                let row = FolderRow(name: name, isExpanded: isExpanded, count: count)
                row.onMouseDown = { [weak self] event in
                    self?.beginTracking(id: id, isFolder: true, event: event)
                }
                row.onContextMenu = { [weak self] event in self?.onFolderMenu?(id, event) }
                list.addSubview(row)
                return row
            }
        }
        // La ligne active doit rester sous les yeux, y compris quand la liste dépasse.
        if let selected, let index = newItems.firstIndex(where: { $0.id == selected }) {
            layoutSubtreeIfNeeded()
            reveal(index: index)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor
        dropHighlight.layer?.backgroundColor = Tokens.selectionFill.cgColor

        let width = bounds.width
        let rowHeight = Tokens.Row.height
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

        // Le pied de la sidebar : l'accès aux téléchargements, seul et discret. C'est
        // aussi là que l'avancement se montre — un fichier qui arrive ne doit pas exiger
        // qu'on ouvre une page pour savoir où il en est.
        let footer = Tokens.Row.height
        downloadsButton.frame = NSRect(x: inset, y: Tokens.Space.s,
                                       width: footer, height: footer)

        let bottom = Tokens.Space.s + footer + Tokens.Space.s
        list.frame = NSRect(x: 0, y: bottom, width: width, height: max(0, top - bottom))
        // La liste coupe ce qui dépasse : sans ça, les onglets en trop descendaient
        // par-dessus le bouton des téléchargements, qui restait cliquable en dessous.
        list.wantsLayer = true
        list.layer?.masksToBounds = true
        clampScroll()
        positionRows(animated: false)
    }

    // MARK: - Défilement

    /// Hauteur qu'occuperaient toutes les lignes, trou de dépôt compris.
    private var contentHeight: CGFloat {
        CGFloat(rows.count + (gapIndex == nil ? 0 : 1)) * Tokens.Row.height
    }

    private var maximumScroll: CGFloat {
        max(0, contentHeight - list.bounds.height)
    }

    private func clampScroll() {
        scrollOffset = min(max(0, scrollOffset), maximumScroll)
    }

    override func scrollWheel(with event: NSEvent) {
        guard maximumScroll > 0 else { return super.scrollWheel(with: event) }
        // Un trackpad compte en points, une molette compte en lignes — et une ligne, ici,
        // c'est une ligne d'onglet. Sans cette conversion, un cran de molette déplaçait la
        // liste d'un point : le défilement existait, mais ne se voyait pas.
        //
        // `scrollingDeltaY` est nul sur certains événements — souris anciennes, événements
        // synthétiques — et il faut alors retomber sur `deltaY`, qui compte en lignes.
        //
        // **Le signe est soustrait, pas ajouté.** `scrollOffset` compte ce qui est passé
        // au-dessus de la liste : le faire croître fait *monter* le contenu. Or macOS a déjà
        // appliqué le réglage « défilement naturel » à `scrollingDeltaY` — deux doigts vers
        // le bas y arrivent positifs, et l'on attend alors que le contenu descende. En
        // additionnant, la colonne partait dans le sens contraire de tout le reste du
        // système, y compris de la page juste à côté d'elle.
        let precise = event.hasPreciseScrollingDeltas && event.scrollingDeltaY != 0
        let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        scrollOffset -= precise ? raw : raw * Tokens.Row.height
        clampScroll()
        positionRows(animated: false)
    }

    /// Ramène une ligne dans la partie visible.
    ///
    /// Sans ça, changer d'onglet au clavier dans une longue liste sélectionnait une ligne
    /// qu'on ne voyait pas : la sidebar disait le contraire de ce que montrait la page.
    private func reveal(index: Int) {
        guard maximumScroll > 0, rows.indices.contains(index) else { return }
        let rowHeight = Tokens.Row.height
        let top = CGFloat(index) * rowHeight
        let bottom = top + rowHeight

        if top < scrollOffset {
            scrollOffset = top
        } else if bottom > scrollOffset + list.bounds.height {
            scrollOffset = bottom - list.bounds.height
        }
        clampScroll()
    }

    /// Pose les lignes de haut en bas, en sautant celle qu'on glisse et en ouvrant un trou
    /// à l'endroit du dépôt. Animé pendant le glissement : c'est ce mouvement des voisins
    /// qui donne la sensation que l'onglet se range vraiment quelque part.
    private func positionRows(animated: Bool) {
        let width = bounds.width
        let inset = Tokens.Space.s
        let rowHeight = Tokens.Row.height

        var cursor = list.bounds.height + scrollOffset
        var frames: [(NSView, NSRect)] = []

        for (index, row) in rows.enumerated() {
            if gapIndex == index { cursor -= rowHeight }
            if items[index].id == draggingID {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            cursor -= rowHeight
            frames.append((row, NSRect(x: inset, y: cursor,
                                       width: width - inset * 2, height: rowHeight - 2)))
        }
        if gapIndex == rows.count { cursor -= rowHeight }

        // Le changement d'espace : les lignes sont posées décalées, puis rejoignent leur
        // place. Même durée et même courbe que le rangement d'un onglet — deux mouvements
        // qui se ressembleraient à moitié se remarqueraient au lieu de se comprendre.
        if slideFrom != 0 {
            let offset = slideFrom
            slideFrom = 0
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                frames.forEach { $0.0.frame = $0.1 }
                return
            }
            frames.forEach { $0.0.frame = $0.1.offsetBy(dx: offset, dy: 0) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.slideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                frames.forEach { $0.0.animator().frame = $0.1 }
            }
            return
        }

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            frames.forEach { $0.0.frame = $0.1 }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            frames.forEach { $0.0.animator().frame = $0.1 }
        }
    }

    /// La durée du mouvement, partagée par le rangement d'un onglet et le changement
    /// d'espace : c'est ce partage qui fait qu'on lit les deux comme un même geste.
    private static let slideDuration: TimeInterval = 0.14

    // MARK: - Glisser-déposer

    /// Clic et glisser partagent le même appui : on ne sait lequel c'est qu'après coup.
    ///
    /// La boucle de suivi vit ici et non dans la ligne : déposer reconstruit toute la
    /// liste, donc une ligne qui suivrait son propre glissement disparaîtrait en cours de
    /// route, avec les événements qu'elle attendait encore.
    private func beginTracking(id: UUID, isFolder: Bool, event: NSEvent) {
        guard let window,
              let index = items.firstIndex(where: { $0.id == id }),
              rows.indices.contains(index) else { return }

        let row = rows[index]
        let start = convert(event.locationInWindow, from: nil)
        let rowFrame = convert(row.frame, from: list)
        // Décalage entre le point saisi et le haut de la ligne : sans lui, la copie
        // sauterait sous le curseur au premier pixel de déplacement.
        let grab = start.y - rowFrame.minY
        var moved = false
        var drop: SidebarDrop?

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: .infinity, mode: .eventTracking) { [weak self] event, stop in
            guard let self, let event else { stop.pointee = true; return }
            let point = self.convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseUp {
                stop.pointee = true
                if moved {
                    self.endDrag()
                    if let drop { self.onDropTab?(id, drop) }
                } else if isFolder {
                    self.onToggleFolder?(id)
                } else {
                    self.onSelectTab?(id)
                }
                return
            }

            // Quelques points de course avant de basculer en glissement, sinon un clic
            // avec la main qui tremble déplacerait un onglet.
            guard moved || abs(point.y - start.y) >= 4 else { return }
            if !moved {
                moved = true
                self.beginDrag(id: id, row: row, frame: rowFrame)
            }

            self.proxy?.frame.origin.y = point.y - grab
            let inList = self.list.convert(point, from: self)
            drop = isFolder ? self.folderTarget(at: inList, dragging: id)
                            : self.dropTarget(at: inList)
            self.showDrop(drop)
        }
    }

    /// Sort la ligne du flux et lui substitue une copie flottante. Une copie plutôt que la
    /// ligne elle-même : la ligne appartient à la liste, qui la repose à chaque mise en
    /// page — la copie, elle, n'obéit qu'au curseur.
    private func beginDrag(id: UUID, row: NSView, frame: NSRect) {
        draggingID = id

        let image = NSImage(size: row.bounds.size)
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: rep)
            image.addRepresentation(rep)
        }

        let floating = NSImageView(frame: frame)
        floating.image = image
        floating.imageScaling = .scaleNone
        floating.wantsLayer = true
        floating.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
        addSubview(floating, positioned: .above, relativeTo: nil)
        proxy = floating

        // Le survol reste allumé sous le curseur qui passe : pendant un glissement il
        // ferait concurrence au trou, qui est le vrai repère.
        setHoverEnabled(false)

        positionRows(animated: false)
        captureSlots()
    }

    private func captureSlots() {
        slots = items.enumerated().compactMap { index, item in
            guard item.id != draggingID, rows.indices.contains(index) else { return nil }
            let frame = rows[index].frame
            var folderID: UUID?
            if case .folder(let id, _, _, _) = item { folderID = id }
            return Slot(itemIndex: index, minY: frame.minY, maxY: frame.maxY, folderID: folderID)
        }
    }

    private func setHoverEnabled(_ enabled: Bool) {
        for row in rows {
            (row as? TabRow)?.hoverEnabled = enabled
            (row as? FolderRow)?.hoverEnabled = enabled
        }
    }

    private func endDrag() {
        proxy?.removeFromSuperview()
        proxy = nil
        draggingID = nil
        gapIndex = nil
        slots = []
        dropHighlight.isHidden = true
        rows.forEach { $0.isHidden = false }
        setHoverEnabled(true)
    }

    private func dropTarget(at point: NSPoint) -> SidebarDrop? {
        guard let first = slots.first, let last = slots.last else { return .end }
        if point.y > first.maxY { return insertion(from: first.itemIndex) }
        if point.y < last.minY { return .end }

        for slot in slots {
            guard point.y >= slot.minY, point.y <= slot.maxY else { continue }
            if let folderID = slot.folderID {
                // La bande centrale fait entrer dans le dossier, les bords insèrent
                // autour : sans cette distinction, on ne pourrait jamais déposer juste
                // au-dessus d'un dossier.
                let margin = (slot.maxY - slot.minY) * 0.3
                if point.y > slot.minY + margin, point.y < slot.maxY - margin {
                    return .into(folderID)
                }
            }
            let middle = (slot.minY + slot.maxY) / 2
            return insertion(from: point.y > middle ? slot.itemIndex : slot.itemIndex + 1)
        }
        // Entre deux emplacements — l'espace d'un séparateur : on rattache au suivant.
        return insertion(from: slots.first { $0.maxY < point.y }?.itemIndex ?? 0)
    }

    /// Traduit « à partir de la ligne n » en cible, en sautant dossiers, séparateurs et la
    /// ligne glissée elle-même, et en tombant sur la fin de liste quand il n'y a plus rien.
    private func insertion(from index: Int) -> SidebarDrop {
        for item in items.dropFirst(index) {
            if case .tab(let id, _, _, _, _, _, _) = item, id != draggingID { return .before(id) }
        }
        return .end
    }

    /// Les dossiers ne visent que d'autres dossiers : on cherche celui sous le curseur,
    /// et à défaut on tombe en fin de liste des dossiers.
    private func folderTarget(at point: NSPoint, dragging id: UUID) -> SidebarDrop? {
        let folderSlots = slots.filter { $0.folderID != nil }
        guard let first = folderSlots.first else { return .folderEnd }
        if point.y > first.maxY { return .folderBefore(first.folderID!) }
        for slot in folderSlots {
            guard point.y >= slot.minY, point.y <= slot.maxY else { continue }
            let middle = (slot.minY + slot.maxY) / 2
            if point.y > middle { return .folderBefore(slot.folderID!) }
            let next = folderSlots.first { $0.minY < slot.minY }
            return next.map { .folderBefore($0.folderID!) } ?? .folderEnd
        }
        return .folderEnd
    }

    private func showDrop(_ drop: SidebarDrop?) {
        var newGap: Int?
        var highlight: Int?

        switch drop {
        case .into(let folderID):
            highlight = items.firstIndex { $0.id == folderID }
        case .before(let tabID):
            newGap = items.firstIndex { $0.id == tabID }
        case .end:
            newGap = rows.count
        case .folderBefore(let folderID):
            newGap = items.firstIndex { $0.id == folderID }
        case .folderEnd:
            // Juste après le dernier dossier, pas en bas de la liste : c'est là que le
            // dossier atterrira réellement.
            newGap = items.lastIndex { if case .folder = $0 { return true } else { return false } }
                .map { $0 + 1 } ?? rows.count
        case nil:
            break
        }

        if let highlight, rows.indices.contains(highlight) {
            dropHighlight.frame = rows[highlight].frame
            dropHighlight.isHidden = false
        } else {
            dropHighlight.isHidden = true
        }

        guard newGap != gapIndex else { return }
        gapIndex = newGap
        positionRows(animated: true)
    }
}

/// Le bouton des téléchargements, avec son avancement.
///
/// Il ne double pas l'entrée du menu : celle-ci ouvre la page, celui-ci **montre l'état**.
/// Un anneau qui se remplit dit qu'un fichier arrive sans qu'on ait à aller le vérifier.
