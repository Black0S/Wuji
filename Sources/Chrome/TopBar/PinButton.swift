import AppKit

/// L'icône d'une extension épinglée dans la barre du haut.
///
/// **Dans son propre fichier**, parce qu'elle ne partage rien avec la barre sinon la place
/// qu'elle y occupe : son dessin, sa pastille et sa taille sont un sujet à part, et c'est
/// celui qui a le plus bougé.

@MainActor
final class PinButton: NSView {

    let id: String
    var onClick: (() -> Void)?
    var onContextMenu: ((NSView) -> Void)?

    private let icon = NSImageView()
    /// La pastille, en bas à droite de l'icône. **C'est souvent la seule chose qu'on
    /// regarde** — le nombre de requêtes arrêtées, d'articles non lus, d'onglets rangés —
    /// et une extension épinglée sans elle perd la moitié de ce qu'elle sait dire.
    private let badge = NSTextField(labelWithString: "")

    init(pin: ContentTopBar.Pin) {
        id = pin.id
        super.init(frame: .zero)
        wantsLayer = true

        icon.image = pin.icon
        // **`…UpOrDown`, et une boîte fixe.** Une icône d'extension arrive avec la taille
        // que WebKit lui donne, et cette taille n'est pas la même selon le moment : au
        // lancement, l'action de l'onglet n'est pas encore résolue et c'est l'icône du
        // manifeste qui répond — souvent 128 points de côté. `scaleProportionallyDown` la
        // réduisait alors à la boîte entière du bouton, tandis qu'une icône déjà petite
        // restait petite. D'où le défaut : trop grosse à l'ouverture, normale après avoir
        // décroché puis réépinglé, c'est-à-dire une fois l'action résolue.
        //
        // Ajuster dans les deux sens dans une boîte fixe rend le résultat indépendant de
        // ce que WebKit a répondu et du moment où il a répondu.
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerCurve = .continuous
        badge.stringValue = pin.badge
        badge.isHidden = pin.badge.isEmpty
        addSubview(badge)

        toolTip = pin.label
        setAccessibilityLabel(pin.badge.isEmpty ? pin.label : "\(pin.label) — \(pin.badge)")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Change ce que le bouton montre sans le remplacer : l'icône d'une extension et sa
    /// pastille dépendent de la page ouverte, et changent donc bien plus souvent que la
    /// liste des extensions épinglées.
    func apply(_ pin: ContentTopBar.Pin) {
        if icon.image !== pin.icon { icon.image = pin.icon }
        if badge.stringValue != pin.badge {
            badge.stringValue = pin.badge
            badge.isHidden = pin.badge.isEmpty
            needsLayout = true
        }
        toolTip = pin.label
        setAccessibilityLabel(pin.badge.isEmpty ? pin.label : "\(pin.label) — \(pin.badge)")
    }

    /// Le côté du dessin, à l'intérieur du bouton. C'est la taille à laquelle AppKit rend
    /// les symboles des boutons voisins : une icône d'extension qui remplirait toute la
    /// boîte pèserait visiblement plus lourd qu'eux, dans une rangée qui doit se lire comme
    /// une seule.
    static let glyph: CGFloat = 16

    override func layout() {
        super.layout()
        let inset = ((bounds.width - Self.glyph) / 2).rounded()
        icon.frame = bounds.insetBy(dx: inset, dy: (bounds.height - Self.glyph) / 2)
        badge.textColor = Tokens.chromeBackground
        badge.backgroundColor = Tokens.textPrimary
        badge.drawsBackground = true
        badge.layer?.backgroundColor = Tokens.textPrimary.cgColor

        // **La pastille mord le coin, elle ne couvre pas l'icône.**
        //
        // Posée à la base du bouton et haute de onze points, elle mangeait la moitié du
        // bouclier d'uBlock — on lisait le compte et plus l'extension. Elle déborde donc
        // vers le bas et vers la droite : la vue ne rogne pas ses sous-vues, et ce
        // débordement est ce qui rend les deux lisibles à la fois.
        let height: CGFloat = 10
        let width = max(height, badge.intrinsicContentSize.width + 5)
        badge.frame = NSRect(x: bounds.maxX - width + 3, y: -2, width: width, height: height)
        badge.layer?.cornerRadius = height / 2
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(self) }

    /// `NSView` répond au clic droit par le menu contextuel d'AppKit ; on l'intercepte
    /// pour poser le nôtre, qui parle de cette extension-là.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
