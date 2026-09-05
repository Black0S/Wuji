import AppKit
import WebKit

/// Un onglet.
///
/// Il porte une identité stable. C'est ce qui permet à tout le reste de le désigner sans
/// jamais parler de position : un index change dès qu'on déplace ou ferme
/// quelque chose ailleurs, et on croit alors désigner un onglet alors qu'on désigne un rang.
///
/// `NSObject` pour une seule raison : `WKWebExtensionTab` est un protocole Objective-C, et
/// c'est par lui qu'une extension voit cet onglet. Rien d'autre ici n'en dépend — l'égalité
/// reste l'identité, comparée par `===` partout dans l'application.
@MainActor
final class Tab: NSObject {
    let id = UUID()
    let webView: WKWebView

    /// La dernière adresse dont on soit sûr, et le titre qui allait avec.
    ///
    /// **C'est l'identité de l'onglet, et elle ne s'efface jamais de son vivant.** La vue
    /// web, elle, passe par des états où elle ne sait rien dire : entre deux navigations,
    /// restaurée mais pas encore chargée. Chaque fois qu'on a fait
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
    /// Le type du document affiché, retenu à la réponse. `WKWebView` ne l'expose pas, et
    /// c'est lui qui dit qu'une page est du texte — donc, peut-être, un script à installer.
    var documentMIME: String?
    /// Ouvert par un site, pas par l'utilisateur — `window.open`. Sert à savoir quoi faire
    /// quand sa toute première adresse est refusée.
    var isPopup = false

    /// L'adresse pour laquelle les scripts de l'utilisateur ont déjà été joués.
    ///
    /// Elle empêche de les rejouer deux fois sur la même page : un site qui appelle
    /// `replaceState` à chaque frappe — une recherche qui écrit ses filtres dans l'adresse —
    /// enverrait sinon autant d'exécutions que de caractères tapés.
    var scriptedURL: URL?

    /// Les observations vivent avec l'onglet, pas avec la vue active.
    ///
    /// N'observer que l'onglet courant laissait les autres figés sur leur dernier état
    /// connu : un onglet ouvert en arrière-plan gardait son marqueur de chargement et son
    /// titre provisoire jusqu'à ce qu'un autre événement rafraîchisse la liste.
    var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
    }

    /// Note où en est l'onglet. Appelé quand une page s'engage pour de bon.
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
    /// — restauré, entre deux navigations — ouvrait un trou par lequel un onglet
    /// disparaissait. Ici la question ne se pose plus : `about:blank` et
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
    /// jamais chargé.
    func loadIfPending() {
        guard webView.url == nil, let address = lastKnownURL else { return }
        webView.load(URLRequest(url: address))
    }

    /// Cette page ressemble-t-elle à un article ?
    ///
    /// Relevé **une fois par navigation** et retenu ici, pas mesuré à chaque battement du
    /// chrome : la réponse demande de parcourir les paragraphes de la page, et la barre du
    /// haut se resynchronise des dizaines de fois pendant qu'une page arrive.
    var hasArticle = false

    /// Cet onglet a-t-il déjà chargé quelque chose ?
    ///
    /// **Toucher une propriété de page réveille le processus de rendu.** `pageZoom`,
    /// `customUserAgent`, `underPageBackgroundColor` : chacune oblige WebKit à instancier
    /// la page, donc à lancer un processus, pour un onglet restauré que personne n'a encore
    /// regardé. Vingt-deux onglets rouverts en lançaient vingt — c'est ce que montrait
    /// `ps`. Ce qui n'a pas chargé attendra d'être regardé.
    var hasLoaded: Bool { webView.url != nil }

    /// **Cette page voyage-t-elle en clair ?**
    ///
    /// Une seule question, donc un booléen. C'était une énumération à deux cas, née d'un
    /// liseré qui n'existe plus — et le type portait le nom de la vue qui l'affichait,
    /// ce qui faisait dépendre l'onglet d'un dessin.
    var isInsecure: Bool { url?.scheme?.lowercased() == "http" }
}
