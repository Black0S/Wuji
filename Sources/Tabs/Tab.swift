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

    /// La dernière adresse dont on soit sûr, et le titre qui allait avec.
    ///
    /// **C'est l'identité de l'onglet, et elle ne s'efface jamais de son vivant.** La vue
    /// web, elle, passe par des états où elle ne sait rien dire : vidée pendant la veille,
    /// entre deux navigations, restaurée mais pas encore chargée. Chaque fois qu'on a fait
    /// dépendre l'identité de l'onglet de ce que la vue racontait sur l'instant, un onglet
    /// a disparu de la colonne — trois fois, par trois chemins différents.
    ///
    /// Elle sert aussi au **chargement différé** : à la réouverture, seul l'onglet actif va
    /// chercher sa page. Les autres ne sont qu'un titre et une adresse jusqu'au clic —
    /// sinon rouvrir trente onglets lancerait trente requêtes et trente moteurs de rendu.
    var lastKnownURL: URL?
    var lastKnownTitle: String?

    /// Un média joue-t-il dans cette page ?
    ///
    /// La page le dit elle-même : elle écoute `play` et `pause` sur ses éléments audio et
    /// vidéo. `requestMediaPlaybackState` existe, mais il faut l'interroger — donc scruter
    /// tous les onglets en boucle pour savoir lequel chante.
    var isPlayingMedia = false
    /// Ouvert par un site, pas par l'utilisateur — `window.open`. Sert à savoir quoi faire
    /// quand sa toute première adresse est refusée.
    var isPopup = false

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
        // **On note d'abord où revenir, on vide ensuite.**
        //
        // L'ordre inverse a coûté cher : `interactionState` peut être nul — une page qui
        // n'a pas fini de s'engager n'en a pas — et l'onglet était alors vidé sans être
        // marqué endormi. Il annonçait `about:blank`, la colonne le prenait pour un onglet
        // vierge et le retirait, et `wake()` refusait de le rouvrir faute d'état. Un
        // onglet perdu, sans rien pour le dire.
        guard !isSleeping, !isPlayingMedia, let live = webView.url else { return }
        remember(url: live)

        // Le marqueur est posé quoi qu'il arrive : sans état d'interaction on rechargera
        // l'adresse, ce qui coûte le défilement mais rend l'onglet. Perdre sa position est
        // ennuyeux ; perdre l'onglet ne l'est pas, c'est inacceptable.
        sleepingState = (webView.interactionState as? Data) ?? Data()
        webView.stopLoading()
        // La vue reste, mais vide : son processus de rendu est libéré avec son contenu.
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Réveille l'onglet à l'endroit exact où on l'avait laissé.
    ///
    /// **L'adresse de repli n'est pas effacée ici.** Elle l'était, et c'était le défaut :
    /// entre l'instant où l'on efface et celui où la page s'engage, la vue annonce encore
    /// un document vide. L'onglet n'avait alors plus aucune adresse à donner, la colonne le
    /// prenait pour vierge, et il disparaissait sous le curseur de qui venait le survoler
    /// pour le réveiller. Le repli reste ; il s'efface tout seul dès que la vue a mieux à
    /// dire.
    func wake() {
        guard let state = sleepingState else { return }
        sleepingState = nil

        // Un état vide veut dire « endormi sans savoir où l'on en était » : on repart de
        // l'adresse. C'est le repli, pas le cas courant.
        if state.isEmpty {
            if let address = lastKnownURL { webView.load(URLRequest(url: address)) }
            return
        }
        webView.interactionState = state
    }

    /// Note où en est l'onglet. Appelé quand une page s'engage pour de bon, et avant de
    /// l'endormir.
    func remember(url: URL) {
        guard url.absoluteString != "about:blank" else { return }
        lastKnownURL = url
        let live = webView.title
        if let live, !live.isEmpty { lastKnownTitle = live }
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

    /// L'adresse de l'onglet.
    var url: URL? { Self.resolvedURL(live: webView.url, lastKnown: lastKnownURL) }

    /// Quelle adresse fait foi : celle de la vue quand elle en a une vraie, la dernière
    /// connue sinon.
    ///
    /// **Une seule règle, sans état intermédiaire à connaître.** Les versions précédentes
    /// demandaient « l'onglet dort-il ? » pour choisir, et chaque nouvel état de transition
    /// — en veille, en réveil, restauré, entre deux navigations — ouvrait un trou par
    /// lequel un onglet disparaissait. Ici la question ne se pose plus : `about:blank` et
    /// l'absence d'adresse veulent dire la même chose, « la vue n'a rien à dire », et c'est
    /// la mémoire de l'onglet qui répond.
    ///
    /// Fonction séparée et sans dépendance à WebKit, pour que la règle soit vérifiable.
    static func resolvedURL(live: URL?, lastKnown: URL?) -> URL? {
        if let live, live.absoluteString != "about:blank" { return live }
        return lastKnown ?? live
    }

    /// Un titre vide n'est pas `nil` : une page qui commence à charger en renvoie un, et
    /// la ligne se réduirait alors à son marqueur de chargement.
    var title: String {
        if let title = webView.title, !title.isEmpty { return title }
        if let lastKnownTitle, !lastKnownTitle.isEmpty { return lastKnownTitle }
        return url?.host() ?? "Nouvel onglet"
    }

    /// Un onglet qu'on connaît déjà : restauré d'une session, ou repris après fermeture.
    convenience init(configuration: WKWebViewConfiguration, url: URL?, title: String?) {
        self.init(configuration: configuration)
        lastKnownURL = url
        lastKnownTitle = title
    }

    /// Charge la page d'un onglet restauré, au premier affichage.
    ///
    /// **Rien n'est effacé ici non plus.** C'était le troisième endroit à vider l'identité
    /// de l'onglet avant que la page existe — même motif, même conséquence : une ligne qui
    /// s'évanouit le temps du chargement. La mémoire de l'onglet reste, la vue la
    /// remplacera d'elle-même quand elle aura mieux à dire.
    ///
    /// La condition porte sur la vue, pas sur la mémoire : une vue qui n'a **rien** n'a
    /// jamais chargé. Une vue vidée par la veille annonce `about:blank`, et c'est `wake()`
    /// qui s'en occupe, pas cette fonction.
    func loadIfPending() {
        guard webView.url == nil, let address = lastKnownURL else { return }
        webView.load(URLRequest(url: address))
    }

    /// L'état de sécurité déduit de l'URL. Le vrai signal (certificat invalide,
    /// permission caméra active) arrive en J1/J2 — ici on valide le vocabulaire visuel.
    var security: SecurityBorderView.State {
        guard let scheme = url?.scheme?.lowercased() else { return .none }
        return scheme == "http" ? .insecure : .none
    }
}
