import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ContentTopBarDelegate, OmniboxDelegate, FindBarDelegate, SpacesPanelDelegate,
                       WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                       WKDownloadDelegate, NSMenuItemValidation {

    private var window: BrowserWindow!
    private var layout: BrowserLayout!

    private let favicons = FaviconStore()
    private let session = SessionStore()
    private let history = HistoryStore()
    private let downloads = DownloadStore()
    private let favorites = FavoritesStore()
    private let settings = Settings()
    private let userScriptRules = UserRules()
    private let userScripts = UserScriptStore()
    private let permissions = Permissions()
    private let location = LocationAccess()
    private lazy var blocker = ContentBlocker(settings: settings, userRules: userScriptRules)
    private let blockLog = BlockingLog()
    private lazy var blockLogWindow = BlockLogWindow(log: blockLog)

    /// Les onglets appartiennent à un espace, jamais à l'application. Tout ce qui suit
    /// passe donc par `currentSpace` — c'est ce qui évite d'avoir deux notions
    /// d'« onglet courant » qui se désynchronisent.
    private var spaces: [Space] = []
    private var currentSpaceIndex = 0

    /// Position et total de la recherche dans la page, tenus à la main — voir `countMatches`.
    private var findPosition = 1
    private var findTotal: Int?
    private var omniboxCreatesTab = false

    /// **Une configuration par onglet.**
    ///
    /// Les scripts de l'utilisateur dépendent du domaine visé et se posent avant la
    /// navigation. Avec un contrôleur de contenu partagé, deux onglets qui chargent en même
    /// temps se voleraient leurs scripts. Mesuré avant de s'y engager : WebKit ouvre déjà
    /// un processus de rendu par vue web, une configuration par onglet ne coûte donc rien
    /// de plus.
    private func makeConfiguration(isPrivate: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // Un magasin non persistant : cookies, cache et stockage local vivent en mémoire et
        // disparaissent avec l'espace. C'est WebKit qui garantit l'effacement, pas nous.
        if isPrivate { config.websiteDataStore = .nonPersistent() }
        config.defaultWebpagePreferences.allowsContentJavaScript = true

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

    private var currentSpace: Space { spaces[currentSpaceIndex] }
    /// L'espace courant est-il privé ? Consulté à la création d'un onglet.
    private var isPrivateSpace: Bool { spaces.indices.contains(currentSpaceIndex) && currentSpace.isPrivate }
    /// L'onglet courant, **sans passer par `currentSpace`**.
    ///
    /// Ce détour indexait `spaces` sans le borner, et la compilation des règles se termine
    /// parfois avant que les espaces soient restaurés : le rappel touchait alors un tableau
    /// vide et l'application mourait au lancement. C'est la deuxième fois que ce chemin
    /// tue le démarrage — il ne doit plus jamais pouvoir sortir des bornes.
    private var currentTab: Tab? {
        spaces.indices.contains(currentSpaceIndex) ? spaces[currentSpaceIndex].current : nil
    }

    // MARK: - Cycle de vie

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
            guard self.reloadAfterBlocking else { return }
            self.reloadAfterBlocking = false
            self.currentTab?.webView.reload()
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
    private func installTerminationHandler() {
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

    private var terminationSource: DispatchSourceSignal?

    // MARK: - Session

    private func restoreSession() {
        guard let stored = session.load(), !stored.spaces.isEmpty else {
            spaces = [Space(name: "Personnel", symbol: Space.symbol(forIndex: 0))]
            newTab(url: nil)
            return
        }

        spaces = stored.spaces.map { storedSpace in
            let space = Space(name: storedSpace.name, symbol: storedSpace.symbol)
            for storedFolder in storedSpace.folders {
                let folder = space.addFolder(named: storedFolder.name)
                folder.isExpanded = storedFolder.isExpanded
                storedFolder.tabs.forEach { space.place(restore($0), at: .into(folder)) }
                folder.isExpanded = storedFolder.isExpanded
            }
            storedSpace.loose.forEach { space.place(restore($0), at: .looseEnd) }
            let order = space.allTabs
            if let index = storedSpace.currentTab, order.indices.contains(index) {
                space.current = order[index]
            } else {
                space.current = order.first
            }
            return space
        }
        currentSpaceIndex = min(max(0, stored.currentSpace), spaces.count - 1)

        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
    }

    private func restore(_ stored: StoredTab) -> Tab {
        makeTab(pendingURL: stored.url.flatMap(URL.init(string:)), pendingTitle: stored.title)
    }

    private func snapshot() -> StoredSession {
        // Un espace privé n'est pas écrit : le retrouver au prochain lancement serait le
        // contraire de ce qu'il promet.
        StoredSession(
            spaces: spaces.filter { !$0.isPrivate }.map { space in
                let order = space.allTabs
                return StoredSpace(
                    name: space.name,
                    symbol: space.symbol,
                    folders: space.folders.map { folder in
                        StoredFolder(name: folder.name, isExpanded: folder.isExpanded,
                                     tabs: folder.tabs.filter { !isBlank($0) }.map(store))
                    },
                    loose: space.loose.filter { !isBlank($0) }.map(store),
                    currentTab: order.firstIndex { $0 === space.current })
            },
            currentSpace: currentSpaceIndex)
    }

    private func store(_ tab: Tab) -> StoredTab {
        StoredTab(url: tab.url?.absoluteString, title: tab.title)
    }

    /// Un seul endroit où les réglages descendent dans l'application. Sans ça, chaque
    /// réglage finirait branché depuis sa propre rangée d'interface, et on ne saurait
    /// plus qui pilote quoi.
    private func applySettings() {
        let themeChanged = appliedTheme != settings.theme
        appliedTheme = settings.theme
        NSApp.appearance = settings.theme.appearance

        for tab in spaces.flatMap(\.allTabs) {
            tab.webView.pageZoom = settings.pageZoom
            tab.webView.customUserAgent = settings.agent == .safari ? nil
                : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                  + "(KHTML, like Gecko) " + settings.agent.applicationName
            tab.webView.isInspectable = settings.safariInspection
            // Une couleur dynamique posée sur WebKit est résolue à l'affectation : il faut
            // la réécrire quand le thème change.
            // Une page interne suit le thème par `prefers-color-scheme`, qui reflète
            // l'apparence de la vue. Le basculement est instantané pour le CSS, mais le
            // HTML a pu être produit avec des couleurs figées : on le régénère.
            if themeChanged, tab.url?.scheme == InternalPageHandler.scheme {
                tab.webView.reload()
            }
        }

        spaces.flatMap(\.allTabs).forEach(applyPageBackground)
    }

    /// Le fond hors page — celui qu'on découvre au rebond du défilement.
    ///
    /// Résolu contre l'apparence **déduite du réglage**, et non contre celle de la vue :
    /// au moment où l'on applique un thème, les vues n'ont pas encore basculé, et lire
    /// leur apparence rendait toujours la précédente. Le réglage, lui, est déjà à jour.
    private func applyPageBackground(to tab: Tab) {
        let appearance = settings.theme.appearance ?? NSApp.effectiveAppearance
        tab.webView.underPageBackgroundColor =
            Tokens.resolve(Tokens.sidebarBackground, for: appearance)
    }

    private var appliedTheme: Settings.Theme?

    private func refreshInternalPages() {
        for tab in spaces.flatMap(\.allTabs) {
            applyPageBackground(to: tab)
            if tab.url?.scheme == InternalPageHandler.scheme { tab.webView.reload() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Le libellé du menu suit ce que la touche va réellement faire. « Fermer l'onglet »
    /// affiché alors que ⌘W fermera les Réglages serait un mensonge, même bref. Et une
    /// entrée qui n'a rien à faire — rien à rouvrir, rien à mettre de côté — se désactive
    /// plutôt que d'attendre un clic sans effet.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTab(_:)):
            let auxiliary = NSApp.keyWindow != nil && NSApp.keyWindow !== window
            item.title = auxiliary ? "Fermer la fenêtre" : "Fermer l'onglet"
            return true
        case #selector(toggleFavorite(_:)):
            guard let tab = currentTab, let url = favoritableURL(of: tab) else { return false }
            item.title = favorites.contains(url) ? "Retirer des favoris" : "Ajouter aux favoris"
            return true
        case #selector(reopenClosedTab(_:)):
            return !closedTabs.isEmpty
        default:
            return true
        }
    }


    // MARK: - Onglets

    /// `⌘T` n'ouvre que la palette. L'onglet ne naît qu'au moment où l'on choisit une
    /// destination — et pas du tout si l'on bascule sur un onglet déjà ouvert, ce qui est
    /// le cas le plus fréquent. Créer l'onglet d'abord laissait une page vide derrière
    /// chaque changement d'onglet fait au clavier.
    @objc func newTab(_ sender: Any?) {
        openOmnibox(creatingTab: true)
    }

    /// Sans adresse, l'onglet ouvre la page vierge de Wuji plutôt que de rester blanc :
    /// elle porte le fond de la sidebar, donc la fenêtre reste une seule surface tant
    /// qu'il n'y a rien à afficher.
    static let blankPage = URL(string: "wuji://")!

    /// Un onglet vierge n'est pas encore un onglet : il n'a ni adresse ni titre à montrer.
    /// Il reste donc hors de la liste, hors de la palette et hors de la session — sinon on
    /// listerait une ligne qui ne désigne rien, et on la restaurerait au lancement suivant.
    private func isBlank(_ tab: Tab) -> Bool {
        tab.url == nil || tab.url == Self.blankPage
    }

    private func newTab(url: URL?) {
        let tab = makeTab()
        currentSpace.append(tab)
        activateCurrentTab()
        tab.webView.load(URLRequest(url: url ?? Self.blankPage))
    }

    private func makeTab(configuration override: WKWebViewConfiguration? = nil,
                         pendingURL: URL? = nil, pendingTitle: String? = nil) -> Tab {
        let tab = Tab(configuration: override ?? makeConfiguration(isPrivate: isPrivateSpace),
                      pendingURL: pendingURL, pendingTitle: pendingTitle)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.webView.pageZoom = settings.pageZoom
        tab.webView.isInspectable = settings.safariInspection
        // Un onglet vierge ne montre plus le blanc par défaut de WebKit : il prend le fond
        // du thème. Sans ça, ouvrir un onglet en thème sombre projette une page blanche
        // pleine hauteur, et c'est le contraire d'une interface qui se fait oublier.
        // Le fond des pages internes est celui de la sidebar : la fenêtre reste une seule
        // surface, sans cadre autour d'une page qui appartient à l'application.
        applyPageBackground(to: tab)

        // Chaque onglet s'observe lui-même, pas seulement celui qui est affiché : sinon un
        // onglet ouvert en arrière-plan reste figé sur son titre provisoire et son marqueur
        // de chargement jusqu'au prochain événement venu d'ailleurs.
        let sync: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncChrome() }
        }
        tab.observations = [
            tab.webView.observe(\.url, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.title, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.isLoading, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.estimatedProgress, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.canGoBack, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.canGoForward, options: [.initial, .new], changeHandler: sync)
        ]
        return tab
    }

    // MARK: - Ouverture en arrière-plan

    /// `⌘clic` ouvre dans un nouvel onglet **sans y aller** ; `⌘⇧clic` y va. C'est la
    /// convention de tous les navigateurs, et elle vaut d'être respectée : on ⌘-clique
    /// justement pour ne pas quitter la page qu'on est en train de lire.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Les règles avancées se posent **avant** que la page parte, sinon le lecteur de
        // YouTube a déjà lu sa réponse quand notre code arrive.
        if navigationAction.targetFrame?.isMainFrame ?? false {
            installPageScripts(for: navigationAction.request.url, in: webView)
        }

        // Une adresse en `.user.js` est une offre d'installation, pas une page à lire.
        if let url = navigationAction.request.url, url.path.hasSuffix(".user.js"),
           navigationAction.targetFrame?.isMainFrame ?? true {
            installScript(from: url)
            return .cancel
        }

        guard navigationAction.navigationType == .linkActivated,
              navigationAction.modifierFlags.contains(.command),
              let url = navigationAction.request.url else { return .allow }
        openInNewTab(url, activate: navigationAction.modifierFlags.contains(.shift))
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        present(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        present(error, in: webView)
    }

    /// Affiche l'échec **à l'adresse demandée**, et non sous `wuji://` : l'URL reste dans
    /// la barre, le bouton précédent fonctionne, et réessayer a un sens.
    private func present(_ error: any Error, in webView: WKWebView) {
        let error = error as NSError

        // Deux échecs qui n'en sont pas : une navigation qu'on a annulée nous-mêmes — le
        // ⌘clic — et une navigation devenue téléchargement. Les afficher accuserait le
        // réseau de ce que nous venons de faire.
        guard error.code != NSURLErrorCancelled,
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }

        guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url else { return }
        // Le seul refus dont WebKit nous informe : une adresse principale qu'une règle a
        // arrêtée. C'est peu, et c'est vrai.
        if ErrorPage.isBlocked(error) {
            blockLog.record(.blocked, host: url.host() ?? "", detail: url.absoluteString)
        }
        webView.loadSimulatedRequest(URLRequest(url: url),
                                     responseHTML: ErrorPage.html(url: url, error: error))
    }

    /// Une page vue est une page arrivée. Enregistrer au départ de la navigation
    /// compterait les redirections et les erreurs comme des visites.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        // Rien n'est noté depuis un espace privé — c'est tout ce qu'il promet.
        guard !isPrivateSpace else { return }
        history.record(url: url, title: webView.title ?? "")
    }

    /// Une réponse que WebKit ne sait pas afficher est un fichier, pas une page.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        register(download, source: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        register(download, source: navigationResponse.response.url)
    }

    private func register(_ download: WKDownload, source: URL?) {
        download.delegate = self
        let item = DownloadItem(download: download,
                                source: source ?? URL(string: "about:blank")!,
                                filename: source?.lastPathComponent ?? "fichier")
        downloads.add(item)
        attach(download, to: item)
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let destination = DownloadStore.destination(for: suggestedFilename)
        guard let item = downloads.item(for: download) else { return destination }
        item.filename = destination.lastPathComponent
        item.destination = destination
        refreshDownloads(reload: true)
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = downloads.item(for: download) else { return }
        item.state = .finished
        item.observation = nil
        refreshDownloads(reload: true)
        // Sans signal, un téléchargement terminé est invisible : le fichier est arrivé
        // quelque part et rien ne le dit.
        layout.toast.show("\(item.filename) · téléchargé") { [weak self] in self?.showDownloads(nil) }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = downloads.item(for: download) else { return }
        item.state = .failed(error.localizedDescription)
        refreshDownloads(reload: true)
    }

    /// `reload` : à réserver aux changements de composition. Pour le seul avancement, on
    /// pousse les chiffres dans la page — la recharger à chaque paquet reçu la faisait
    /// clignoter et remontait le défilement.
    private func refreshDownloads(reload: Bool = false) {
        downloads.changed()
        downloads.items.forEach { $0.sample() }
        let running = downloads.items.filter(\.isActive)
        // Un seul anneau pour tous : la moyenne dit « ça avance », ce qui est la seule
        // question qu'on se pose sans ouvrir la page.
        let fraction = running.isEmpty ? nil : running.reduce(0) { $0 + $1.fraction } / Double(running.count)
        layout.sidebar.updateDownloads(progress: fraction)

        let pages = spaces.flatMap(\.allTabs).filter { $0.url == Self.downloadsPage }
        guard !pages.isEmpty else { return }

        if reload {
            pages.forEach { $0.webView.reload() }
            return
        }
        // Quelques rafraîchissements par seconde suffisent à donner le mouvement ; le
        // rappel d'avancement, lui, se déclenche des dizaines de fois.
        guard Date().timeIntervalSince(lastProgressPush) > 0.15 else { return }
        lastProgressPush = Date()

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        for item in downloads.items where item.isRunning {
            item.sample()
            let detail = "\(formatter.string(fromByteCount: item.received)) sur "
                + (item.expected > 0 ? formatter.string(fromByteCount: item.expected) : "?")
                + " · en cours"
            let script = "window.wujiProgress && window.wujiProgress('\(item.id.uuidString)', "
                + "\(Int(item.fraction * 100)), '\(detail)')"
            pages.forEach { $0.webView.evaluateJavaScript(script) }
        }
    }

    private var lastProgressPush = Date.distantPast

    static let downloadsPage = URL(string: "wuji://downloads")!

    @objc func showDownloads(_ sender: Any?) {
        openInternal(Self.downloadsPage)
    }

    // MARK: - Blocage

    /// Pose sur l'onglet ce qui doit s'exécuter dans la page.
    ///
    /// Chaque onglet a son contrôleur de contenu : on peut donc remplacer ses scripts sans
    /// toucher aux autres. Il n'y a plus de scriptlets — les règles livrées ne visent que
    /// des domaines, et WebKit les applique lui-même — donc rien n'est injecté ici qui ne
    /// serve à l'application ou à l'utilisateur.
    private func installPageScripts(for url: URL?, in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(PageContextMenu.script)
        controller.addUserScript(MediaWatcher.script)
        // Le mouchard du journal n'est posé que si quelqu'un regarde.
        if blockLogWindow.isOpen { controller.addUserScript(BlockLogWatcher.script) }

        // Les scripts de l'utilisateur s'appliquent même sur un site où la protection est
        // levée : ils sont à lui.
        guard settings.userScriptsEnabled else { return }
        for (script, code) in userScripts.matching(url) {
            let time: WKUserScriptInjectionTime = script.runAt == "document-start" ? .atDocumentStart
                                                                                  : .atDocumentEnd
            controller.addUserScript(WKUserScript(source: "(function(){\n" + code + "\n})();",
                                                  injectionTime: time, forMainFrameOnly: true))
        }
    }

    static let adBlockPage = URL(string: "wuji://ad-block/my-rules")!
    static let scriptsPage = URL(string: "wuji://scripts")!

    /// Ce que la page des reglages doit afficher.
    private var settingsState: SettingsPage.State {
        SettingsPage.State(theme: settings.theme.rawValue,
                           searchEngine: settings.searchEngine.rawValue,
                           pageZoom: Double(settings.pageZoom),
                           inspection: settings.safariInspection,
                           retention: settings.historyRetention,
                           historyCount: history.count,
                           blockingEnabled: settings.blockingEnabled,
                           userScripts: settings.userScriptsEnabled,
                           agent: settings.agent.rawValue,
                           blockingSummary: blocker.state.summary,
                           permissions: permissions.decisions.map {
                               ($0.host, $0.kind.rawValue, $0.isAllowed)
                           })
    }

    static let settingsPage = URL(string: "wuji://settings")!

    @objc func openSettings(_ sender: Any?) {
        openInternal(Self.settingsPage)
    }

    private func handleSettingsAction(_ action: String, payload: [String: Any]) {
        switch action {
        case "set":
            guard let key = payload["key"] as? String,
                  let value = payload["value"] as? String else { return }
            switch key {
            case "theme":      settings.theme = Settings.Theme(rawValue: value) ?? .auto
            case "engine":     settings.searchEngine = Settings.SearchEngine(rawValue: value) ?? .duckduckgo
            case "inspection": settings.safariInspection = (value == "true")
            case "retention":  settings.historyRetention = Int(value) ?? 90
            case "zoom":       settings.pageZoom = (Double(value) ?? 100) / 100
            case "agent":      settings.agent = Settings.Agent(rawValue: value) ?? .safari
            case "blocking":
                settings.blockingEnabled = (value == "true")
                blocker.start()
            case "userscripts":
                settings.userScriptsEnabled = (value == "true")
                syncBlockingButton()
                // Les onglets ouverts portent encore les scripts posés à leur navigation :
                // éteindre la fonction sans les retirer laisserait croire qu'elle ment.
                spaces.flatMap(\.allTabs).filter { !$0.isSleeping }.forEach {
                    installPageScripts(for: $0.url, in: $0.webView)
                    $0.webView.reload()
                }
            default: break
            }
        case "clear-history":
            history.clear()
            refreshSettingsPages()
        case "forget-permission":
            guard let host = payload["host"] as? String else { return }
            permissions.forget(host: host, kind: payload["kind"] as? String)
        default:
            break
        }
    }

    private func refreshSettingsPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "settings" }
            .forEach { $0.webView.reload() }
    }

    @objc func showScripts(_ sender: Any?) {
        openInternal(Self.scriptsPage)
    }

    /// Ouvre le journal. **Il part de maintenant, et ne recharge rien.**
    ///
    /// Il rechargeait toutes les pages ouvertes pour y poser son mouchard, et remplissait
    /// donc sa première fenêtre en cassant ce que l'on regardait — une vidéo relancée, un
    /// formulaire vidé. Un journal est un témoin : il note ce qui se passe pendant qu'il
    /// est ouvert, pas ce qu'il aurait fallu provoquer pour avoir quelque chose à montrer.
    @objc func showBlockLog(_ sender: Any?) {
        blockLogWindow.show()
        // Les pages déjà ouvertes recevront le mouchard à leur prochaine navigation ; les
        // nouvelles l'ont tout de suite.
    }

    private func refreshScriptsPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "scripts" }
            .forEach { $0.webView.reload() }
    }

    /// Télécharge un script et l'installe, après accord.
    ///
    /// Un script utilisateur s'exécute avec les pouvoirs de la page : l'installer sans le
    /// demander serait exécuter du code tiers sur simple visite d'une adresse.
    private func installScript(from url: URL) {
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            let preview = UserScript(text: text, source: url)
            self.layout.toast.ask(
                title: "Installer « \(preview.name) » ?",
                message: "Ce script s'exécutera sur : \(preview.patterns.prefix(3).joined(separator: ", ")). Il aura les mêmes pouvoirs que ces pages.",
                confirm: "Installer", isDestructive: false, onCancel: {}) { [weak self] in
                    self?.userScripts.add(text: text, source: url)
                    self?.layout.toast.show("Script installé") { self?.showScripts(nil) }
                    self?.refreshScriptsPages()
                }
        }
    }

    private func handleScriptAction(_ action: String, payload: [String: Any]) {
        switch action {
        case "install":
            guard let raw = payload["url"] as? String, let url = URL(string: raw),
                  url.scheme == "https" || url.scheme == "http" else { return }
            installScript(from: url)
        case "enable":
            guard let value = payload["value"] as? Bool else { return }
            userScripts.setEnabled(value, id: payload["id"] as? String)
        case "update":
            // On retélécharge à la même adresse : c'est le script lui-même qui dit sa
            // version, et son en-tête sera relu comme à l'installation.
            guard let id = payload["id"] as? String,
                  let script = userScripts.scripts.first(where: { $0.id.uuidString == id }),
                  let source = script.source else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: source),
                      let text = String(data: data, encoding: .utf8) else {
                    self?.layout.toast.show("Mise à jour impossible")
                    return
                }
                let updated = self?.userScripts.add(text: text, source: source)
                self?.layout.toast.show(updated.map {
                    $0.version.isEmpty ? "« \($0.name) » mis à jour"
                                       : "« \($0.name) » en v\($0.version)"
                } ?? "Mise à jour impossible")
                self?.refreshScriptsPages()
            }
        case "remove":
            userScripts.remove(id: payload["id"] as? String)
        default:
            break
        }
    }

    @objc func showAdBlock(_ sender: Any?) {
        openInternal(Self.adBlockPage)
    }

    /// Ce que le bouclier de la barre doit montrer.
    ///
    /// Le bloqueur prévient dès qu'il change d'état, y compris avant que la session soit
    /// restaurée : d'où les gardes. Sans elles, la compilation qui se termine pendant le
    /// démarrage va chercher un onglet courant dans une liste d'espaces encore vide.
    private var blockingBadge: ContentTopBar.Blocking {
        guard settings.blockingEnabled else { return .off }
        guard !spaces.isEmpty else { return .active }
        return blocker.isExcepted(currentTab?.url) ? .excepted : .active
    }

    private func syncBlockingButton() {
        guard layout != nil else { return }
        layout.topBar.setBlocking(blockingBadge)
        layout.topBar.setScripts(
            installed: settings.userScriptsEnabled && !userScripts.scripts.isEmpty,
            activeHere: settings.userScriptsEnabled && !userScripts.matching(currentTab?.url).isEmpty)
    }

    /// Le menu des scripts.
    ///
    /// Il dit d'abord ce qui tourne **ici**, puis laisse allumer et éteindre chaque script
    /// sans passer par une page : c'est le geste qu'on fait quand un script casse le site
    /// qu'on est en train de lire, et il ne doit pas coûter une navigation.
    private func scriptsMenu() -> [ActionItem] {
        var items: [ActionItem] = []
        let here = Set(userScripts.matching(currentTab?.url).map(\.0.id))

        items.append(ActionItem(title: here.isEmpty
                                    ? "Aucun script sur cette page"
                                    : "\(here.count) script\(here.count > 1 ? "s" : "") sur cette page",
                                symbol: "curlybraces", isEnabled: false))
        items.append(.separator)

        // Ceux qui s'appliquent ici d'abord : c'est la page ouverte qui motive l'ouverture
        // du menu, pas l'inventaire.
        let ordered = userScripts.scripts.sorted { first, second in
            here.contains(first.id) != here.contains(second.id) ? here.contains(first.id) : false
        }
        for script in ordered {
            // La coche dit l'état, et l'action le renverse. Un rond vide plutôt qu'une
            // absence de glyphe : sans forme, une ligne éteinte n'est qu'un texte, et on
            // ne sait plus si la liste est cochable.
            items.append(ActionItem(title: script.name,
                                    symbol: script.isEnabled ? "checkmark.circle.fill" : "circle",
                                    action: { [weak self] in
                                        guard let self else { return }
                                        userScripts.setEnabled(!script.isEnabled, id: script.id.uuidString)
                                        currentTab?.webView.reload()
                                        refreshScriptsPages()
                                        syncBlockingButton()
                                    }))
        }

        items.append(.separator)
        items.append(ActionItem(title: "Gérer les scripts…", symbol: "list.bullet",
                                action: { [weak self] in self?.showScripts(nil) }))
        return items
    }

    private func refreshAdBlockPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "ad-block" }
            .forEach { $0.webView.reload() }
    }

    /// Le menu du bouclier.
    ///
    /// Il répond d'abord à « que se passe-t-il **ici** » — l'état du site ouvert et ce que
    /// les règles y font — avant d'offrir les outils. Une feuille qui commence par ses
    /// réglages oblige à chercher l'information à chaque fois.
    private func blockingMenu() -> [ActionItem] {
        var items: [ActionItem] = []
        let url = currentTab.flatMap(favoritableURL(of:))

        if let url, let host = url.host() {
            let excepted = blocker.isExcepted(url)

            // L'état du site, en une ligne qu'on lit sans cliquer.
            items.append(ActionItem(title: excepted ? "Protection levée sur \(host)"
                                                    : "Protection active sur \(host)",
                                    symbol: excepted ? "shield.slash" : "shield.lefthalf.filled",
                                    isEnabled: false))
            items.append(.separator)

            items.append(ActionItem(title: excepted ? "Réactiver sur ce site" : "Désactiver sur ce site",
                                    symbol: excepted ? "shield" : "shield.slash",
                                    action: { [weak self] in self?.toggleBlocking(for: url) }))
            if !excepted {
                items.append(ActionItem(title: "Bloquer un élément…", symbol: "scope",
                                        action: { [weak self] in self?.pickElement() }))
            }
            items.append(.separator)
        }

        items.append(ActionItem(title: blocker.state.summary, symbol: "info.circle", isEnabled: false))
        items.append(ActionItem(title: "Mes règles…", symbol: "pencil",
                                action: { [weak self] in self?.showAdBlock(nil) }))
        items.append(ActionItem(title: "Journal de blocage…", symbol: "text.line.first.and.arrowtriangle.forward",
                                action: { [weak self] in self?.showBlockLog(nil) }))
        return items
    }

    /// Arme le sélecteur d'élément sur la page courante.
    private func pickElement() {
        currentTab?.webView.evaluateJavaScript(ElementPicker.script)
    }

    /// La règle produite par le sélecteur, rangée avec le domaine où on l'a prise.
    ///
    /// Le domaine est indispensable : `##.promo` sans domaine masquerait les promos de tout
    /// le web. Une règle écrite en un clic doit rester bornée à l'endroit où on l'a écrite.
    private func addPickedRule(_ selector: String) {
        guard let host = currentTab?.url?.host(), !selector.isEmpty else { return }
        blocker.addUserRule(WebKitRule.hide(selector: selector, on: host))
        // L'élément disparaît tout de suite, sans attendre la compilation : on vient de le
        // désigner, le voir survivre quelques secondes ferait douter du clic. La règle,
        // elle, prendra le relais au prochain chargement.
        let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        currentTab?.webView.evaluateJavaScript(
            "document.querySelectorAll('\(escaped)').forEach(n => n.style.setProperty('display','none','important'))")
        layout.toast.show("Élément masqué sur \(host)") { [weak self] in self?.showAdBlock(nil) }
    }

    private func handleAdBlockAction(_ action: String, payload: [String: Any]) {
        switch action {
        case "unexcept":
            guard let host = payload["host"] as? String else { return }
            settings.blockingExceptions.removeAll { $0 == host }
            blocker.compile()
        case "rule":
            guard let rule = payload["rule"] as? String else { return }
            blocker.addUserRule(rule)
        case "unrule":
            guard let rule = payload["rule"] as? String else { return }
            blocker.removeUserRule(rule)
        default:
            break
        }
    }

    /// Éteindre ou rallumer la protection sur un site, puis recharger.
    ///
    /// Le rechargement n'est pas une politesse : les règles de contenu s'appliquent au
    /// moment où la requête part. Sans lui, la page reste exactement telle qu'elle était
    /// et on croit que le réglage n'a rien fait.
    private func toggleBlocking(for url: URL) {
        reloadAfterBlocking = true
        blocker.toggleException(for: url)
        let host = url.host() ?? ""
        layout.toast.show(blocker.isExcepted(url)
                          ? "Protection désactivée sur \(host)"
                          : "Protection réactivée sur \(host)")
    }

    /// Une page à recharger dès que la liste compilée sera en place.
    private var reloadAfterBlocking = false

    // MARK: - Favoris

    static let favoritesPage = URL(string: "wuji://favorites")!

    @objc func showFavorites(_ sender: Any?) {
        openInternal(Self.favoritesPage)
    }

    /// `⌘D` met la page de côté, ou l'en retire si elle y est déjà.
    ///
    /// Un seul raccourci pour les deux sens : `⌘D` sur une page déjà en favori ne peut
    /// vouloir dire que « finalement, non ». Le retour est un toast et non un panneau —
    /// mettre de côté est un geste qu'on fait en passant, pas une opération à confirmer.
    @objc func toggleFavorite(_ sender: Any?) {
        guard let tab = currentTab, let url = favoritableURL(of: tab) else { return }
        let added = favorites.toggle(url: url, title: tab.title)
        layout.toast.show(added ? "Ajouté aux favoris" : "Retiré des favoris") { [weak self] in
            self?.showFavorites(nil)
        }
        refreshFavorites()
    }

    /// L'adresse qu'on peut mettre de côté, s'il y en a une.
    ///
    /// Ni une page vierge — elle ne mène nulle part — ni une page de l'application :
    /// mettre `wuji://favorites` dans les favoris ferait une liste qui se contient
    /// elle-même, et ces pages ont déjà leur raccourci.
    private func favoritableURL(of tab: Tab) -> URL? {
        guard let url = tab.url, !isBlank(tab),
              url.scheme != InternalPageHandler.scheme else { return nil }
        return url
    }

    /// Les pages ouvertes sur la liste doivent refléter ce qui vient de changer ailleurs.
    private func refreshFavorites() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url == Self.favoritesPage }
            .forEach { $0.webView.reload() }
    }

    private func handleFavoriteAction(_ action: String, id: String?) {
        switch action {
        case "delete":
            favorites.remove(id: id)
            // Pas de rechargement : la page a déjà retiré la ligne, et la recharger
            // remonterait le défilement pour rien.
        case "rename":
            guard let item = favorites.item(id: id), let id else { return }
            layout.actionSheet.presentPrompt(title: "Renommer le favori", value: item.title,
                                             confirm: "Renommer") { [weak self] name in
                self?.favorites.rename(id: id, to: name)
                self?.refreshFavorites()
            }
        default:
            break
        }
    }

    /// La demande de caméra ou de micro.
    ///
    /// **Elle passe par la feuille de l'application**, comme tout le reste : le panneau
    /// système de WebKit arrive avec son matériau translucide et son vocabulaire, au moment
    /// précis où l'on veut que la personne lise ce qu'elle accorde.
    ///
    /// Le refus est le défaut : fermer la feuille sans choisir, c'est refuser.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host
        let kind: Permissions.Kind = switch type {
        case .camera: .camera
        case .microphone: .microphone
        default: .both
        }

        // Déjà tranché pour ce site : on ne redemande pas.
        if let known = permissions.decision(host: host, kind: kind) {
            return known ? .grant : .deny
        }

        return await withCheckedContinuation { continuation in
            layout.toast.ask(
                title: "Autoriser \(kind.label) ?",
                message: "« \(host) » demande l'accès à \(kind.label). Cette réponse sera retenue pour ce site, et modifiable dans les réglages.",
                confirm: "Autoriser", isDestructive: false,
                onCancel: { [weak self] in
                    self?.permissions.remember(host: host, kind: kind, isAllowed: false)
                    continuation.resume(returning: .deny)
                },
                onConfirm: { [weak self] in
                    self?.permissions.remember(host: host, kind: kind, isAllowed: true)
                    continuation.resume(returning: .grant)
                })
        }
    }

    /// La position, demandée par `navigator.geolocation`.
    ///
    /// **WebKit ne l'expose pas dans `WKUIDelegate` public**, et sans réponse il refuse en
    /// silence : une page qui demande la position échouait sans que rien ne le dise. Le
    /// sélecteur ci-dessous est celui que WebKit appelle réellement ; ne pas y répondre
    /// n'est pas un choix de discrétion, c'est une fonction absente.
    ///
    /// La décision suit exactement la même règle que la caméra : demandée une fois,
    /// retenue par site, révocable dans les réglages, et refusée par défaut.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        askLocation(host: origin.host) { decisionHandler($0 ? .grant : .deny) }
    }

    /// L'ancienne forme du même appel, gardée parce qu'on ne sait pas laquelle de ses deux
    /// portes WebKit empruntera : elles ont cohabité longtemps.
    @objc(_webView:requestGeolocationPermissionForFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor frame: WKFrameInfo,
                 decisionHandler: @escaping (Bool) -> Void) {
        askLocation(host: frame.request.url?.host() ?? "", then: decisionHandler)
    }

    private func askLocation(host: String, then decide: @escaping (Bool) -> Void) {
        // Le refus de macOS l'emporte sur tout : demander à l'utilisateur d'autoriser un
        // site quand le système a déjà dit non ferait promettre ce qu'on ne peut pas tenir.
        guard !location.isBlockedBySystem else {
            layout.toast.show("macOS refuse la position à Wuji — voir Réglages Système, Confidentialité.")
            decide(false)
            return
        }
        if let known = permissions.decision(host: host, kind: .location) {
            guard known else { decide(false); return }
            location.authorize(decide)
            return
        }
        layout.toast.ask(
            title: "Partager votre position ?",
            message: "« \(host) » demande votre position. Cette réponse sera retenue pour ce site, et modifiable dans les réglages.",
            confirm: "Partager", isDestructive: false,
            onCancel: { [weak self] in
                self?.permissions.remember(host: host, kind: .location, isAllowed: false)
                decide(false)
            },
            onConfirm: { [weak self] in
                guard let self else { decide(false); return }
                permissions.remember(host: host, kind: .location, isAllowed: true)
                // Et seulement maintenant la boîte du système : elle arrive derrière un
                // oui explicite, jamais avant.
                location.authorize(decide)
            })
    }

    /// Ce qu'il faut faire si la feuille d'autorisation se ferme sans reponse.
    private var pendingPermission: (() -> Void)?

    /// `target="_blank"` et `window.open` : WebKit demande une nouvelle vue plutôt que de
    /// naviguer. Rendre `nil` reviendrait à avaler le lien en silence — c'est le défaut le
    /// plus courant des navigateurs maison.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = makeTab(configuration: configuration)
        currentSpace.append(tab)
        activateCurrentTab()
        return tab.webView
    }

    private func openInNewTab(_ url: URL, activate: Bool) {
        let staying = currentSpace.current
        let tab = makeTab()
        currentSpace.append(tab)
        tab.webView.load(URLRequest(url: url))
        // L'onglet naît juste après celui d'où l'on vient : au bout de la liste, il
        // faudrait aller le chercher.
        if let staying { currentSpace.place(tab, at: .after(staying)) }
        if !activate, let staying { currentSpace.current = staying }
        activateCurrentTab()
    }

    private func select(tabID: UUID) {
        guard let tab = currentSpace.tab(with: tabID) else { return }
        currentSpace.current = tab
        activateCurrentTab()
    }

    private func close(tabID: UUID) {
        guard let tab = currentSpace.tab(with: tabID) else { return }
        remember(tab, in: currentSpace)
        currentSpace.remove(tab)
        // Ce que l'onglet faisait s'arrête avec lui : sans ce démontage, le son d'une
        // vidéo continuait après la fermeture.
        tab.tearDown()
        if currentSpace.isEmpty {
            newTab(url: nil)
            openOmnibox()
        } else {
            activateCurrentTab()
        }
    }


    /// `⌘W` ferme ce qui est devant, et rien d'autre.
    ///
    /// Quand une fenêtre auxiliaire a le focus — les Réglages aujourd'hui, n'importe
    /// laquelle demain — c'est elle qui se ferme. Un raccourci qui agit sur une fenêtre
    /// qu'on ne regarde pas est un piège, surtout celui-là.
    ///
    /// Et sur le navigateur, il ferme l'onglet, sans exception : `⌘W` doit vouloir dire
    /// la même chose partout.
    @objc func closeTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(nil)
            return
        }

        guard let tab = currentSpace.current else { return }
        close(tabID: tab.id)
    }

    // MARK: - Rouvrir un onglet fermé

    /// Un onglet fermé, et de quoi le rendre **là où il était**.
    ///
    /// L'espace et le dossier sont désignés par leur identité, la place par un rang :
    /// entre la fermeture et la reprise, un voisin a pu disparaître, mais un conteneur
    /// nommé et un rang borné retombent toujours sur quelque chose de vrai.
    private struct ClosedTab {
        let url: URL
        let title: String
        let space: UUID
        let folder: UUID?
        let index: Int
    }

    /// Le plus récent en dernier : fermer puis rouvrir doit rendre ce qu'on vient de
    /// fermer, pas ce qu'on avait fermé ce matin.
    private var closedTabs: [ClosedTab] = []

    private func remember(_ tab: Tab, in space: Space) {
        // Une page vierge n'a rien à rendre : la rouvrir donnerait une page vierge de plus.
        guard let url = tab.url, !isBlank(tab) else { return }
        let folder = space.folders.first { $0.tabs.contains { $0 === tab } }
        let index = folder.flatMap { $0.tabs.firstIndex { $0 === tab } }
            ?? space.loose.firstIndex { $0 === tab }
            ?? space.loose.count

        closedTabs.append(ClosedTab(url: url, title: tab.title, space: space.id,
                                    folder: folder?.id, index: index))
        // Borné : au-delà d'une poignée, ce n'est plus « rouvrir ce que je viens de
        // fermer », c'est un second historique — et il en existe déjà un vrai.
        if closedTabs.count > 12 { closedTabs.removeFirst() }
    }

    /// `⇧⌘T` rend le dernier onglet fermé, dans son espace et à sa place.
    ///
    /// Il revient chargé en différé, comme au démarrage : on rouvre souvent par réflexe,
    /// et une requête réseau immédiate pour un onglet qu'on regardera peut-être serait
    /// payée à chaque fois.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = closedTabs.popLast() else { return }

        // L'espace d'origine s'il existe encore, celui d'aujourd'hui sinon : rendre
        // l'onglet ailleurs vaut mieux que ne rien rendre.
        if let index = spaces.firstIndex(where: { $0.id == closed.space }) {
            currentSpaceIndex = index
        }
        let space = currentSpace
        let tab = makeTab(pendingURL: closed.url, pendingTitle: closed.title)
        space.restore(tab, folder: closed.folder, index: closed.index)
        space.current = tab
        activateCurrentTab()
    }

    @objc func nextTab(_ sender: Any?) { step(by: 1) }
    @objc func previousTab(_ sender: Any?) { step(by: -1) }

    /// La navigation clavier suit l'ordre d'affichage, dossiers compris : c'est celui que
    /// l'utilisateur a sous les yeux.
    private func step(by delta: Int) {
        let order = currentSpace.allTabs
        guard order.count > 1,
              let position = order.firstIndex(where: { $0 === currentSpace.current }) else { return }
        currentSpace.current = order[(position + delta + order.count) % order.count]
        activateCurrentTab()
    }

    private func activateCurrentTab() {
        guard let tab = currentSpace.current ?? currentSpace.allTabs.first else { return }
        currentSpace.current = tab
        tab.lastSeen = Date()
        tab.wake()
        // C'est ici que le chargement différé se dénoue : un onglet restauré ne va
        // chercher sa page qu'au moment où on le regarde.
        tab.loadIfPending()
        layout.content.attach(tab.webView)
        syncChrome()
        scheduleSleep()
    }

    /// Endort les onglets qu'on ne regarde plus depuis un moment.
    ///
    /// **Un onglet en veille rend son processus de rendu et sa mémoire.** Une vue web
    /// invisible les garde : WebKit n'offre aucune API pour l'endormir, la seule façon est
    /// de vider la page en conservant de quoi la reconstruire. Dix minutes, parce que
    /// revenir sur un onglet après dix minutes coûte un rechargement qu'on accepte, alors
    /// qu'après trente secondes il surprendrait.
    /// Au bout de combien de temps un onglet qu'on ne regarde plus rend sa mémoire.
    ///
    /// **Cinq minutes.** Deux, c'était trop court à l'usage : on revenait sur un onglet
    /// quitté le temps d'une recherche et il fallait le recharger. Le survol le réveille
    /// avant le clic, mais ça ne rachète pas un délai qui se déclenche pendant qu'on
    /// travaille.
    ///
    /// Le processeur, lui, n'attend pas ce délai : une page qui n'est pas à l'écran est
    /// déjà bridée par WebKit, ses minuteries comprises.
    private static let sleepDelay: TimeInterval = 300

    private func scheduleSleep() {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs() }
        }
    }

    private var sleepTimer: Timer?
    private var prewakeItem: DispatchWorkItem?

    /// Réveille un onglet survolé, s'il l'est encore dans un cinquième de seconde.
    private func prewake(_ id: UUID) {
        prewakeItem?.cancel()
        guard let tab = spaces.flatMap(\.allTabs).first(where: { $0.id == id }), tab.isSleeping
        else { return }
        let item = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let tab, tab.isSleeping else { return }
                tab.wake()
                self?.syncSidebar()
            }
        }
        prewakeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func sleepIdleTabs() {
        let now = Date()
        for space in spaces {
            for tab in space.allTabs where tab !== space.current {
                guard now.timeIntervalSince(tab.lastSeen) > Self.sleepDelay, !tab.isSleeping,
                      tab.webView.url != nil else { continue }
                // **On demande au moteur, pas à la page.** Le drapeau posé par la page vient
                // d'un évènement `play` ou `pause` ; il suffit qu'un lecteur change de piste,
                // ou que WebKit bride l'onglet en arrière-plan, pour qu'un `pause` passe et
                // qu'on croie la musique finie. On endormait alors un onglet qui jouait, et
                // le son s'arrêtait — exactement ce que la mise en veille promettait
                // d'éviter.
                tab.webView.requestMediaPlaybackState { [weak self, weak tab] state in
                    MainActor.assumeIsolated {
                        guard let tab, state != .playing, !tab.isPlayingMedia else { return }
                        tab.sleep()
                        self?.syncSidebar()
                    }
                }
            }
        }
    }

    private func syncChrome() {
        // Les observations posées avec `.initial` se déclenchent pendant la construction
        // des onglets — donc avant que `spaces` existe, au moment de la restauration.
        guard !spaces.isEmpty, let tab = currentTab else { return }
        let state = tab.security
        layout.content.border.set(state)
        layout.content.setProgress(tab.webView.estimatedProgress, isLoading: tab.webView.isLoading)
        layout.topBar.show(url: tab.url,
                           security: state,
                           canGoBack: tab.webView.canGoBack,
                           canGoForward: tab.webView.canGoForward)
        window.title = tab.title
        syncBlockingButton()
        syncSidebar()
    }

    /// Construit la liste affichée : les dossiers avec leur contenu, puis les onglets de
    /// passage. La sidebar ne reçoit que des identités et de quoi dessiner.
    private func syncSidebar() {
        guard !spaces.isEmpty else { return }
        let space = currentSpace
        layout.sidebar.update(space: SpaceSnapshot(name: space.name, symbol: space.symbol))

        var items: [SidebarItem] = []
        for folder in space.folders {
            let visible = folder.tabs.filter { !isBlank($0) }
            items.append(.folder(id: folder.id, name: folder.name,
                                 isExpanded: folder.isExpanded, count: visible.count))
            if folder.isExpanded {
                items.append(contentsOf: visible.map { item(for: $0, depth: 1) })
            }
        }
        items.append(contentsOf: space.loose.filter { !isBlank($0) }.map { item(for: $0, depth: 0) })

        layout.sidebar.update(items: items, selected: space.current?.id)
        session.scheduleSave(self.snapshot())
    }

    private func item(for tab: Tab, depth: Int) -> SidebarItem {
        .tab(id: tab.id, title: tab.title, host: tab.url?.host() ?? "",
             isLoading: tab.webView.isLoading, favicon: favicons.icon(for: tab.url),
             depth: depth, isPlaying: tab.isPlayingMedia, isSleeping: tab.isSleeping)
    }

    // MARK: - Dossiers et déplacements

    /// Un espace privé neuf, et on y va.
    @objc func newPrivateSpace(_ sender: Any?) {
        let space = Space(name: "Privé", symbol: Space.privateSymbol)
        space.isPrivate = true
        spaces.append(space)
        currentSpaceIndex = spaces.count - 1
        newTab(url: nil)
        openOmnibox()
        layout.toast.show("Espace privé : rien ne sera enregistré")
    }

    @objc func newFolder(_ sender: Any?) {
        let folder = currentSpace.addFolder(named: "Dossier \(currentSpace.folders.count + 1)")
        // Le nouvel onglet courant y entre : créer un dossier vide qu'il faudrait ensuite
        // remplir à la main serait deux gestes pour une intention.
        if let tab = currentSpace.current { currentSpace.place(tab, at: .into(folder)) }
        syncSidebar()
    }

    private func toggleFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        folder.isExpanded.toggle()
        syncSidebar()
    }

    private func drop(tabID: UUID, on drop: SidebarDrop) {
        let space = currentSpace

        // Un dossier glissé ne porte pas d'onglet : c'est le même geste et le même
        // rappel, mais une autre collection.
        if let folder = space.folder(with: tabID) {
            switch drop {
            case .folderBefore(let otherID):
                if let other = space.folder(with: otherID) { space.moveFolder(folder, before: other) }
            case .folderEnd:
                space.moveFolderToEnd(folder)
            default:
                break
            }
            syncSidebar()
            return
        }

        guard let tab = space.tab(with: tabID) else { return }
        switch drop {
        case .before(let otherID):
            guard let other = space.tab(with: otherID) else { return }
            space.place(tab, at: .before(other))
        case .into(let folderID):
            guard let folder = space.folder(with: folderID) else { return }
            space.place(tab, at: .into(folder))
        case .end:
            space.place(tab, at: .looseEnd)
        case .folderBefore, .folderEnd:
            break
        }
        syncSidebar()
    }

    private func showTabMenu(_ id: UUID, _ event: NSEvent) {
        let space = currentSpace
        guard space.tab(with: id) != nil else { return }

        // Le glisser-déposer reste le geste principal ; ce niveau est le chemin
        // équivalent pour qui préfère ne pas viser.
        var destinations = space.folders.map { folder in
            ActionItem(title: folder.name, symbol: "folder",
                       action: { [weak self] in
                           guard let self, let tab = self.currentSpace.tab(with: id) else { return }
                           self.currentSpace.place(tab, at: .into(folder))
                           self.syncSidebar()
                       })
        }
        if !destinations.isEmpty { destinations.append(.separator) }
        destinations.append(ActionItem(title: "Hors dossier", symbol: "tray",
                                       action: { [weak self] in
                                           guard let self, let tab = self.currentSpace.tab(with: id) else { return }
                                           self.currentSpace.place(tab, at: .looseEnd)
                                           self.syncSidebar()
                                       }))

        let items: [ActionItem] = [
            ActionItem(title: "Déplacer vers", symbol: "arrow.right.doc.on.clipboard",
                       children: destinations),
            .separator,
            ActionItem(title: "Fermer l'onglet", symbol: "xmark", shortcut: "⌘W",
                       isDestructive: true,
                       action: { [weak self] in self?.close(tabID: id) })
        ]
        presentSheet(items, at: event)
    }

    private func showFolderMenu(_ id: UUID, _ event: NSEvent) {
        let items: [ActionItem] = [
            ActionItem(title: "Renommer", symbol: "pencil",
                       action: { [weak self] in self?.renameFolder(id) }),
            ActionItem(title: "Supprimer le dossier", symbol: "trash", isDestructive: true,
                       action: { [weak self] in self?.deleteFolder(id) })
        ]
        presentSheet(items, at: event)
    }

    private func presentSheet(_ items: [ActionItem], at event: NSEvent) {
        let point = layout.convert(event.locationInWindow, from: nil)
        layout.actionSheet.present(items, at: point)
    }

    /// Renommer un dossier passe par une boîte de dialogue, faute d'une ligne qui puisse
    /// devenir éditable comme dans le panneau des espaces — la sidebar reconstruit ses
    /// lignes à chaque changement, l'édition en place n'y survivrait pas.
    private func renameFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        layout.actionSheet.presentPrompt(title: "Renommer le dossier",
                                         value: folder.name,
                                         confirm: "Renommer") { [weak self] name in
            guard let self, let folder = self.currentSpace.folder(with: id) else { return }
            folder.name = name
            self.syncSidebar()
        }
    }

    /// Supprimer un dossier ne ferme pas ses onglets : ils redeviennent des onglets de
    /// passage. Rien à confirmer, rien n'est perdu.
    private func deleteFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        currentSpace.removeFolder(folder)
        syncSidebar()
    }

    // MARK: - Navigation

    @objc func focusOmnibox(_ sender: Any?) { openOmnibox() }
    @objc func reload(_ sender: Any?) { currentTab?.webView.reload() }
    /// Le zoom est un réglage de l'application, pas de l'onglet.
    ///
    /// Régler la taille du texte page par page obligerait à le refaire partout ; c'est une
    /// question de vue, pas de site. Le raccourci modifie donc le même réglage que la page
    /// « Sites web », et toutes les pages suivent.
    @objc func zoomIn(_ sender: Any?)  { setZoom(settings.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(settings.pageZoom - 0.1) }
    @objc func zoomReset(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ value: CGFloat) {
        let clamped = min(max(0.5, (value * 10).rounded() / 10), 2)
        guard clamped != settings.pageZoom else { return }
        settings.pageZoom = clamped
        layout.toast.show("Zoom \(Int(clamped * 100)) %")
    }

    @objc func goBack(_ sender: Any?) { currentTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { currentTab?.webView.goForward() }

    /// `creatingTab` : la destination choisie ouvrira un onglet au lieu de remplacer la
    /// page courante.
    private func openOmnibox(creatingTab: Bool = false) {
        omniboxCreatesTab = creatingTab
        layout.omnibox.present(in: window,
                               seed: creatingTab ? "" : (currentTab?.url?.absoluteString ?? ""))
    }

    /// Ouvre l'adresse là où il faut : dans un nouvel onglet si la palette a été appelée
    /// pour ça, dans la page courante sinon — et dans un onglet neuf s'il n'y en a aucun.
    private func go(to url: URL) {
        guard !omniboxCreatesTab, let tab = currentTab else {
            newTab(url: url)
            return
        }
        tab.webView.load(URLRequest(url: url))
    }

    // MARK: - ContentTopBarDelegate

    func topBarDidRequestOmnibox(_ bar: ContentTopBar) {
        openOmnibox()
    }

    func topBar(_ bar: ContentTopBar, didTrigger action: ContentTopBar.Action) {
        switch action {
        case .back:    currentTab?.webView.goBack()
        case .forward: currentTab?.webView.goForward()
        case .menu:    layout.actionSheet.present(mainMenu(), below: bar.menuButton)
        case .blocking: layout.actionSheet.present(blockingMenu(), below: bar.blockingButton)
        case .scripts:  layout.actionSheet.present(scriptsMenu(), below: bar.scriptsButton)
        }
    }

    /// Le menu principal ne contient que ce qui existe. La maquette en montrait onze
    /// entrées ; les favoris, l'historique, les téléchargements et la session privée
    /// n'existent pas encore, et les afficher grisés donnerait l'illusion d'un produit
    /// plus avancé qu'il ne l'est.
    private func mainMenu() -> [ActionItem] {
        var items: [ActionItem] = [
            ActionItem(title: "Nouvel onglet", symbol: "plus", shortcut: "⌘T",
                       action: { [weak self] in self?.newTab(nil) }),
            ActionItem(title: "Nouveau dossier", symbol: "folder.badge.plus", shortcut: "⇧⌘N",
                       action: { [weak self] in self?.newFolder(nil) })
        ]
        // Seulement quand il y a quelque chose à rouvrir : une entrée grisée en
        // permanence apprend à ne plus lire cette ligne.
        if !closedTabs.isEmpty {
            items.append(ActionItem(title: "Rouvrir l'onglet fermé", symbol: "arrow.uturn.left",
                                    shortcut: "⇧⌘T",
                                    action: { [weak self] in self?.reopenClosedTab(nil) }))
        }
        items.append(.separator)

        // Le libellé dit dans quel sens ça va, et la ligne n'existe que si la page peut
        // être mise de côté : une page vierge n'a rien à garder.
        if let tab = currentTab, let url = favoritableURL(of: tab) {
            let known = favorites.contains(url)
            items.append(ActionItem(title: known ? "Retirer des favoris" : "Ajouter aux favoris",
                                    symbol: known ? "star.fill" : "star", shortcut: "⌘D",
                                    action: { [weak self] in self?.toggleFavorite(nil) }))
        }
        items.append(ActionItem(title: "Favoris", symbol: "star.square", shortcut: "⇧⌘B",
                                action: { [weak self] in self?.showFavorites(nil) }))

        items.append(contentsOf: [
            ActionItem(title: "Historique", symbol: "clock", shortcut: "⌘Y",
                       action: { [weak self] in self?.showHistory(nil) }),
            ActionItem(title: "Téléchargements", symbol: "arrow.down.circle", shortcut: "⌘J",
                       action: { [weak self] in self?.showDownloads(nil) }),
            ActionItem(title: "Rechercher dans la page…", symbol: "magnifyingglass", shortcut: "⌘F",
                       action: { [weak self] in self?.findInPage(nil) }),
            ActionItem(title: "Imprimer…", symbol: "printer", shortcut: "⌘P",
                       action: { [weak self] in self?.printPage(nil) }),
            .separator,
            ActionItem(title: "Réglages…", symbol: "gearshape", shortcut: "⌘,",
                       action: { [weak self] in self?.openSettings(nil) }),
            ActionItem(title: "À propos de Wuji", symbol: "info.circle",
                       action: { NSApp.orderFrontStandardAboutPanel(nil) })
        ])
        return items
    }

    // MARK: - Menu contextuel de la page

    /// Ancré sur le curseur, et non sur les coordonnées de l'événement : le clic vient
    /// d'avoir lieu, la souris est encore dessus. C'est vrai jusque dans les cadres
    /// imbriqués, où les coordonnées de la page ne sont plus celles de la fenêtre.
    private func showPageMenu(_ target: PageContextMenu.Target) {
        let items = contextItems(for: target)
        guard !items.isEmpty, let window, let layout else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        layout.actionSheet.present(items, at: layout.convert(inWindow, from: nil))
    }

    /// Le menu parle de ce qui est sous le curseur, et de rien d'autre. Sur un lien il
    /// parle du lien ; sur une image, de l'image ; sur du vide, de la page. Un menu qui
    /// dirait tout à chaque fois obligerait à chercher la seule ligne qui s'applique.
    private func contextItems(for target: PageContextMenu.Target) -> [ActionItem] {
        var items: [ActionItem] = []
        func startGroup() {
            if !items.isEmpty { items.append(.separator) }
        }

        if let link = target.link {
            items.append(ActionItem(title: "Ouvrir dans un nouvel onglet", symbol: "square.on.square",
                                    action: { [weak self] in self?.openInNewTab(link, activate: false) }))
            items.append(ActionItem(title: "Copier l'adresse du lien", symbol: "link",
                                    action: { Self.copy(link.absoluteString) }))
        }

        if let image = target.image, PageContextMenu.isAddressable(image) {
            startGroup()
            items.append(ActionItem(title: "Ouvrir l'image dans un nouvel onglet", symbol: "photo",
                                    action: { [weak self] in self?.openInNewTab(image, activate: false) }))
            items.append(ActionItem(title: "Copier l'adresse de l'image", symbol: "link",
                                    action: { Self.copy(image.absoluteString) }))
            items.append(ActionItem(title: "Enregistrer l'image…", symbol: "arrow.down.circle",
                                    action: { [weak self] in self?.download(image) }))
        }

        if target.isEditable {
            // Dans un champ, l'ordre est celui que tout le monde connaît. Ces trois-là
            // passent par les actions standard plutôt que par le presse-papiers : c'est
            // le champ de la page qui sait où insérer, pas nous.
            var edit: [ActionItem] = []
            if !target.selection.isEmpty {
                edit.append(ActionItem(title: "Couper", symbol: "scissors", shortcut: "⌘X",
                                       action: { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }))
                edit.append(ActionItem(title: "Copier", symbol: "doc.on.doc", shortcut: "⌘C",
                                       action: { Self.copy(target.selection) }))
            }
            if NSPasteboard.general.string(forType: .string) != nil {
                edit.append(ActionItem(title: "Coller", symbol: "doc.on.clipboard", shortcut: "⌘V",
                                       action: { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }))
            }
            if !edit.isEmpty {
                startGroup()
                items.append(contentsOf: edit)
            }
        } else if !target.selection.isEmpty {
            startGroup()
            items.append(ActionItem(title: "Copier", symbol: "doc.on.doc", shortcut: "⌘C",
                                    action: { Self.copy(target.selection) }))
            if let url = settings.searchEngine.url(for: target.selection) {
                // La recherche part dans un nouvel onglet : on cherche un mot **en lisant**
                // une page, et perdre la page serait perdre la raison de chercher.
                items.append(ActionItem(title: Self.searchTitle(for: target.selection),
                                        symbol: "magnifyingglass",
                                        action: { [weak self] in self?.openInNewTab(url, activate: true) }))
            }
        }

        guard items.isEmpty else { return items }

        // Rien sous le curseur : le menu parle alors de la page elle-même. Précédent et
        // suivant n'apparaissent que s'il y a quelque chose derrière ou devant — une
        // entrée grisée en permanence est une entrée qu'on apprend à ne plus lire.
        guard let tab = currentTab else { return [] }
        if tab.webView.canGoBack {
            items.append(ActionItem(title: "Précédent", symbol: "chevron.left",
                                    action: { [weak self] in self?.goBack(nil) }))
        }
        if tab.webView.canGoForward {
            items.append(ActionItem(title: "Suivant", symbol: "chevron.right",
                                    action: { [weak self] in self?.goForward(nil) }))
        }
        items.append(ActionItem(title: "Recharger", symbol: "arrow.clockwise", shortcut: "⌘R",
                                action: { [weak self] in self?.reload(nil) }))
        if let url = tab.url, !isBlank(tab) {
            items.append(.separator)
            items.append(ActionItem(title: "Copier l'adresse de la page", symbol: "link",
                                    action: { Self.copy(url.absoluteString) }))
        }
        return items
    }

    /// Assez de la sélection pour la reconnaître, jamais assez pour couper la ligne.
    ///
    /// La citation est raccourcie **jusqu'à ce qu'elle tienne**, et non à un nombre de
    /// caractères choisi d'avance : une troncature par la feuille emporterait le guillemet
    /// fermant, et on ne saurait plus où finit ce qu'on a sélectionné.
    private static func searchTitle(for selection: String) -> String {
        let flat = selection.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        func title(_ quote: String) -> String { "Rechercher « \(quote) »" }
        guard !ActionSheet.fits(title: title(flat)) else { return title(flat) }

        var candidate = flat
        while !candidate.isEmpty, !ActionSheet.fits(title: title(candidate + "…")) {
            candidate.removeLast()
        }
        return title(candidate.trimmingCharacters(in: .whitespaces) + "…")
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Télécharger sans naviguer : enregistrer une image ne doit pas quitter la page où
    /// on l'a trouvée.
    private func download(_ url: URL) {
        guard let webView = currentTab?.webView else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated { self?.register(download, source: url) }
        }
    }

    @objc func showHistory(_ sender: Any?) {
        openInternal(URL(string: "wuji://history")!)
    }

    /// Dans l'onglet courant s'il est vierge ou s'il montre déjà cette page, dans un
    /// nouveau sinon : consulter deux fois l'historique ne doit pas laisser deux onglets.
    private func openInternal(_ url: URL) {
        if let tab = currentTab, tab.url == nil || tab.url == Self.blankPage || tab.url == url {
            tab.webView.load(URLRequest(url: url))
        } else {
            newTab(url: url)
        }
    }

    /// Les actions des pages internes. Elles ne touchent à rien elles-mêmes : elles
    /// demandent, l'application décide.
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any] else { return }
            if message.name == MediaWatcher.handler {
                // La page dit ce qu'elle joue ; l'onglet le retient pour la sidebar.
                let playing = payload["playing"] as? Bool ?? false
                if let tab = spaces.flatMap(\.allTabs).first(where: { $0.webView === message.webView }),
                   tab.isPlayingMedia != playing {
                    tab.isPlayingMedia = playing
                    syncSidebar()
                }
                return
            }
            if message.name == BlockLogWatcher.handler {
                let host = message.frameInfo.request.url?.host() ?? ""
                for raw in payload["refused"] as? [String] ?? [] {
                    guard let url = URL(string: raw) else { continue }
                    blockLog.record(.refused, host: host,
                                    detail: (url.host() ?? "") + url.path)
                }
                return
            }
            if message.name == ElementPicker.handler {
                addPickedRule(payload["selector"] as? String ?? "")
                return
            }
            if message.name == PageContextMenu.handler {
                showPageMenu(PageContextMenu.Target(payload: payload))
                return
            }
            if message.name == "wujiError" {
                guard let raw = payload["url"] as? String, let url = URL(string: raw) else { return }
                // « Ne pas bloquer ce site » depuis la page d'erreur : l'exception, puis
                // la page. Sans le second geste, on resterait devant l'échec en croyant
                // que le réglage n'a rien fait.
                if payload["action"] as? String == "allow" { blocker.toggleException(for: url) }
                currentTab?.webView.load(URLRequest(url: url))
                return
            }
            guard let action = payload["action"] as? String else { return }
            if message.name == "wujiDownloads" {
                handleDownloadAction(action, id: payload["id"] as? String)
                return
            }
            if message.name == "wujiFavorites" {
                handleFavoriteAction(action, id: payload["id"] as? String)
                return
            }
            if message.name == "wujiSettings" {
                handleSettingsAction(action, payload: payload)
                return
            }
            if message.name == "wujiScripts" {
                handleScriptAction(action, payload: payload)
                return
            }
            if message.name == "wujiAdBlock" {
                handleAdBlockAction(action, payload: payload)
                return
            }
            switch action {
            case "delete":
                if let url = payload["url"] as? String { history.delete(url: url) }
            case "clear":
                history.clear()
                currentTab?.webView.reload()
            default:
                break
            }
        }
    }

    private func handleDownloadAction(_ action: String, id: String?) {
        switch action {
        case "clear":
            downloads.clearFinished()
            currentTab?.webView.reload()

        case "reveal":
            guard let destination = downloads.item(id: id)?.destination else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])

        case "pause":
            guard let item = downloads.item(id: id), let download = item.download else { return }
            item.sample()
            item.state = .paused
            item.observation = nil
            // Mettre en pause, c'est annuler en gardant de quoi reprendre : WebKit n'a pas
            // d'autre mécanisme, et sans ces données la reprise repartirait de zéro.
            download.cancel { [weak self] data in
                MainActor.assumeIsolated {
                    item.resumeData = data
                    item.download = nil
                    self?.refreshDownloads(reload: true)
                }
            }

        case "resume":
            guard let item = downloads.item(id: id), let data = item.resumeData,
                  let webView = currentTab?.webView else { return }
            item.state = .running
            item.resumeData = nil
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                MainActor.assumeIsolated { self?.attach(download, to: item) }
            }

        case "cancel":
            guard let item = downloads.item(id: id) else { return }
            item.download?.cancel { _ in }
            item.state = .failed("Annulé")
            item.observation = nil
            item.download = nil
            // Le fichier partiel n'a plus d'usage : le laisser dans Téléchargements
            // ferait croire à un fichier complet.
            if let destination = item.destination { try? FileManager.default.removeItem(at: destination) }
            refreshDownloads(reload: true)

        case "retry":
            guard let item = downloads.item(id: id), let webView = currentTab?.webView else { return }
            downloads.remove(item)
            // `startDownload` plutôt qu'une navigation : réessayer ne doit pas déplacer la
            // page qu'on est en train de regarder.
            webView.startDownload(using: URLRequest(url: item.source)) { [weak self] download in
                MainActor.assumeIsolated { self?.register(download, source: item.source) }
            }

        default:
            break
        }
    }

    /// Rebranche un téléchargement repris sur l'élément existant : c'est un nouvel objet
    /// WebKit, mais la même ligne pour l'utilisateur.
    private func attach(_ download: WKDownload, to item: DownloadItem) {
        download.delegate = self
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDownloads() }
        }
        refreshDownloads(reload: true)
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = currentTab?.webView else { return }
        webView.printOperation(with: .shared).run()
    }

    // MARK: - Espaces

    private var spaceSnapshots: [SpaceRowSnapshot] {
        spaces.map {
            SpaceRowSnapshot(name: $0.name, symbol: $0.symbol, tabCount: $0.tabCount)
        }
    }

    private func showSpacesPanel(from anchor: NSView) {
        layout.spacesPanel.present(spaces: spaceSnapshots,
                                   current: currentSpaceIndex,
                                   symbol: currentSpace.symbol,
                                   anchor: anchor)
    }

    func spacesPanel(_ panel: SpacesPanel, didSelect index: Int) {
        guard spaces.indices.contains(index), index != currentSpaceIndex else { return }
        currentSpaceIndex = index
        // Un espace vide n'existe pas : on y entre toujours sur un onglet.
        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
    }

    func spacesPanel(_ panel: SpacesPanel, didPick symbol: String) {
        // Le symbole d'un espace privé ne se change pas : c'est à quoi on le reconnaît.
        guard !currentSpace.isPrivate else {
            layout.toast.show("Le symbole d'un espace privé ne change pas")
            return
        }
        currentSpace.symbol = symbol
        refreshSpaces(panel)
    }

    func spacesPanel(_ panel: SpacesPanel, didRename index: Int, to name: String) {
        guard spaces.indices.contains(index) else { return }
        spaces[index].name = name
        refreshSpaces(panel)
    }

    func spacesPanel(_ panel: SpacesPanel, didMove index: Int, to destination: Int) {
        guard spaces.indices.contains(index), spaces.indices.contains(destination) else { return }
        // L'espace courant est suivi par son identité, pas par sa position : réordonner
        // ne doit pas faire basculer l'utilisateur dans un autre espace.
        let staying = currentSpace
        let moved = spaces.remove(at: index)
        spaces.insert(moved, at: destination)
        if let position = spaces.firstIndex(where: { $0 === staying }) {
            currentSpaceIndex = position
        }
        refreshSpaces(panel)
    }

    func spacesPanel(_ panel: SpacesPanel, menuFor index: Int, canDelete: Bool, at event: NSEvent) {
        let items: [ActionItem] = [
            ActionItem(title: "Renommer", symbol: "pencil",
                       action: { [weak panel] in panel?.beginRename(at: index) }),
            ActionItem(title: spaces.indices.contains(index) && spaces[index].isPrivate
                              ? "Rendre cet espace normal" : "Rendre cet espace privé",
                       symbol: spaces.indices.contains(index) && spaces[index].isPrivate
                              ? "eye" : "eye.slash",
                       action: { [weak self, weak panel] in
                           panel?.dismiss()
                           self?.togglePrivate(at: index)
                       }),
            .separator,
            ActionItem(title: "Supprimer", symbol: "trash", isEnabled: canDelete,
                       isDestructive: true,
                       action: { [weak self, weak panel] in
                           panel?.dismiss()
                           guard let self else { return }
                           self.spacesPanel(panel ?? self.layout.spacesPanel, didDelete: index)
                       })
        ]
        presentSheet(items, at: event)
    }

    /// Bascule un espace entre normal et privé.
    ///
    /// Les onglets déjà ouverts ne changent pas de monde : leurs vues web sont nées avec
    /// un magasin de données, et on ne le remplace pas sous leurs pieds. La bascule vaut
    /// donc pour la suite, et on le dit plutôt que de laisser croire à un effacement.
    private func togglePrivate(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        let space = spaces[index]
        space.isPrivate.toggle()
        layout.toast.show(space.isPrivate
                          ? "« \(space.name) » est privé : rien ne sera enregistré"
                          : "« \(space.name) » redevient normal")
        syncSidebar()
        session.save(snapshot())
    }

    func spacesPanel(_ panel: SpacesPanel, didDelete index: Int) {
        guard spaces.indices.contains(index), spaces.count > 1 else { return }
        let doomed = spaces[index]

        // Supprimer un espace ferme ses onglets, et rien ne les rouvrira tant qu'il n'y a
        // pas d'historique : c'est une perte, donc on demande.
        guard !doomed.isEmpty else { return removeSpace(at: index) }
        layout.toast.ask(
            title: "Supprimer « \(doomed.name) » ?",
            message: doomed.tabCount == 1
                ? "Son onglet sera fermé, et rien ne le rouvrira."
                : "Ses \(doomed.tabCount) onglets seront fermés, et rien ne les rouvrira.",
            confirm: "Supprimer", isDestructive: true, onCancel: {},
            onConfirm: { [weak self] in self?.removeSpace(at: index) })
    }

    private func removeSpace(at index: Int) {
        guard spaces.indices.contains(index), spaces.count > 1 else { return }
        spaces.remove(at: index)
        currentSpaceIndex = min(currentSpaceIndex, spaces.count - 1)
        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
    }

    /// Le panneau reste ouvert pendant qu'on règle un espace : il faut donc rafraîchir
    /// les deux surfaces, la sidebar et le panneau lui-même.
    private func refreshSpaces(_ panel: SpacesPanel) {
        syncSidebar()
        panel.reload(spaces: spaceSnapshots,
                     current: currentSpaceIndex,
                     symbol: currentSpace.symbol)
    }

    func spacesPanelDidRequestNew(_ panel: SpacesPanel) {
        let index = spaces.count
        spaces.append(Space(name: "Espace \(index + 1)", symbol: Space.symbol(forIndex: index)))
        currentSpaceIndex = index
        newTab(url: nil)
    }

    // MARK: - Recherche dans la page

    @objc func findInPage(_ sender: Any?) {
        layout.findBar.present(in: window)
    }

    @objc func findNext(_ sender: Any?) {
        guard layout.findBar.isOpen else { return }
        findBarDidRequestNext(layout.findBar)
    }

    @objc func findPrevious(_ sender: Any?) {
        guard layout.findBar.isOpen else { return }
        findBarDidRequestPrevious(layout.findBar)
    }

    func findBar(_ bar: FindBar, didChange query: String) {
        findPosition = 1
        search(query, backwards: false)
        countMatches(of: query)
    }

    func findBarDidRequestNext(_ bar: FindBar) {
        findPosition = findTotal.map { $0 > 0 ? (findPosition % $0) + 1 : 1 } ?? findPosition + 1
        search(bar.query, backwards: false)
    }

    func findBarDidRequestPrevious(_ bar: FindBar) {
        findPosition = findTotal.map { $0 > 0 ? (findPosition - 2 + $0) % $0 + 1 : 1 } ?? max(1, findPosition - 1)
        search(bar.query, backwards: true)
    }

    func findBarDidClose(_ bar: FindBar) {
        findTotal = nil
        findPosition = 1
        // Aucune API publique ne « décoche » une recherche : on retire la sélection,
        // ce qui efface le surlignage laissé par WebKit.
        currentTab?.webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    private func search(_ query: String, backwards: Bool) {
        guard let webView = currentTab?.webView, !query.isEmpty else {
            layout.findBar.show(position: 0, total: nil)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true

        webView.find(query, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layout.findBar.show(position: self.findPosition,
                                         total: result.matchFound ? self.findTotal : 0)
            }
        }
    }

    /// `WKFindResult` ne dit que « trouvé ou non » : ni total, ni position. Le compteur
    /// est donc reconstitué ici, par un balayage du texte de la page.
    ///
    /// **C'est une approximation du moteur de recherche de WebKit, pas sa vérité** : ce
    /// balayage lit `innerText`, donc il ignore les iframes et compte différemment un mot
    /// coupé entre deux nœuds. Sur une page ordinaire il tombe juste ; sur une page
    /// composite il peut diverger de ce que la navigation surligne réellement.
    private func countMatches(of query: String) {
        guard let webView = currentTab?.webView,
              !query.isEmpty,
              let encoded = try? JSONSerialization.data(withJSONObject: [query]),
              let literal = String(data: encoded, encoding: .utf8) else {
            findTotal = nil
            return
        }
        let script = """
        (function (needle) {
            if (!needle || !document.body) { return 0; }
            var haystack = document.body.innerText.toLowerCase();
            needle = needle.toLowerCase();
            var count = 0, at = 0;
            while ((at = haystack.indexOf(needle, at)) !== -1) { count++; at += needle.length; }
            return count;
        })(\(literal)[0]);
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.findTotal = value as? Int
                self.layout.findBar.show(position: self.findPosition, total: self.findTotal)
            }
        }
    }

    // MARK: - OmniboxDelegate

    /// **Ce qu'on tape passe en premier**, les onglets ouverts ensuite.
    ///
    /// L'ordre du tableau est l'ordre affiché et celui de la sélection : la première ligne
    /// est donc toujours la lecture littérale de la frappe. Un onglet ouvert en tête ferait
    /// changer la cible de `↵` au fil de la saisie — on taperait une recherche pour
    /// atterrir sur une page qu'on avait déjà, sans l'avoir demandé.
    func omnibox(_ omnibox: Omnibox, resultsFor query: String) -> [OmniboxResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var matchingTabs: [OmniboxResult] = []
        for (spaceIndex, space) in spaces.enumerated() {
            for tab in space.allTabs {
                guard !isBlank(tab) else { continue }
                guard !(spaceIndex == currentSpaceIndex && tab === space.current) else { continue }
                let haystack = "\(tab.title) \(tab.url?.absoluteString ?? "")".lowercased()
                guard trimmed.isEmpty || haystack.contains(trimmed.lowercased()) else { continue }
                // L'espace n'est rappelé que s'il n'est pas celui où l'on se trouve :
                // le préciser à chaque ligne serait du bruit dans le cas courant.
                let host = tab.url?.host() ?? "onglet"
                let subtitle = spaceIndex == currentSpaceIndex ? host : "\(space.name) · \(host)"
                matchingTabs.append(.tab(space: spaceIndex,
                                         tab: tab.id,
                                         title: tab.title,
                                         subtitle: subtitle,
                                         icon: favicons.icon(for: tab.url)))
            }
        }

        guard !trimmed.isEmpty else { return matchingTabs }

        // Pas d'historique ici : la palette sert à aller quelque part qu'on a en tête, et
        // une liste de pages déjà visitées la ferait relire à chaque frappe. Chercher dans
        // ce qu'on a vu est un autre geste, et il a sa page — `wuji://history`.
        //
        // L'adresse avant la recherche quand la frappe en est une : « exemple.fr » veut
        // aller sur exemple.fr, pas chercher ces neuf caractères.
        var results: [OmniboxResult] = []
        if let url = Self.directURL(trimmed) { results.append(.url(url)) }
        results.append(.search(trimmed))
        return results + matchingTabs
    }

    func omnibox(_ omnibox: Omnibox, didActivate result: OmniboxResult) {
        switch result {
        case .tab(let spaceIndex, let tabID, _, _, _):
            currentSpaceIndex = spaceIndex
            if let tab = currentSpace.tab(with: tabID) { currentSpace.current = tab }
            activateCurrentTab()
        case .url(let url):
            go(to: url)
        case .search(let query):
            if let url = settings.searchEngine.url(for: query) { go(to: url) }
        }
    }

    func omniboxDidDismiss(_ omnibox: Omnibox) {}

    /// Une adresse ou une recherche — la seule ambiguïté que l'omnibox doit lever.
    static func directURL(_ input: String) -> URL? {
        // Les pages de l'application n'ont pas de point dans leur nom : « wuji://settings »
        // partait en recherche, ce qui est le contraire de ce qu'on demande en le tapant.
        if input.hasPrefix("\(InternalPageHandler.scheme)://") { return URL(string: input) }

        guard !input.contains(" "), input.contains(".") else { return nil }
        let candidate = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }

    // MARK: - Menus

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Réglages…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Wuji", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Wuji", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Fichier")
        fileMenu.addItem(withTitle: "Nouvel onglet", action: #selector(newTab(_:)), keyEquivalent: "t")
        // ⇧⌘N est le raccourci de la navigation privée partout ailleurs : le dossier lui
        // cède la place et passe sur ⌥⌘N.
        let privateItem = NSMenuItem(title: "Nouvel espace privé",
                                     action: #selector(newPrivateSpace(_:)), keyEquivalent: "N")
        privateItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(privateItem)
        let folderItem = NSMenuItem(title: "Nouveau dossier",
                                    action: #selector(newFolder(_:)), keyEquivalent: "n")
        folderItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(folderItem)
        fileMenu.addItem(withTitle: "Fermer l'onglet", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let reopenItem = NSMenuItem(title: "Rouvrir l'onglet fermé",
                                    action: #selector(reopenClosedTab(_:)), keyEquivalent: "T")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(reopenItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Indispensable : sans menu Édition, ⌘C/⌘V ne fonctionnent pas dans l'omnibox.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Présentation")
        viewMenu.addItem(withTitle: "Omnibox", action: #selector(focusOmnibox(_:)), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Recharger", action: #selector(reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Agrandir", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Réduire", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Taille réelle", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Ajouter aux favoris", action: #selector(toggleFavorite(_:)),
                         keyEquivalent: "d")
        let favoritesItem = NSMenuItem(title: "Favoris", action: #selector(showFavorites(_:)),
                                       keyEquivalent: "B")
        favoritesItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(favoritesItem)
        viewMenu.addItem(withTitle: "Blocage", action: #selector(showAdBlock(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Scripts", action: #selector(showScripts(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Historique", action: #selector(showHistory(_:)), keyEquivalent: "y")
        viewMenu.addItem(withTitle: "Téléchargements", action: #selector(showDownloads(_:)), keyEquivalent: "j")
        viewMenu.addItem(withTitle: "Rechercher dans la page…", action: #selector(findInPage(_:)), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "Résultat suivant", action: #selector(findNext(_:)), keyEquivalent: "g")
        let previousMatch = NSMenuItem(title: "Résultat précédent",
                                       action: #selector(findPrevious(_:)), keyEquivalent: "G")
        previousMatch.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(previousMatch)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Onglet suivant", action: #selector(nextTab(_:)), keyEquivalent: "]")
        viewMenu.addItem(withTitle: "Onglet précédent", action: #selector(previousTab(_:)), keyEquivalent: "[")

        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}
