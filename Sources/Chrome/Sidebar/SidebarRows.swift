import AppKit

/// Les pièces de la colonne : les rangées et les boutons qu'elle empile.
///
/// **Séparées de la colonne elle-même**, qui n'en tenait plus la moitié : mille lignes dans
/// un fichier, dont quatre cents pour des vues qui ne parlent qu'à elles-mêmes. Ce qui
/// change ici — le dessin d'une ligne, sa hauteur, son survol — ne touche jamais à la
/// disposition d'ensemble, et l'inverse est vrai aussi.
///
/// Elles restent internes au module : rien hors du chrome n'a de raison de les construire.

@MainActor
final class DownloadButton: ThemedView {

    var onClick: (() -> Void)?
    var progress: Double? { didSet { needsDisplay = true } }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Tokens.selectionFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Tokens.Row.radius,
                         yRadius: Tokens.Row.radius).fill()
        }

        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 9

        if let progress {
            // L'anneau d'avancement remplace le cercle du glyphe : deux cercles concentriques
            // se liraient comme un chargement indéterminé.
            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.5
            Tokens.separator.setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(progress), clockwise: true)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            Tokens.textPrimary.setStroke()
            arc.stroke()
        }

        // La teinte passe par la configuration du symbole, pas par `set()` : une couleur
        // posée dans le contexte ne colore pas une image, même en mode gabarit. C'est ce
        // qui laissait le glyphe identique en clair et en sombre.
        let tint = (isHovered || progress != nil) ? Tokens.textPrimary : Tokens.textSecondary
        let configuration = NSImage.SymbolConfiguration(pointSize: progress == nil ? 15 : 9,
                                                        weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let glyph = NSImage(systemSymbolName: progress == nil ? "arrow.down.circle" : "arrow.down",
                                  accessibilityDescription: "Téléchargements")?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                              width: size.width, height: size.height))
    }
}

// MARK: - Lignes

/// Le sélecteur d'espace, en tête de sidebar : la forme de l'espace courant, son nom, et
/// un chevron qui annonce qu'il y a un choix derrière.
@MainActor
final class SpaceSwitcher: ThemedView {

    var onClick: ((NSView) -> Void)?

    var hoverEnabled = true

    private let glyph = NSImageView()
    private let label = InsetTextField.label(weight: .medium)
    private let chevron = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Row.radius
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

    override func mouseEntered(with event: NSEvent) {
        guard hoverEnabled else { return }
        isHovered = true
        needsLayout = true
    }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsLayout = true }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isHovered ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        glyph.contentTintColor = Tokens.textPrimary
        label.textColor = Tokens.textPrimary
        chevron.contentTintColor = Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let left = Tokens.Space.s + 14 + Tokens.Space.m
        // Cadre pleine hauteur : une étiquette d'une ligne se centre dans son cadre,
        // alors qu'un cadre à hauteur fixe la laisse flotter au-dessus du glyphe.
        label.frame = NSRect(x: left, y: 0, width: bounds.width - left - 28, height: bounds.height)
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
final class FolderRow: ThemedView {

    var onMouseDown: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    var hoverEnabled = true { didSet { if !hoverEnabled { isHovered = false; needsLayout = true } } }

    private let chevron = NSImageView()
    private let glyph = NSImageView()
    private let label = InsetTextField.label(weight: .medium)
    private let count = InsetTextField.label(size: 12, alignment: .right)
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Met à jour sans se refaire. Rien ici ne touche à la hiérarchie de vues : c'est ce
    /// qui permet à la colonne de suivre une page qui charge sans se reconstruire.
    func update(name: String, isExpanded: Bool, count tabCount: Int) {
        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: isExpanded ? "Replier" : "Déplier")
        label.stringValue = name
        count.stringValue = isExpanded ? "" : "\(tabCount)"
        needsLayout = true
    }

    init(name: String, isExpanded: Bool, count tabCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Row.radius
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        update(name: name, isExpanded: isExpanded, count: tabCount)
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

    override func mouseEntered(with event: NSEvent) {
        guard hoverEnabled else { return }
        isHovered = true
        needsLayout = true
    }
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
        count.frame = NSRect(x: bounds.width - 30, y: 0, width: 22, height: bounds.height)
        label.frame = NSRect(x: left, y: 0,
                             width: count.frame.minX - left - Tokens.Space.xs, height: bounds.height)
    }


    /// La fenêtre est déplaçable par son fond, ce qui est commode sur les zones vides de
    /// la sidebar — mais désastreux sur une ligne : le glissement déplacerait la fenêtre
    /// au lieu de l'onglet. Chaque ligne interactive doit donc s'en défendre.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}

/// Un onglet. La favicon est la seule couleur admise dans le chrome — et c'est cohérent :
/// elle appartient au site, pas à l'interface (spec §4.6).
@MainActor
final class TabRow: ThemedView {

