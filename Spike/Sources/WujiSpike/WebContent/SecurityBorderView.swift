import AppKit

/// **Question 2 du spike** : peut-on dessiner un liseré fin autour du contenu, animable,
/// sans décaler la mise en page de la page ?
///
/// Réponse testée ici : oui, en le posant **au-dessus** du web view plutôt qu'autour.
/// Le `WKWebView` garde exactement sa taille, la page ne se remet jamais en page,
/// et le liseré n'existe que dans une couche par-dessus.
///
/// Le liseré est **par vue de contenu, jamais par fenêtre** (spec §4.3) : le jour du
/// Split View, deux volets dont un seul est chiffré rendent un liseré de fenêtre absurde.
/// D'où une instance par conteneur de contenu, dès maintenant.
final class SecurityBorderView: NSView {

    enum State: Equatable {
        case none
        case insecure          // connexion non chiffrée
        case permission        // caméra / micro / position actifs en ce moment
        case privateSession

        var color: NSColor? {
            switch self {
            case .none:            return nil
            case .insecure:        return Tokens.Security.insecure
            case .permission:      return Tokens.Security.permission
            case .privateSession:  return Tokens.Security.privateSession
            }
        }

        var label: String {
            switch self {
            case .none:            return "aucun"
            case .insecure:        return "non chiffré"
            case .permission:      return "permission active"
            case .privateSession:  return "session privée"
            }
        }
    }

    private(set) var state: State = .none
    private let stroke = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(stroke)
        stroke.fillColor = nil
        stroke.lineWidth = Tokens.Security.width
        stroke.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Transparent au clic : le liseré ne doit jamais voler un événement à la page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let inset = Tokens.Security.width / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Pas d'animation implicite sur le redimensionnement de fenêtre, sinon le liseré traîne.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.frame = bounds
        stroke.path = CGPath(roundedRect: rect,
                             cornerWidth: Tokens.Radius.card,
                             cornerHeight: Tokens.Radius.card,
                             transform: nil)
        CATransaction.commit()
    }

    override func updateLayer() {
        applyColor(animated: false)
    }

    func set(_ newState: State, animated: Bool = true) {
        guard newState != state else { return }
        state = newState
        applyColor(animated: animated)
    }

    private func applyColor(animated: Bool) {
        let target = state.color
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.22)
        if let target {
            // resolvedColor : sinon la couleur dynamique clair/sombre est figée à sa valeur
            // du moment où on la pousse dans CALayer.
            stroke.strokeColor = target.resolved(for: effectiveAppearance).cgColor
            stroke.opacity = 1
        } else {
            stroke.opacity = 0
        }
        CATransaction.commit()
    }
}

private extension NSColor {
    func resolved(for appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance { out = self.usingColorSpace(.sRGB) ?? self }
        return out
    }
}
