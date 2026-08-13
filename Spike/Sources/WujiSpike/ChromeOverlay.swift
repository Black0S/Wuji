import AppKit

@MainActor
protocol ChromeOverlayDelegate: AnyObject {
    func chromeOverlay(_ overlay: ChromeOverlay, didSubmit text: String)
}

/// **Question 3 du spike** : le chrome flat opaque reste-t-il lisible sur des pages réelles ?
///
/// Aucune translucidité, aucun effet de verre — décision arrêtée (spec §3). La pilule tient
/// sur trois choses et trois seulement : un fond **opaque**, un **filet de 1 px** et une
/// **ombre douce**. Retirer le filet et poser la pilule sur une page blanche suffit à
/// la faire disparaître : c'est la démonstration de la règle §4.2.
@MainActor
final class ChromeOverlay: NSView {

    weak var delegate: ChromeOverlayDelegate?

    private let pill = NSView()
    private let field = NSTextField()
    private let lockLabel = NSTextField(labelWithString: "")

    private static let pillWidth: CGFloat = 520
    private static let pillHeight: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildPill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Seule la pilule intercepte les clics ; le reste du bandeau laisse passer vers la page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return pill.frame.contains(local) ? super.hitTest(point) : nil
    }

    private func buildPill() {
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Tokens.Radius.pill
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: pill)
        addSubview(pill)

        lockLabel.font = .systemFont(ofSize: 12, weight: .medium)
        lockLabel.alignment = .center
        pill.addSubview(lockLabel)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.placeholderString = "Rechercher ou saisir une adresse"
        field.lineBreakMode = .byTruncatingTail
        field.target = self
        field.action = #selector(submit)
        pill.addSubview(field)

        applyColors()
    }

    override func layout() {
        super.layout()
        pill.frame = NSRect(
            x: (bounds.width - Self.pillWidth) / 2,
            y: bounds.height - Self.pillHeight - Tokens.Space.s,
            width: Self.pillWidth,
            height: Self.pillHeight
        )
        let lockWidth: CGFloat = 26
        lockLabel.frame = NSRect(x: Tokens.Space.m, y: 0, width: lockWidth, height: Self.pillHeight)
        field.frame = NSRect(
            x: Tokens.Space.m + lockWidth,
            y: (Self.pillHeight - 20) / 2,
            width: Self.pillWidth - (Tokens.Space.m * 2) - lockWidth,
            height: 20
        )
    }

    override func updateLayer() {
        applyColors()
    }

    private func applyColors() {
        pill.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        pill.layer?.borderColor = Tokens.chromeHairline.cgColor
        field.textColor = Tokens.textPrimary
        lockLabel.textColor = Tokens.textSecondary
    }

    // MARK: - État

    func show(url: URL?, security: SecurityBorderView.State) {
        if window?.firstResponder !== field.currentEditor() {
            field.stringValue = url?.absoluteString ?? ""
        }
        lockLabel.stringValue = security == .insecure ? "⚠︎" : "🔒"
        lockLabel.textColor = security == .insecure ? Tokens.Security.insecure : Tokens.textSecondary
    }

    /// `⌘L` — le seul point d'entrée quand l'interface est masquée.
    func focusOmnibox() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var isEditing: Bool { field.currentEditor() != nil }

    @objc private func submit() {
        delegate?.chromeOverlay(self, didSubmit: field.stringValue)
        window?.makeFirstResponder(nil)
    }
}