    var onMouseDown: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    var hoverEnabled = true { didSet { if !hoverEnabled { isHovered = false; needsLayout = true } } }

    private let icon = NSImageView()
    private let label = InsetTextField.label()
    private let close = NSButton()
    private let speaker = NSImageView()
    private var isPlaying: Bool
    private var isSelected: Bool
    private let depth: Int
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Met à jour sans se refaire. Rien ici ne touche à la hiérarchie de vues : c'est ce
    /// qui permet à la colonne de suivre une page qui charge sans se reconstruire.
    ///
    /// L'image n'est réaffectée que si elle a changé : une favicon posée à l'identique
    /// invalide quand même la vue, et la colonne se redessinait pour rien.
    func update(title: String, host: String, isLoading: Bool, isPlaying: Bool,
                favicon: NSImage?, isSelected: Bool) {
        let wanted = favicon ?? Self.placeholder
        if icon.image !== wanted {
            icon.image = wanted
            icon.contentTintColor = favicon == nil ? Tokens.textSecondary : nil
        }
        let text = isLoading ? "· \(title)" : title
        if label.stringValue != text { label.stringValue = text }
        if speaker.isHidden == isPlaying { speaker.isHidden = !isPlaying }
        guard self.isPlaying != isPlaying || self.isSelected != isSelected else { return }
        self.isPlaying = isPlaying
        self.isSelected = isSelected
        needsLayout = true
    }

    /// Le globe des pages sans favicon, dessiné une fois : il était refait à chaque ligne
    /// et à chaque mise à jour, pour la même image.
    private static let placeholder = NSImage(systemSymbolName: "globe",
                                             accessibilityDescription: nil)

    init(title: String, host: String, isLoading: Bool, isPlaying: Bool = false,
         favicon: NSImage?,
         depth: Int, isSelected: Bool) {
        self.isPlaying = isPlaying
        self.isSelected = isSelected
        self.depth = depth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Row.radius
        layer?.cornerCurve = .continuous

        if let favicon {
            icon.image = favicon
        } else {
            icon.image = Self.placeholder
            icon.contentTintColor = Tokens.textSecondary
        }
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        // Le haut-parleur est à droite, là où l'œil descend pour chercher lequel des
        // onglets chante — pas collé au titre, où il déplacerait le texte d'une ligne à
        // l'autre et casserait la colonne. Le point de chargement, lui, reste un préfixe :
        // il est passager, et il n'y a rien à viser.
        //
        // Rien ne dit « en veille » : un onglet endormi doit se comporter comme les
        // autres, il se réveille au clic.
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

        speaker.image = NSImage(systemSymbolName: "speaker.wave.2",
                                accessibilityDescription: "Lecture en cours")
        speaker.imageScaling = .scaleProportionallyDown
        speaker.isHidden = !isPlaying
        addSubview(speaker)
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

    override func mouseEntered(with event: NSEvent) {
        guard hoverEnabled else { return }
        isHovered = true
        needsLayout = true
    }
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
        // Le haut-parleur ne cède plus la place à la croix : il se décale à sa gauche.
        // Le faire disparaître au survol était une erreur — on survole justement la
        // colonne pour trouver l'onglet qui chante, et le repère s'effaçait au moment où
        // l'on en avait besoin.
        speaker.isHidden = !isPlaying
        speaker.contentTintColor = Tokens.textSecondary

        let indent = CGFloat(depth) * Tokens.Row.indent
        let iconSize: CGFloat = 16
        icon.frame = NSRect(x: Tokens.Space.s + indent, y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
        let left = Tokens.Space.s + indent + iconSize + Tokens.Space.m
        let reserved: CGFloat = (isPlaying && isHovered) ? 48 : 26
        label.frame = NSRect(x: left, y: 0,
                             width: max(0, bounds.width - left - reserved), height: bounds.height)
        close.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 18) / 2, width: 18, height: 18)
        speaker.frame = NSRect(x: bounds.width - (isHovered ? 45 : 23),
                               y: (bounds.height - 13) / 2, width: 14, height: 13)
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
final class FooterButton: ThemedView {
    var onClick: (() -> Void)?

    private let glyph = NSImageView()
    private let label = InsetTextField.label()
    private let shortcut = InsetTextField.label(size: 12, alignment: .right)

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
        label.frame = NSRect(x: Tokens.Space.s + 14 + Tokens.Space.s, y: 0,
                             width: bounds.width - 90, height: bounds.height)
        shortcut.frame = NSRect(x: bounds.width - 44, y: 0, width: 36, height: bounds.height)
    }


    /// La fenêtre est déplaçable par son fond, ce qui est commode sur les zones vides de
    /// la sidebar — mais désastreux sur une ligne : le glissement déplacerait la fenêtre
    /// au lieu de l'onglet. Chaque ligne interactive doit donc s'en défendre.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
