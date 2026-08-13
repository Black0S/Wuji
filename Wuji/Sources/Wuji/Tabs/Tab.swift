import AppKit
import WebKit

/// Un onglet.
///
/// Il porte une identité stable. C'est ce qui permet à tout le reste de le désigner sans
/// jamais parler de position : un index change dès qu'on déplace ou ferme
/// quelque chose ailleurs, et on croit alors désigner un onglet alors qu'on désigne un rang.
@MainActor
final class Tab {
    let id = UUID()
    let webView: WKWebView

    /// Ce qu'on sait d'un onglet restauré tant qu'il n'a pas été ouvert.
    ///
    /// **Chargement différé** : à la réouverture, seul l'onglet actif va chercher sa page.
    /// Les autres ne sont qu'un titre et une adresse jusqu'au clic. Sans ça, rouvrir
    /// trente onglets lancerait trente requêtes réseau et trente moteurs de rendu d'un
    /// coup — c'est ce qui rend le démarrage des autres navigateurs si lourd.
    var pendingURL: URL?
    private var pendingTitle: String?

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

    var url: URL? { webView.url ?? pendingURL }
    /// Un titre vide n'est pas `nil` : une page qui commence à charger en renvoie un, et
    /// la ligne se réduirait alors à son marqueur de chargement.
    var title: String {
        if let title = webView.title, !title.isEmpty { return title }
        if let pendingTitle, !pendingTitle.isEmpty { return pendingTitle }
        return url?.host() ?? "Nouvel onglet"
    }

    convenience init(configuration: WKWebViewConfiguration, pendingURL: URL?, pendingTitle: String?) {
        self.init(configuration: configuration)
        self.pendingURL = pendingURL
        self.pendingTitle = pendingTitle
    }

    /// Charge la page si elle ne l'a jamais été. Rendu au premier affichage de l'onglet.
    func loadIfPending() {
        guard let pendingURL else { return }
        self.pendingURL = nil
        pendingTitle = nil
        webView.load(URLRequest(url: pendingURL))
    }

    /// L'état de sécurité déduit de l'URL. Le vrai signal (certificat invalide,
    /// permission caméra active) arrive en J1/J2 — ici on valide le vocabulaire visuel.
    var security: SecurityBorderView.State {
        guard let scheme = url?.scheme?.lowercased() else { return .none }
        return scheme == "http" ? .insecure : .none
    }
}
