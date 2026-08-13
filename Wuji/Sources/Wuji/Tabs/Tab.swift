import AppKit
import WebKit

/// Un onglet.
///
/// Il porte une identité stable. C'est ce qui permet à tout le reste de le désigner sans
/// jamais parler de position : un index change dès qu'on épingle, déplace ou ferme
/// quelque chose ailleurs, et on croit alors désigner un onglet alors qu'on désigne un rang.
@MainActor
final class Tab {
    let id = UUID()
    let webView: WKWebView

    /// Épinglé : regroupé en tête de liste et tenu à l'écart des onglets de passage.
    /// La fermeture reste celle de tous les autres — `⌘W` doit vouloir dire la même chose
    /// partout dans l'application.
    var isPinned = false

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
