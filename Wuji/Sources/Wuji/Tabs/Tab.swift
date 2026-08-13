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

    /// Les observations vivent avec l'onglet, pas avec la vue active.
    ///
    /// N'observer que l'onglet courant laissait les autres figés sur leur dernier état
    /// connu : un onglet ouvert en arrière-plan gardait son marqueur de chargement et son
    /// titre provisoire jusqu'à ce qu'un autre événement rafraîchisse la liste.
    var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
    }

    var url: URL? { webView.url }
    /// Un titre vide n'est pas `nil` : une page qui commence à charger en renvoie un, et
    /// la ligne se réduirait alors à son marqueur de chargement.
    var title: String {
        if let title = webView.title, !title.isEmpty { return title }
        return url?.host() ?? "Nouvel onglet"
    }

    /// L'état de sécurité déduit de l'URL. Le vrai signal (certificat invalide,
    /// permission caméra active) arrive en J1/J2 — ici on valide le vocabulaire visuel.
    var security: SecurityBorderView.State {
        guard let scheme = url?.scheme?.lowercased() else { return .none }
        return scheme == "http" ? .insecure : .none
    }
}
