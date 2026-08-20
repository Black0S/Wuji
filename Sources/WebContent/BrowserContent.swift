import AppKit
import WebKit

/// Le conteneur de contenu : un `WKWebView` bord à bord, et **son** liseré de sécurité.
///
/// Un liseré par conteneur, pas un par fenêtre (spec §4.3). En v1 il n'y a qu'un volet,
/// donc ça ne se voit pas — mais le jour du Split View, deux volets dont un seul est
/// chiffré rendent un liseré de fenêtre absurde. Deux heures maintenant, deux semaines plus tard.
@MainActor
final class BrowserContent: ThemedView {

    let border = SecurityBorderView()
    private(set) var webView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Seul l'angle haut-gauche est arrondi : c'est celui où la sidebar et la barre du
        // haut se rejoignent. Les trois autres touchent les bords de la fenêtre, qui a
        // déjà ses propres arrondis — les arrondir aussi creuserait un liseré de fond
        // visible dans les coins.
        layer?.cornerRadius = Tokens.Chrome.contentCorner
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMaxYCorner]
        layer?.masksToBounds = true

        addSubview(border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        border.frame = bounds       // au-dessus du contenu : la page ne se remet jamais en page
    }

    // **Pas de barre de chargement.**
    //
    // Il y en avait une : un filet clair collé au bord haut du contenu. Elle datait d'une
    // interface qui s'escamotait, où plus rien n'aurait dit qu'une page travaille. Cette
    // interface n'existe plus — la colonne marque déjà l'onglet qui charge, et le reste du
    // temps ce filet ne faisait que traverser l'écran à chaque navigation.
    //
    // Ce qu'on gagne en plus du calme : l'avancement du chargement n'est plus observé du
    // tout, donc le chrome cesse de se resynchroniser plusieurs fois par seconde pendant
    // qu'une page arrive.

    func attach(_ newWebView: WKWebView) {
        guard newWebView !== webView else { return }
        webView?.removeFromSuperview()
        webView = newWebView
        newWebView.frame = bounds
        newWebView.autoresizingMask = [.width, .height]
        addSubview(newWebView, positioned: .below, relativeTo: border)
        needsLayout = true
    }
}
