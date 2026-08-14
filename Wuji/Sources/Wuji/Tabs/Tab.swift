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

    /// Un média joue-t-il dans cette page ?
    ///
    /// La page le dit elle-même : elle écoute `play` et `pause` sur ses éléments audio et
    /// vidéo. `requestMediaPlaybackState` existe, mais il faut l'interroger — donc scruter
    /// tous les onglets en boucle pour savoir lequel chante.
    var isPlayingMedia = false

    /// Depuis quand cet onglet n'a-t-il pas été regardé.
    var lastSeen = Date()

    /// L'état de navigation d'un onglet mis en veille : son historique et sa position.
    ///
    /// **Mettre en veille, c'est détruire la vue web.** Un `WKWebView` invisible garde son
    /// processus de rendu et sa mémoire ; il n'existe aucune API pour l'endormir. La seule
    /// façon de rendre les ressources est de le supprimer, en gardant de quoi le
    /// reconstruire à l'identique.
    private var sleepingState: Data?

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

    var isSleeping: Bool { sleepingState != nil }

    /// Endort l'onglet : la page s'en va, son adresse et son historique restent.
    ///
    /// Rien n'est endormi qui joue du son — couper la musique d'un onglet qu'on a laissé
    /// exprès en fond serait pire que la mémoire économisée.
    func sleep() {
        guard !isSleeping, !isPlayingMedia, webView.url != nil else { return }
        sleepingState = webView.interactionState as? Data
        pendingURL = webView.url
        pendingTitle = title
        webView.stopLoading()
        // La vue reste, mais vide : son processus de rendu est libéré avec son contenu.
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Réveille l'onglet à l'endroit exact où on l'avait laissé.
    func wake() {
        guard let state = sleepingState else { return }
        sleepingState = nil
        pendingURL = nil
        pendingTitle = nil
        webView.interactionState = state
    }

    /// Coupe tout ce qui vit dans cet onglet.
    ///
    /// Fermer un onglet doit arrêter ce qu'il faisait. Sans ce démontage, une vidéo
    /// continuait de jouer après la fermeture : la vue web restait retenue par ses
    /// observations et par le délégué, et son processus de rendu avec elle.
    func tearDown() {
        webView.pauseAllMediaPlayback()
        webView.stopLoading()
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        // Une page vide libère le processus de rendu tout de suite, sans attendre que le
        // ramasse-miettes veuille bien lâcher la vue.
        webView.loadHTMLString("", baseURL: nil)
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
