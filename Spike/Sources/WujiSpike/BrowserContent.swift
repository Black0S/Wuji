import AppKit
import WebKit

/// Le conteneur de contenu : un `WKWebView` bord à bord, et **son** liseré de sécurité.
///
/// Un liseré par conteneur, pas un par fenêtre (spec §4.3). En v1 il n'y a qu'un volet,
/// donc ça ne se voit pas — mais le jour du Split View, deux volets dont un seul est
/// chiffré rendent un liseré de fenêtre absurde. Deux heures maintenant, deux semaines plus tard.
@MainActor
final class BrowserContent: NSView {

    let border = SecurityBorderView()
    private(set) var webView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        border.frame = bounds       // au-dessus du contenu : la page ne se remet jamais en page
    }

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

/// Un onglet. Pas de barre d'onglets dans le spike, et c'est délibéré : la thèse à
/// éprouver est que **l'omnibox devient le vrai sélecteur d'onglets** quand l'interface
/// disparaît. Une barre d'onglets rendrait le test caduc.
@MainActor
final class Tab {
    let webView: WKWebView

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
    }

    var url: URL? { webView.url }
    var title: String { webView.title ?? url?.host() ?? "Nouvel onglet" }

    /// L'état de sécurité déduit de l'URL. Le vrai signal (certificat invalide,
    /// permission caméra active) arrive en J1/J2 — ici on valide le vocabulaire visuel.
    var security: SecurityBorderView.State {
        guard let scheme = url?.scheme?.lowercased() else { return .none }
        return scheme == "http" ? .insecure : .none
    }
}
