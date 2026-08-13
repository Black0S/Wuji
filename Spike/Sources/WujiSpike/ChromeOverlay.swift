import AppKit

@MainActor
protocol ChromeOverlayDelegate: AnyObject {
    func chromeOverlayDidRequestOmnibox(_ overlay: ChromeOverlay)
    func chromeOverlay(_ overlay: ChromeOverlay, didTrigger action: ChromeOverlay.Action)
}

/// Le chrome révélé : un HUD de navigation à gauche, la pilule d'adresse au centre.
///
/// La pilule **n'est pas éditable**. Cliquer dessus ouvre la palette (`Omnibox`), qui est
/// le vrai point d'entrée. Deux surfaces d'édition concurrentes, c'est exactement le genre
/// de doublon que le principe 5 interdit.
///
/// Tout est flat et opaque — décision arrêtée (spec §3). La pilule tient sur trois choses
/// et trois seulement : fond **opaque**, **filet de 1 px**, **ombre douce**. Retirer le
/// filet et la poser sur une page blanche suffit à la faire disparaître : c'est la
/// démonstration de la règle §4.2.
@MainActor
final class ChromeOverlay: NSView {

    enum Action { case back, forward, reload }

    weak var delegate: ChromeOverlayDelegate?

    private let hud = NSView()
    private let pill = NSView()
    private let lock = NSImageView()
    private let address = NSTextField(labelWithString: "")
    private var hudButtons: [NSButton] = []

    private static let pillWidth: CGFloat = 520
    private static let barHeight = Tokens.Chrome.barHeight
    private static let hudWidth: CGFloat = 132

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildHUD()
        buildPill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Seuls le HUD et la pilule interceptent les clics ; partout ailleurs, la page reçoit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard hud.frame.contains(local) || pill.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Construction

    private func buildHUD() {
        hud.wantsLayer = true
        hud.layer?.cornerRadius = Tokens.Radius.pill
        hud.layer?.cornerCurve = .continuous
        hud.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: hud)
        addSubview(hud)

        let specs: [(String, Action, String)] = [
            ("chevron.left", .back, "Précédent"),
            ("chevron.right", .forward, "Suivant"),
            ("arrow.clockwise", .reload, "Recharger")
        ]
        hudButtons = specs.map { symbol, action, label in
            let button = NSButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = Tokens.textPrimary
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = #selector(hudAction(_:))
            button.tag = [Action.back, .forward, .reload].firstIndex(of: action) ?? 0
            hud.addSubview(button)
            return button
        }
    }

    private func buildPill() {
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Tokens.Radius.pill
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: pill)
        addSubview(pill)

        lock.imageScaling = .scaleProportionallyDown
        pill.addSubview(lock)

        address.font = .systemFont(ofSize: 13, weight: .regular)
        address.lineBreakMode = .byTruncatingTail
        address.alignment = .center
        address.stringValue = "Rechercher ou saisir une adresse"
        pill.addSubview(address)

        let click = NSClickGestureRecognizer(target: self, action: #selector(openOmnibox))
        pill.addGestureRecognizer(click)

        applyColors()
    }

    // MARK: - Disposition

    override func layout() {
        super.layout()
        let top = Tokens.Chrome.row1(in: bounds)

        // Décalé au-delà des feux de circulation, sinon le HUD passe dessous.
        hud.frame = NSRect(x: Tokens.Chrome.trafficLights, y: top,
                           width: Self.hudWidth, height: Self.barHeight)
        let buttonWidth = Self.hudWidth / CGFloat(hudButtons.count)
        for (index, button) in hudButtons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * buttonWidth, y: 0,
                                  width: buttonWidth, height: Self.barHeight)
        }

        pill.frame = NSRect(x: (bounds.width - Self.pillWidth) / 2, y: top,
                            width: Self.pillWidth, height: Self.barHeight)
        let lockSize: CGFloat = 14
        lock.frame = NSRect(x: Tokens.Space.m, y: (Self.barHeight - lockSize) / 2,
                            width: lockSize, height: lockSize)
        address.frame = NSRect(x: Tokens.Space.m + lockSize + Tokens.Space.s,
                               y: (Self.barHeight - 18) / 2,
                               width: Self.pillWidth - (Tokens.Space.m + lockSize + Tokens.Space.s) * 2,
                               height: 18)
    }

    override func updateLayer() {
        applyColors()
    }

    private func applyColors() {
        for surface in [hud, pill] {
            surface.layer?.backgroundColor = Tokens.chromeBackground.cgColor
            surface.layer?.borderColor = Tokens.chromeHairline.cgColor
        }
        hudButtons.forEach { $0.contentTintColor = Tokens.textPrimary }
    }

    // MARK: - État

    func show(url: URL?, security: SecurityBorderView.State, canGoBack: Bool, canGoForward: Bool) {
        address.stringValue = url?.absoluteString ?? "Rechercher ou saisir une adresse"
        address.textColor = url == nil ? Tokens.textSecondary : Tokens.textPrimary

        let insecure = security == .insecure
        lock.image = NSImage(systemSymbolName: insecure ? "exclamationmark.triangle" : "lock",
                             accessibilityDescription: insecure ? "Connexion non chiffrée" : "Connexion chiffrée")
        lock.contentTintColor = insecure ? Tokens.Security.insecure : Tokens.textSecondary

        hudButtons[0].isEnabled = canGoBack
        hudButtons[1].isEnabled = canGoForward
        // « Différencier sans couleur » : l'état désactivé passe par l'opacité, pas par une teinte.
        hudButtons[0].alphaValue = canGoBack ? 1 : 0.35
        hudButtons[1].alphaValue = canGoForward ? 1 : 0.35
    }

    // MARK: - Actions

    @objc private func openOmnibox() {
        delegate?.chromeOverlayDidRequestOmnibox(self)
    }

    @objc private func hudAction(_ sender: NSButton) {
        let actions: [Action] = [.back, .forward, .reload]
        guard actions.indices.contains(sender.tag) else { return }
        delegate?.chromeOverlay(self, didTrigger: actions[sender.tag])
    }
}
