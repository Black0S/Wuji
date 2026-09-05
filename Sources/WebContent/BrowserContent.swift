import AppKit
import WebKit

/// Le conteneur de contenu : un `WKWebView` bord à bord, et rien par-dessus.
@MainActor
final class BrowserContent: ThemedView {

    private(set) var webView: WKWebView?

    /// La vue qu'on a quittée alors qu'elle était encore en plein écran.
    ///
    /// **Un filet, pas une fonctionnalité.** Quitter un onglet demande à sa page de sortir
    /// du plein écran — voir `park(_:)` —, mais la sortie est asynchrone : WebKit referme sa
    /// fenêtre au tour de boucle suivant. Retirer la vue avant qu'il ait fini couperait la
    /// source de son image, et le bureau du plein écran deviendrait noir le temps qu'il
    /// disparaisse. Elle reste donc dans la hiérarchie jusqu'à ce que la sortie soit
    /// effective, laissée **dessous** : la nouvelle vue est opaque et couvre tout le cadre.
    ///
    /// Elle n'est pas cachée non plus. Masquer une vue dont WebKit tire son image revient à
    /// la retirer.
    private var parked: WKWebView?
    private var parkedObservation: NSKeyValueObservation?
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
        // **La vue qui revient était peut-être celle qu'on gardait.** On cesse alors de la
        // garder *sans la retirer* : elle redevient simplement la vue courante. La retirer
        // pour la remettre dans la foulée serait précisément le détachement qu'on évite.
        if newWebView === parked { forgetParked(removing: false) }
        park(webView)
        webView = newWebView
        newWebView.frame = bounds
        newWebView.autoresizingMask = [.width, .height]
        // Au-dessus de tout : si une vue en plein écran attend dessous, elle doit y rester
        // sans jamais se voir.
        addSubview(newWebView, positioned: .above, relativeTo: nil)
        needsLayout = true
    }

    /// Range la vue qu'on quitte.
    ///
    /// **Un plein écran appartient à l'onglet qu'on regarde.** Le garder ouvert pendant
    /// qu'on lit ailleurs faisait montrer la même vidéo à deux endroits — en grand sur son
    /// bureau, et dans la fenêtre au retour sur l'onglet. Deux images du même objet qui ne
    /// disent pas la même chose : on ne sait plus laquelle commande. Quitter l'onglet
    /// demande donc à la page de sortir du plein écran, et le bureau se referme avec.
    ///
    /// **`document.exitFullscreen()` et non `closeAllMediaPresentations()`.** La seconde
    /// ferme aussi l'incrustation — or l'incrustation existe précisément pour continuer à
    /// regarder pendant qu'on fait autre chose. Fermer les deux d'un même geste tuerait la
    /// fonction en croyant ranger.
    ///
    /// La sortie est asynchrone : si la vue est encore en plein écran à cet instant, on la
    /// garde plutôt que de la retirer, et on la relâche quand la sortie a eu lieu.
    private func park(_ view: WKWebView?) {
        // Une vue déjà gardée le reste : on ne la range pas deux fois.
        guard let view, view !== parked else { return }
        // Une autre l'était : elle n'a plus de raison de l'être.
        forgetParked(removing: true)

        let state = view.fullscreenState
        guard state == .inFullscreen || state == .enteringFullscreen else {
            return view.removeFromSuperview()
        }
        view.evaluateJavaScript("document.exitFullscreen && document.exitFullscreen()")
        parked = view
        parkedObservation = view.observe(\.fullscreenState, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard view.fullscreenState == .notInFullscreen else { return }
                self?.forgetParked(removing: true)
            }
        }
    }

    private func forgetParked(removing: Bool) {
        parkedObservation?.invalidate()
        parkedObservation = nil
        // La vue redevenue courante ne se retire pas : elle est à l'écran.
        if removing, let parked, parked !== webView { parked.removeFromSuperview() }
        parked = nil
    }
}
