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
final class ContentTopBar: NSView {

    enum Action { case back, forward, newTab }

    weak var delegate: ContentTopBarDelegate?

    private let back = NSButton()
    private let forward = NSButton()
    private let newTab = NSButton()
    private let ring = NSButton()
    private let lock = NSImageView()
    private let address = NSTextField(labelWithString: "")
    private let hairline = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        configure(back, symbol: "chevron.left", label: "Précédent")
        configure(forward, symbol: "chevron.right", label: "Suivant")
        configure(newTab, symbol: "plus", label: "Nouvel onglet")
        // L'anneau : le logo sert de point d'entrée à la palette. C'est la seule marque
        // permanente de l'application dans l'interface — et elle fait quelque chose.
        configure(ring, symbol: "circle", label: "Omnibox")

        lock.imageScaling = .scaleProportionallyDown
        addSubview(lock)

        address.font = .systemFont(ofSize: 13, weight: .medium)
        address.alignment = .center
        address.lineBreakMode = .byTruncatingTail
        addSubview(address)
        address.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openOmnibox)))

        hairline.wantsLayer = true
        addSubview(hairline)
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
        layer?.backgroundColor = Tokens.chromeBackground.cgColor
        hairline.layer?.backgroundColor = Tokens.separator.cgColor
        [back, forward, newTab, ring].forEach { $0.contentTintColor = Tokens.textPrimary }

        let size: CGFloat = 28
        let y = (bounds.height - size) / 2
        back.frame = NSRect(x: Tokens.Space.l, y: y, width: size, height: size)
        forward.frame = NSRect(x: Tokens.Space.l + size + Tokens.Space.xs, y: y, width: size, height: size)
        ring.frame = NSRect(x: bounds.width - Tokens.Space.l - size, y: y, width: size, height: size)
        newTab.frame = NSRect(x: bounds.width - Tokens.Space.l - size * 2 - Tokens.Space.s, y: y,
                              width: size, height: size)

        let addressWidth = min(360, bounds.width - 260)
        address.frame = NSRect(x: (bounds.width - addressWidth) / 2, y: (bounds.height - 16) / 2,
                               width: addressWidth, height: 16)
        lock.frame = NSRect(x: address.frame.minX - 20, y: (bounds.height - 12) / 2, width: 12, height: 12)

        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
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

    @objc private func openOmnibox() { delegate?.topBarDidRequestOmnibox(self) }

    @objc private func buttonAction(_ sender: NSButton) {
        switch sender {
        case back:    delegate?.topBar(self, didTrigger: .back)
        case forward: delegate?.topBar(self, didTrigger: .forward)
        case newTab:  delegate?.topBar(self, didTrigger: .newTab)
        case ring:    delegate?.topBarDidRequestOmnibox(self)
        default:      break
        }
    }
}
