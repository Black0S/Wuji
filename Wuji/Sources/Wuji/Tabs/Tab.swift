import AppKit
import WebKit

/// Un onglet. Pas de barre d'onglets dans le prototype, et c'est délibéré : la thèse à
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
