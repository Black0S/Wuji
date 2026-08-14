import AppKit

@MainActor
protocol ContentTopBarDelegate: AnyObject {
    func topBarDidRequestOmnibox(_ bar: ContentTopBar)
    func topBar(_ bar: ContentTopBar, didTrigger action: ContentTopBar.Action)
}

/// La barre du haut, au-dessus du **contenu seulement** — elle commence après la sidebar.
///
/// L'adresse n'est pas éditable : cliquer dessus ouvre la palette. Deux surfaces d'édition
/// pour la même chose, c'est le doublon que le principe 5 interdit.
@MainActor
final class ContentTopBar: ThemedView {

    enum Action { case back, forward, menu, blocking, scripts }

    /// Ce que l'icône de blocage doit dire. Trois états, trois formes — jamais une
    /// couleur seule : « Différencier sans couleur » vaut ici comme ailleurs.
    enum Blocking {
        /// Le bloqueur est éteint partout : l'icône disparaît. Un bouton qui ne pilote
        /// rien de visible n'a pas à occuper la barre.
        case off
        case active
        case excepted
    }

    weak var delegate: ContentTopBarDelegate?

    private let back = NSButton()
    private let forward = NSButton()
    private let more = NSButton()
    private let shield = NSButton()
    private let braces = NSButton()
    private var blocking: Blocking = .off
    private let lock = NSImageView()
    private let address = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Rien à droite : le « + » doublait « Nouvel onglet ⌘T » de la sidebar, et
        // l'anneau doublait le clic sur l'adresse. Deux chemins vers la même action,
        // c'est deux éléments à l'écran pour rien (principe 5).
        configure(back, symbol: "chevron.left", label: "Précédent")
        configure(forward, symbol: "chevron.right", label: "Suivant")
        // Le seul bouton à droite, et il n'est pas un doublon : les actions qu'il expose
        // n'ont aucune autre porte d'entrée que la barre de menus du système.
        configure(more, symbol: "ellipsis", label: "Menu")
        configure(shield, symbol: "shield", label: "Blocage")
        // Les scripts ont leur propre bouton, et pas une ligne dans le menu du bloqueur :
        // ce sont deux pouvoirs différents. Le blocage retire ce qu'un site envoie, un
        // script ajoute du code qui s'exécute avec les droits de la page. Les ranger
        // ensemble laissait croire à une option du bloqueur.
        configure(braces, symbol: "curlybraces", label: "Scripts")
        braces.isHidden = true

        lock.imageScaling = .scaleProportionallyDown
        addSubview(lock)

        address.font = .systemFont(ofSize: 13, weight: .medium)
        address.alignment = .center
        address.lineBreakMode = .byTruncatingTail
        addSubview(address)
        address.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openOmnibox)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(buttonAction(_:))
        addSubview(button)
    }

    override func layout() {
        super.layout()
        // Même fond que la sidebar : les deux forment un seul cadre, pas deux surfaces
        // empilées. C'est la courbe du contenu qui fait la jonction, pas un filet.
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor
        [back, forward, more, shield, braces].forEach { $0.contentTintColor = Tokens.textPrimary }

        let size: CGFloat = 24
        let y = (bounds.height - size) / 2
        back.frame = NSRect(x: Tokens.Space.l, y: y, width: size, height: size)
        forward.frame = NSRect(x: Tokens.Space.l + size + Tokens.Space.xs, y: y, width: size, height: size)
        more.frame = NSRect(x: bounds.width - Tokens.Space.l - size, y: y, width: size, height: size)
        shield.frame = NSRect(x: more.frame.minX - size - Tokens.Space.s, y: y, width: size, height: size)
        // Le bouton des scripts prend la place du bouclier quand celui-ci s'efface :
        // laisser un trou là où une icône a disparu ferait chercher un bouton absent.
        let anchor = shield.isHidden ? more.frame.minX : shield.frame.minX
        braces.frame = NSRect(x: anchor - size - Tokens.Space.s, y: y, width: size, height: size)

        let addressWidth = min(360, bounds.width - 260)
        address.frame = NSRect(x: (bounds.width - addressWidth) / 2, y: (bounds.height - 16) / 2,
                               width: addressWidth, height: 16)
        lock.frame = NSRect(x: address.frame.minX - 20, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }

    func show(url: URL?, security: SecurityBorderView.State, canGoBack: Bool, canGoForward: Bool) {
        address.stringValue = url?.absoluteString ?? "wuji://"
        address.textColor = url == nil ? Tokens.textSecondary : Tokens.textPrimary

        let insecure = security == .insecure
        lock.image = NSImage(systemSymbolName: insecure ? "exclamationmark.triangle" : "lock",
                             accessibilityDescription: insecure ? "Connexion non chiffrée" : "Connexion chiffrée")
        lock.contentTintColor = insecure ? Tokens.Security.insecure : Tokens.textSecondary
        lock.isHidden = url == nil

        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        // « Différencier sans couleur » : l'état désactivé passe par l'opacité.
        back.alphaValue = canGoBack ? 1 : 0.35
        forward.alphaValue = canGoForward ? 1 : 0.35
    }

    /// L'état du blocage, tel que la barre doit le montrer.
    func setBlocking(_ state: Blocking) {
        blocking = state
        shield.isHidden = state == .off
        // Un bouclier barré pour « éteint ici » : la forme change, pas seulement la
        // teinte, donc l'information passe aussi sans couleur.
        shield.image = NSImage(systemSymbolName: state == .excepted ? "shield.slash" : "shield",
                               accessibilityDescription: state == .excepted
                                   ? "Blocage désactivé sur ce site" : "Blocage actif")
        shield.alphaValue = state == .excepted ? 0.5 : 1
    }

    /// Le bouton des scripts n'existe que s'il y a des scripts : sans aucun installé, il
    /// n'ouvrirait qu'une liste vide.
    func setScripts(installed: Bool, activeHere: Bool) {
        braces.isHidden = !installed
        braces.alphaValue = activeHere ? 1 : 0.5
        braces.setAccessibilityLabel(activeHere ? "Scripts actifs sur cette page"
                                                : "Aucun script sur cette page")
        needsLayout = true
    }

    /// Pour ancrer la feuille d'action sous le bouton.
    var menuButton: NSView { more }
    var blockingButton: NSView { shield }
    var scriptsButton: NSView { braces }

    @objc private func openOmnibox() { delegate?.topBarDidRequestOmnibox(self) }

    @objc private func buttonAction(_ sender: NSButton) {
        switch sender {
        case back:    delegate?.topBar(self, didTrigger: .back)
        case forward: delegate?.topBar(self, didTrigger: .forward)
        case more:    delegate?.topBar(self, didTrigger: .menu)
        case shield:  delegate?.topBar(self, didTrigger: .blocking)
        case braces:  delegate?.topBar(self, didTrigger: .scripts)
        default:      break
        }
    }
}
