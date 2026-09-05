import AppKit

/// La complétion des identifiants : la liste qui s'ouvre sous le champ.
///
/// **Une vue de la fenêtre, pas un menu.** Un `NSMenu` — ou n'importe quelle fenêtre qui
/// prend le clavier — avalerait les frappes suivantes : on cliquerait dans le champ, la
/// liste s'ouvrirait, et taper son identifiant ne l'écrirait plus nulle part. Ici la vue est
/// posée dans la fenêtre au-dessus de la page ; elle ne devient jamais premier répondant,
/// donc la page garde le clavier et la saisie continue pendant que la liste se filtre.
///
/// **Elle ne propose que des noms.** Le secret ne quitte le coffre qu'au moment de
/// remplir, pour un compte nommé — savoir *qu'il y a* un identifiant suffit à proposer.
/// Une liste qui porterait les mots de passe les mettrait à l'écran de quiconque passe
/// derrière, et dans une capture d'écran.
@MainActor
final class PasswordSuggestions: ThemedView {

    /// Ce qu'une ligne propose.
    ///
    /// **Le coffre fermé n'est pas une absence de proposition** : c'est une proposition
    /// d'un autre genre. Une carte vide laisserait croire qu'aucun identifiant n'existe
    /// pour ce site, alors qu'il y en a peut-être dix derrière un mot de passe maître —
    /// et il n'y aurait, à cet endroit, aucun moyen de s'en apercevoir.
    enum Proposal: Equatable {
        case account(String)
        case unlock
    }

    /// Le compte choisi. C'est tout ce qui sort d'ici : l'appelant va chercher le secret.
    var onChoose: ((String) -> Void)?
    /// La ligne « Déverrouiller le coffre… » a été prise.
    var onUnlock: (() -> Void)?

    private let card = NSView()
    private let caption = InsetTextField.label(size: 11)
    private var rows: [SuggestionRow] = []
    private var proposals: [Proposal] = []
    private var selection = 0

    /// L'ancrage, en coordonnées de cette vue : le rectangle du champ visé.
    private var anchor: NSRect = .zero

    private static let rowHeight = Tokens.Row.height
    private static let captionHeight: CGFloat = 22
    /// Au-delà, ce n'est plus une complétion mais une liste à parcourir — et la page des
    /// réglages la montre déjà, mieux.
    private static let maxRows = 6
    private static let minWidth: CGFloat = 220
    private static let maxWidth: CGFloat = 380

    var isOpen: Bool { !isHidden }

