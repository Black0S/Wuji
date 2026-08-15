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
    let userScriptRules = UserRules()
    let userScripts = UserScriptStore()
    let permissions = Permissions()
    let location = LocationAccess()
    lazy var blocker = ContentBlocker(settings: settings, userRules: userScriptRules)
    let blockLog = BlockingLog()
    lazy var blockLogWindow = BlockLogWindow(log: blockLog)

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
        pages.adBlock = { [unowned self] path in
            AdBlockPage.html(section: AdBlockPage.Section.from(path: path),
                             state: blocker.state.summary,
                             bundled: blocker.bundledCount,
                             userRules: blocker.userRules.rules,
                             exceptions: settings.blockingExceptions,
                             isBusy: blocker.state.isBusy)
        }
        pages.scripts = { [unowned self] in ScriptsPage.html(scripts: userScripts.scripts) }
        pages.settings = { [unowned self] path in
            SettingsPage.html(section: SettingsPage.Section.from(path: path),
                              state: settingsState)
        }
        config.setURLSchemeHandler(pages, forURLScheme: InternalPageHandler.scheme)
        config.userContentController.add(self, name: "wujiHistory")
        config.userContentController.add(self, name: "wujiDownloads")
        config.userContentController.add(self, name: "wujiFavorites")
        config.userContentController.add(self, name: "wujiAdBlock")
        config.userContentController.add(self, name: ElementPicker.handler)
        config.userContentController.add(self, name: "wujiScripts")
        config.userContentController.add(self, name: "wujiSettings")
        config.userContentController.add(self, name: MediaWatcher.handler)
        config.userContentController.add(self, name: BlockLogWatcher.handler)
        config.userContentController.add(self, name: "wujiError")
        config.userContentController.add(self, name: PageContextMenu.handler)
        config.userContentController.addUserScript(PageContextMenu.script)
        blocker.attach(to: config.userContentController)
        return config
    }

    var currentSpace: Space { spaces[currentSpaceIndex] }
    /// L'espace courant est-il privé ? Consulté à la création d'un onglet.
    var isPrivateSpace: Bool { spaces.indices.contains(currentSpaceIndex) && currentSpace.isPrivate }
    /// L'onglet courant, **sans passer par `currentSpace`**.
    ///
    /// Ce détour indexait `spaces` sans le borner, et la compilation des règles se termine
    /// parfois avant que les espaces soient restaurés : le rappel touchait alors un tableau
    /// vide et l'application mourait au lancement. C'est la deuxième fois que ce chemin
    /// tue le démarrage — il ne doit plus jamais pouvoir sortir des bornes.
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
            openInNewTab(url, activate: true)
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
        // **Le survol réveille.** Un onglet endormi doit recharger sa page ; fait au clic,
        // on regarde une page blanche le temps du réseau. Fait au survol, le trajet de la
        // souris jusqu'à la ligne suffit le plus souvent à couvrir le chargement.
        //
        // Un délai court avant d'agir : traverser la liste pour atteindre le bas ne doit
        // pas réveiller tout ce qu'on frôle au passage.
        layout.sidebar.onHoverTab = { [weak self] id in self?.prewake(id) }
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

        // Le bloqueur compile ses règles au démarrage : la première page ouverte doit
        // déjà être protégée, pas la deuxième.
        // Recharger seulement quand la nouvelle liste est réellement en place : la
        // compilation de cent quarante mille règles prend quelques secondes.
        blocker.onApplied = { [weak self] in
            guard let self else { return }
            if self.reloadAfterBlocking {
                self.reloadAfterBlocking = false
                self.currentTab?.webView.reload()
                return
            }
            // Les règles viennent d'arriver, et une page les a devancées. On propose,
            // on n'impose pas : recharger d'office ce que quelqu'un est en train de lire
            // serait exactement l'automatisme dont on ne veut plus.
            if self.loadedBeforeRules {
                self.loadedBeforeRules = false
                self.layout.toast.show("Protection prête — recharger cette page") { [weak self] in
                    self?.currentTab?.webView.reload()
                }
            }
        }
        blocker.onChange = { [weak self] in
            self?.refreshSettingsPages()
            self?.syncBlockingButton()
            self?.refreshAdBlockPages()
        }
        blocker.isPrivate = { [weak self] in self?.isPrivateSpace ?? false }
        blocker.start()

        history.purge(olderThan: settings.historyRetention)
        restoreSession()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // La sauvegarde différée peut être en attente au moment où l'on quitte.
        session.save(snapshot())
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

    /// Une page à recharger dès que la liste compilée sera en place.
    var reloadAfterBlocking = false
    /// Une page est arrivée avant que les règles soient posées.
    var loadedBeforeRules = false
    var lastProgressPush = Date.distantPast
    /// Ce qu'il faut faire si la feuille d'autorisation se ferme sans reponse.
    var pendingPermission: (() -> Void)?
    var appliedTheme: Settings.Theme?
    /// Le plus récent en dernier : fermer puis rouvrir doit rendre ce qu'on vient de
    /// fermer, pas ce qu'on avait fermé ce matin.
    var closedTabs: [ClosedTab] = []
    var sleepTimer: Timer?
    var prewakeItem: DispatchWorkItem?
}
