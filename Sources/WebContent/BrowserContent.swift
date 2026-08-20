import AppKit
import WebKit

/// Le conteneur de contenu : un `WKWebView` bord à bord, et rien par-dessus.
@MainActor
final class BrowserContent: ThemedView {

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView?.frame = bounds
    }

    // **Pas de liseré de sécurité, pas de barre de chargement.**
    //
    // Le liseré entourait la page de rouge sur une connexion en clair. La barre du haut
    // le dit déjà, et mieux : un triangle contre l'adresse, le `http://` écrit dans la
    // même couleur, et le cadenas qui ouvre le détail. Le liseré répétait cela sur trois
    // points de large tout autour du contenu, en mangeant le bord de chaque page.
    //
    // **Deux surfaces pour un seul fait, c'est une de trop** — et la moins précise est
    // celle qui n'a pas de mots. Il n'avait qu'un état à montrer : le retirer ne laisse
    // aucun cas orphelin.
    //
    // **Pas de barre de chargement non plus.**
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
        addSubview(newWebView)
        needsLayout = true
    }
}