    nonisolated(unsafe) private var keyMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        // **Le clavier n'arrive jamais ici par le chemin ordinaire** : la page garde le
        // premier répondant, c'est tout l'intérêt. On guette donc les frappes en amont, et
        // on ne retient que celles qui appartiennent à la liste tant qu'elle est ouverte.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, MainActor.assumeIsolated({ handle(event) }) else { return event }
            return nil
        }

        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.pill
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = false
        Tokens.applyChromeShadow(to: card)
        addSubview(card)

        caption.stringValue = "Coffre de Wuji"
        card.addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { keyMonitor.map(NSEvent.removeMonitor) }

    // MARK: - Ouvrir, fermer

    /// Montre les comptes proposés sous le champ.
    ///
    /// `anchor` est le rectangle du champ **dans cette vue**. La conversion depuis la page
    /// appartient à l'appelant : lui seul connaît la vue web, son zoom et son cadre.
    func show(_ proposals: [Proposal], under anchor: NSRect) {
        guard !proposals.isEmpty else { return dismiss() }
        self.proposals = Array(proposals.prefix(Self.maxRows))
        self.anchor = anchor
        selection = 0
        rebuild()
        isHidden = false
        needsLayout = true
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        proposals = []
        rows.forEach { $0.removeFromSuperview() }
        rows = []
    }

    /// Le clavier, pendant que la page garde le focus.
    ///
    /// **On n'intercepte que trois touches, et seulement quand la liste est ouverte.**
    /// Flèches et `↵` n'ont pas de sens dans un champ de connexion tant qu'une proposition
    /// est en vue ; tout le reste doit continuer d'arriver à la page, sans quoi la
    /// complétion empêcherait d'écrire ce qu'elle est censée compléter.
    func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        switch event.keyCode {
        case 53:  dismiss(); return true                       // échap
        case 125: move(by: 1); return true                      // bas
        case 126: move(by: -1); return true                     // haut
        case 36, 76:                                            // entrée
            guard proposals.indices.contains(selection) else { return false }
            let chosen = proposals[selection]
            dismiss()
            take(chosen)
            return true
        default:  return false
        }
    }

    private func take(_ proposal: Proposal) {
        switch proposal {
        case .account(let user): onChoose?(user)
        case .unlock:            onUnlock?()
        }
    }

    private func move(by delta: Int) {
        guard !proposals.isEmpty else { return }
        selection = (selection + delta + proposals.count) % proposals.count
        for (index, row) in rows.enumerated() { row.isSelected = index == selection }
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = proposals.enumerated().map { index, proposal in
            let row = SuggestionRow(proposal)
            row.isSelected = index == selection
            row.onHover = { [weak self] in
                guard let self else { return }
                selection = index
                for (position, other) in rows.enumerated() { other.isSelected = position == index }
            }
            row.onClick = { [weak self] in
                self?.dismiss()
                self?.take(proposal)
            }
            card.addSubview(row)
            return row
        }
    }

    // MARK: - Géométrie

    override func layout() {
        super.layout()
        guard !isHidden else { return }

        card.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        card.layer?.borderColor = Tokens.chromeHairline.cgColor
        caption.textColor = Tokens.textSecondary

        let padding = Tokens.Card.padding
        let width = min(Self.maxWidth, max(Self.minWidth, anchor.width))
        let height = padding * 2 + Self.captionHeight
            + CGFloat(rows.count) * Self.rowHeight

        // Sous le champ, et au-dessus quand il n'y a plus la place : une liste qui déborde
        // du bas de la fenêtre est une liste qu'on ne peut pas choisir.
        var y = anchor.minY - height - 4
        if y < 0 { y = min(bounds.height - height, anchor.maxY + 4) }
        let x = min(max(0, anchor.minX), max(0, bounds.width - width))
        card.frame = NSRect(x: x, y: max(0, y), width: width, height: height)

        var top = height - padding
        caption.frame = NSRect(x: padding + Tokens.Row.inset,
                               y: top - Self.captionHeight + 3,
                               width: width - padding * 2 - Tokens.Row.inset,
                               height: Self.captionHeight - 3)
        top -= Self.captionHeight
        for row in rows {
            row.frame = NSRect(x: padding, y: top - Self.rowHeight,
                               width: width - padding * 2, height: Self.rowHeight)
            top -= Self.rowHeight
        }
    }

    /// **Rien en dehors de la carte n'appartient à cette vue.** Elle couvre tout le
    /// contenu ; sans cela, elle capterait les clics sur la page qu'elle recouvre.
    ///
    /// Le point arrive dans les coordonnées de la **vue parente**, jamais dans les nôtres —
    /// c'est le contrat d'AppKit, et l'oublier ici coûtait la moitié de la fonction : cette
    /// vue commence après la sidebar, donc comparer directement décalait chaque clic de sa
    /// largeur. La carte laissait alors passer les clics qu'elle aurait dû prendre, et
    /// prenait ceux d'une bande de page à sa gauche.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, card.frame.contains(convert(point, from: superview)) else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// Une proposition : un glyphe de clé, un nom de compte.
private final class SuggestionRow: ThemedView {

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    var isSelected = false { didSet { needsLayout = true } }

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    init(_ proposal: PasswordSuggestions.Proposal) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Row.radius
        layer?.cornerCurve = .continuous

        let symbol: String
        let text: String
        switch proposal {
        case .account(let user): symbol = "key";       text = user
        case .unlock:            symbol = "lock.open"; text = "Déverrouiller le coffre…"
        }
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)

        label.stringValue = text
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityLabel(text)
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

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        glyph.contentTintColor = Tokens.textSecondary
        label.textColor = Tokens.textPrimary

        let size = Tokens.Row.glyph
        glyph.frame = NSRect(x: Tokens.Row.inset, y: (bounds.height - size) / 2,
                             width: size, height: size)
        let left = Tokens.Row.inset + size + Tokens.Row.glyphGap
        label.frame = NSRect(x: left, y: (bounds.height - 18) / 2,
                             width: max(0, bounds.width - left - Tokens.Row.inset), height: 18)
    }
}
