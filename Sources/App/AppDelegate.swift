import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ContentTopBarDelegate, OmniboxDelegate, FindBarDelegate, SpacesPanelDelegate,
                       WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                       WKDownloadDelegate, NSMenuItemValidation {

    var window: BrowserWindow!
    var layout: BrowserLayout!

    let favicons = FaviconStore()
    let session = SessionStore()
    let history = HistoryStore()
    let downloads = DownloadStore()
    let favorites = FavoritesStore()
    let settings = Settings()

    /// Le blocage de contenu : ce qui est compilé, et ce qui l'applique.
    lazy var blocking = ContentBlocker(settings: settings)
    /// Les règles posées à la main par le sélecteur d'éléments.
    lazy var userRules = UserRules(settings: settings)
    /// Ce que le format de WebKit ne sait pas porter, et que la page applique elle-même.
    let extended = ExtendedStore()
    /// Le catalogue lu au dernier passage sur la page. Il n'est pas gardé sur le disque :
    /// deux cents kilo-octets relus à l'ouverture valent mieux qu'un catalogue d'hier
    /// qu'on ne saurait pas distinguer d'un catalogue d'aujourd'hui.
    var ruleCatalog: [RuleList] = []
    var catalogUnreachable = false
    /// Ce que les pages de blocage ouvertes ont déjà reçu du catalogue. Sert à ne leur
    /// renvoyer les cent soixante et une lignes que lorsqu'elles ont changé — cocher une
    /// case ne change pas le catalogue, seulement son état.
    var patchedCatalog: [String] = []
    let userScripts = UserScriptStore()
    let permissions = Permissions()
    let location = LocationAccess()

    /// Les onglets appartiennent à un espace, jamais à l'application. Tout ce qui suit
    /// passe donc par `currentSpace` — c'est ce qui évite d'avoir deux notions
    /// d'« onglet courant » qui se désynchronisent.
    var spaces: [Space] = []
    var currentSpaceIndex = 0

    /// Position et total de la recherche dans la page, tenus à la main — voir `countMatches`.
    var findPosition = 1
    var findTotal: Int?
    var omniboxCreatesTab = false

    /// **Une configuration par onglet.**
    ///
    /// Les scripts de l'utilisateur dépendent du domaine visé et se posent avant la
    /// navigation. Avec un contrôleur de contenu partagé, deux onglets qui chargent en même
    /// temps se voleraient leurs scripts. Mesuré avant de s'y engager : WebKit ouvre déjà
    /// un processus de rendu par vue web, une configuration par onglet ne coûte donc rien
    /// de plus.
    func makeConfiguration(isPrivate: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // Un magasin non persistant : cookies, cache et stockage local vivent en mémoire et
        // disparaissent avec l'espace. C'est WebKit qui garantit l'effacement, pas nous.
        if isPrivate { config.websiteDataStore = .nonPersistent() }
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // **Le plein écran d'un élément, celui du bouton d'un lecteur vidéo.**
        //
        // Il est éteint par défaut dans `WKWebView`, et rien ne le dit : YouTube répondait
        // « votre navigateur n'est pas compatible avec le mode plein écran » et le bouton
        // ne faisait rien. C'est une propriété distincte du plein écran de la fenêtre —
        // les deux portent le même nom et n'ont rien à voir.
        config.preferences.isElementFullscreenEnabled = true
        // **L'incrustation vidéo n'a pas d'interrupteur public**, et elle est éteinte pour
        // tout ce qui n'est pas Safari : mesuré, `requestPictureInPicture()` répond
        // `NotSupportedError` et le lecteur d'une page ne montre pas de bouton. L'allumer
        // ici rend ce bouton aux lecteurs — celui de YouTube, celui des contrôles natifs de
        // WebKit —, là où on le cherche déjà. Wuji n'en pose pas dans sa barre : la commande
        // appartient au lecteur, pas au chrome.
        WebKitFeatures.enablePictureInPicture(on: config.preferences)
        // **Le préchargement que les pages demandent, éteint par défaut hors de Safari.**
        // `<link rel="prefetch">` et les règles de spéculation : un site qui a fait le
        // travail de dire ce qu'on ouvrira ensuite ne gagnait rien ici. Voir
        // `WebKitFeatures` pour ce que ça coûte — et pourquoi le *prerender*, lui, reste
        // éteint.
        WebKitFeatures.enableWebPerformance(on: config.preferences)

        // **La mise en veille des onglets, faite par WebKit.**
        //
        // Wuji en avait une à lui : passé un délai, l'onglet était vidé et son état gardé
        // pour le reconstruire. Elle a été retirée — elle obligeait l'onglet à traverser un
        // état où sa vue web n'a plus rien à dire, et chaque nouvel état de transition a
        // fini par ouvrir un trou par lequel une ligne disparaissait de la colonne.
        //
        // WebKit sait le faire sans rien détruire. Une vue détachée de la hiérarchie —
        // c'est le cas de tout onglet qu'on ne regarde pas, `BrowserContent` ne garde que
        // celui du moment — voit son JavaScript et sa mise en page suspendus. Rien n'est
        // vidé, rien n'est à reconstruire, et le retour est instantané.
        //
        // **Et le moteur sait ce qu'il ne faut pas suspendre** : une page qui joue du son
        // ou qui charge n'est pas considérée comme inactive. C'est précisément la
        // distinction que notre veille devait deviner en interrogeant l'état de lecture, et
        // qu'elle ratait quand un lecteur changeait de piste.
        config.preferences.inactiveSchedulingPolicy = .suspend

        // **Se présenter comme Safari, mot pour mot.**
        //
        // Sans ça, `WKWebView` s'annonce sans jeton « Version/… Safari/… » : les sites qui
        // reniflent l'agent n'y reconnaissent aucun navigateur connu et servent leur page
        // de repli — Google renvoyait sa mise en page d'il y a quinze ans.
        //
        // Et c'est aussi le choix le plus discret : un agent « Wuji/0.4 » serait unique au
        // monde et suffirait à nous suivre d'un site à l'autre. Le meilleur endroit où se
        // cacher, c'est la foule des Safari.
        config.applicationNameForUserAgent = settings.agent.applicationName
        // Le gestionnaire doit être posé avant la création de la moindre vue web : une
        // configuration déjà utilisée ne l'accepte plus.
        let pages = InternalPageHandler(history: history, downloads: downloads,
                                        favorites: favorites, icons: favicons)
        pages.blocking = { [unowned self] _ in
            // Le catalogue se relit à chaque affichage, y compris quand on arrive par le
            // sommaire ou par l'adresse : `showBlocking` n'est pas le seul chemin, et une
            // page servie sans catalogue se lit comme « il n'y a rien à activer ».
            loadRuleCatalog()
            return BlockingPage.html(state: blockingState)
        }
        pages.rules = { [unowned self] in RulesPage.html(state: rulesState) }
        pages.scripts = { [unowned self] in
            ScriptsPage.html(scripts: userScripts.scripts,
                             isEnabled: settings.userScriptsEnabled)
        }
        pages.settings = { [unowned self] path in
            // Le compte des sites vient de WebKit et se fait attendre : on le demande à
            // chaque ouverture, et la page se remet à jour quand la réponse arrive. Un
            // chiffre affiché doit être celui d'aujourd'hui.
            countSiteData()
            return SettingsPage.html(section: SettingsPage.Section.from(path: path),
                                     state: settingsState)
        }
        config.setURLSchemeHandler(pages, forURLScheme: InternalPageHandler.scheme)
        // Les règles de blocage se posent à la création de la vue : chaque onglet a son
        // propre contrôleur de contenu, donc chacun doit les recevoir.
        blocking.apply(to: config)
        config.userContentController.add(self, name: "wujiHistory")
        config.userContentController.add(self, name: "wujiDownloads")
        config.userContentController.add(self, name: "wujiFavorites")
        config.userContentController.add(self, name: "wujiScripts")
        config.userContentController.add(self, name: "wujiSettings")
        config.userContentController.add(self, name: MediaWatcher.handler)
        config.userContentController.add(self, name: "wujiError")
        config.userContentController.add(self, name: PageContextMenu.handler)
        config.userContentController.add(self, name: "wujiBlocking")
        config.userContentController.add(self, name: ElementPicker.handler)
        config.userContentController.add(self, name: RouteWatcher.handler)
        config.userContentController.add(self, name: PasswordForm.handler)
        config.userContentController.addUserScript(PageContextMenu.script)
        return config
    }

    var currentSpace: Space { spaces[currentSpaceIndex] }

    /// L'onglet qui porte cette vue web, **sans aplatir la liste des onglets**.
    ///
    /// Le motif `spaces.flatMap(\.allTabs).first { $0.webView === webView }` allouait deux
    /// tableaux par espace, sur le chemin critique de chaque navigation et de chaque message
    /// venu d'une page. C'est le seul de nos symboles qu'un profil pris pendant le
    /// chargement d'une page lourde ait fait ressortir.
    func tab(for webView: WKWebView) -> Tab? {
        for space in spaces {
            if let found = space.firstTab(where: { $0.webView === webView }) { return found }
        }
        return nil
    }
    /// L'espace courant est-il privé ? Consulté à la création d'un onglet.
    var isPrivateSpace: Bool { spaces.indices.contains(currentSpaceIndex) && currentSpace.isPrivate }
    /// L'onglet courant, **sans passer par `currentSpace`**.
    ///
    /// Ce détour indexait `spaces` sans le borner, et un rappel asynchrone peut arriver
    /// avant que les espaces soient restaurés : il touchait alors un tableau vide et
    /// l'application mourait au lancement. C'est la deuxième fois que ce chemin tue le
    /// démarrage — il ne doit plus jamais pouvoir sortir des bornes.
    var currentTab: Tab? {
        spaces.indices.contains(currentSpaceIndex) ? spaces[currentSpaceIndex].current : nil
    }

    // MARK: - Cycle de vie

    /// Les adresses qu'un autre programme nous confie — un lien cliqué dans un courriel,
    /// un fichier HTML ouvert depuis le Finder, tout ce qui arrive quand Wuji est le
    /// navigateur par défaut.
    ///
    /// **Chacune ouvre son onglet, et la fenêtre passe devant.** Remplacer la page en
    /// cours ferait perdre ce qu'on lisait pour un lien qu'on vient à peine de cliquer
    /// ailleurs.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            // Un lien cliqué dans une autre application arrive tel qu'il y était écrit —
            // accents compris. On le normalise comme une saisie de l'omnibox, sinon tout
            // ce qui se range par hôte hérite d'une forme que le réseau ne connaît pas.
            openInNewTab(Self.directURL(url.absoluteString) ?? url, activate: true)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Wuji est-il le navigateur par défaut ? On le demande au système plutôt que de le
    /// retenir : c'est un réglage de macOS, et il peut changer sans passer par nous.
    var isDefaultBrowser: Bool {
        guard let https = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: https) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Demande à macOS de faire de Wuji le navigateur par défaut.
    ///
    /// C'est le système qui tranche, et il demande confirmation : on ne peut pas se
    /// déclarer navigateur par défaut dans le dos de quelqu'un, et c'est très bien ainsi.
    func askToBecomeDefault() {
        let bundle = Bundle.main.bundleURL
        Task { @MainActor in
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: bundle,
                                                                    toOpenURLsWithScheme: scheme)
            }
            refreshSettingsPages()
            layout.toast.show(isDefaultBrowser
                              ? "Wuji est le navigateur par défaut"
                              : "macOS n'a pas retenu le changement")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationHandler()
        buildMenu()

        window = BrowserWindow()
        layout = BrowserLayout(frame: window.contentLayoutRect)
        layout.autoresizingMask = [.width, .height]
        layout.topBar.delegate = self
        layout.omnibox.delegate = self
        layout.findBar.delegate = self
        layout.spacesPanel.delegate = self

        layout.sidebar.onSelectTab = { [weak self] id in self?.select(tabID: id) }
        layout.sidebar.onCloseTab = { [weak self] id in self?.close(tabID: id) }
        layout.sidebar.onToggleFolder = { [weak self] id in self?.toggleFolder(id) }
        layout.sidebar.onTabMenu = { [weak self] id, event in self?.showTabMenu(id, event) }
        layout.sidebar.onFolderMenu = { [weak self] id, event in self?.showFolderMenu(id, event) }
        layout.sidebar.onDropTab = { [weak self] id, drop in self?.drop(tabID: id, on: drop) }
        layout.sidebar.onNew = { [weak self] in self?.newTab(nil) }
        layout.sidebar.onDownloads = { [weak self] in self?.showDownloads(nil) }
        layout.sidebar.onSpaceClick = { [weak self] anchor in self?.showSpacesPanel(from: anchor) }

        favicons.onUpdate = { [weak self] in self?.syncSidebar() }

        // Le thème du système peut basculer sans passer par les réglages : les pages
        // internes doivent suivre dans ce cas aussi.
        layout.onAppearanceChange = { [weak self] in self?.refreshInternalPages() }
        window.contentView = layout

        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()


        // Après le reste : une vérification de version n'a aucune raison de retarder
        // l'affichage de la fenêtre.
        if settings.checkUpdatesAtLaunch { checkForUpdate(announcingWhenCurrent: false) }

        // Ce qui était en cours au dernier arrêt revient marqué « interrompu », avec son
        // bouton — rien n'est repris tout seul.
        downloads.restore()
        downloads.onChange = { [weak self] in self?.downloads.persist() }

        history.purge(olderThan: settings.historyRetention)
        // Ce qui était en service le reste, **sans rien retélécharger** : les règles
        // compilées vivent dans le magasin de WebKit et lui survivent au redémarrage.
        blocking.onChange = { [weak self] in
            self?.syncChrome()
            self?.refreshBlockingPages()
        }
        blocking.userRules = userRules
        blocking.restore()
        // Le magasin de WebKit ne se vide pas tout seul : les listes de l'ancien bloqueur
        // intégré y dormaient encore, des mois après sa suppression.
        blocking.sweep()
        // L'annexe suit les listes en service : activer une liste, la retirer ou la mettre
        // à jour change ce qu'il y a à injecter, et un magasin qui ne suivrait pas
        // servirait les règles de la version d'avant.
        extended.onChange = { [weak self] in
            self?.syncChrome()
            self?.refreshBlockingPages()
        }
        syncExtendedRules()
        userRules.onChange = { [weak self] in
            self?.applyBlockingToOpenTabs()
            self?.syncChrome()
            // La page des règles est ouverte pendant qu'on en retire : elle doit montrer
            // ce qui vient de changer, et sur place — un rechargement la remettrait en haut.
            self?.refreshBlockingPages()
        }
        Task { @MainActor in await userRules.restore() }
        restoreSession()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // La sauvegarde différée peut être en attente au moment où l'on quitte.
        session.save(snapshot())
        // Un téléchargement en cours ne se perd pas avec sa liste : le morceau reçu est sur
        // le disque, et sans cette ligne plus rien ne saurait à quoi il correspond.
        downloads.persist()
    }

    /// La session est aussi écrite quand on passe à une autre application.
    ///
    /// `applicationWillTerminate` ne suffit pas : il ne s'exécute pas si le processus est
    /// tué — par un `kill`, par le forceur de quitter, par un plantage. L'écriture était
    /// différée de huit dixièmes de seconde, et cette fenêtre a réellement coûté une
    /// vingtaine d'onglets pendant les essais. Changer d'application est le moment le plus
    /// fréquent où l'on peut écrire sans que personne attende.
    func applicationDidResignActive(_ notification: Notification) {
        // **Un état vide n'écrase pas une session pleine.**
        //
        // La garde ne regardait que les espaces, or il y en a toujours au moins un : il
        // suffisait donc d'un instant sans onglets — pendant une restauration, une
        // fermeture en série — pour qu'un simple passage en arrière-plan écrive le vide
        // par-dessus quinze onglets, définitivement.
        //
        // Perdre une session est irréversible ; garder une session périmée une minute de
        // plus ne coûte rien. Le déséquilibre commande la règle. Une fermeture explicite,
        // elle, passe par `applicationWillTerminate` et dit ce qu'elle veut dire.
        guard spaces.contains(where: { !$0.isEmpty }) else { return }
        session.save(snapshot())
    }

    /// Le signal d'arrêt, qui n'est pas une notification AppKit.
    ///
    /// `SIGTERM` termine le processus sans passer par `applicationWillTerminate`. On
    /// l'intercepte pour écrire la session avant de partir — c'est la différence entre
    /// « fermé proprement » et « vingt onglets perdus ».
    func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if let self, !self.spaces.isEmpty { self.session.save(self.snapshot()) }
                exit(0)
            }
        }
        source.resume()
        terminationSource = source
    }

    var terminationSource: DispatchSourceSignal?

    // MARK: - État réparti
    //
    // Ces propriétés vivent ici parce qu'une extension Swift ne peut pas en porter.
    // Elles appartiennent aux sujets des fichiers voisins ; leur nom dit lequel.

    /// Les hôtes dont on a accepté le certificat refusé, **pour cette session seulement**.
    ///
    /// En mémoire et nulle part ailleurs : quitter Wuji les oublie. Une exception TLS
    /// écrite sur le disque survit à la raison qui l'a fait accorder — le serveur de test
    /// d'un après-midi devient une porte ouverte permanente, sur un nom d'hôte qui peut
    /// changer de main.
    var trustedHosts: Set<String> = []

    /// Les hôtes dont le certificat a déjà passé notre lecture, **pour cette session**.
    ///
    /// Une mémoire de travail, pas une décision : c'est WebKit qui tranche à chaque
    /// connexion. Voir `trust(for:)`.
    var verifiedHosts: Set<String> = []

    /// Le nombre de sites ayant laissé des données, relu à l'ouverture des réglages.
    var siteDataCount: Int?
    /// Ce que chaque site a laissé, site par site.
    ///
    /// **On garde les enregistrements et pas seulement leur nombre**, parce qu'effacer les
    /// données d'un site précis se fait avec l'enregistrement lui-même : WebKit ne prend pas
    /// un nom de domaine, il prend l'objet qu'il a rendu.
    var siteDataRecords: [WKWebsiteDataRecord] = []

    /// Le dernier certificat refusé par hôte, gardé pour que la page d'erreur puisse
    /// montrer ce qu'elle propose d'accepter.
    var rejectedCertificates: [String: SecTrust] = [:]
    var lastProgressPush = Date.distantPast
    /// Ce qu'il faut faire si la feuille d'autorisation se ferme sans reponse.
    var pendingPermission: (() -> Void)?
    /// L'onglet actif, tel qu'on l'a annoncé pour la dernière fois.
    ///
    /// `browser.tabs.onActivated` porte celui qu'on quitte autant que celui qu'on prend :
    /// `currentSpace.current` a déjà changé quand on veut le dire, d'où cette copie.
    weak var activeTab: Tab?
    /// Les onglets affichés en mode lecture. Par identité d'onglet et non par adresse :
    /// deux onglets sur le même article peuvent être lus différemment.
    var readingTabs: Set<UUID> = []
    var appliedTheme: Settings.Theme?
    /// Le plus récent en dernier : fermer puis rouvrir doit rendre ce qu'on vient de
    /// fermer, pas ce qu'on avait fermé ce matin.
    var closedTabs: [ClosedTab] = []
}
