import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ContentTopBarDelegate, OmniboxDelegate, FindBarDelegate, SpacesPanelDelegate,
                       WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private var window: BrowserWindow!
    private var layout: BrowserLayout!

    private let favicons = FaviconStore()
    private let session = SessionStore()
    private let history = HistoryStore()
    private let settings = Settings()
    private var settingsWindow: SettingsWindow?

    /// Les onglets appartiennent à un espace, jamais à l'application. Tout ce qui suit
    /// passe donc par `currentSpace` — c'est ce qui évite d'avoir deux notions
    /// d'« onglet courant » qui se désynchronisent.
    private var spaces: [Space] = []
    private var currentSpaceIndex = 0

    /// Position et total de la recherche dans la page, tenus à la main — voir `countMatches`.
    private var findPosition = 1
    private var findTotal: Int?
    private var omniboxCreatesTab = false

    private lazy var configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Le gestionnaire doit être posé avant la création de la moindre vue web : une
        // configuration déjà utilisée ne l'accepte plus.
        config.setURLSchemeHandler(InternalPageHandler(history: history),
                                   forURLScheme: InternalPageHandler.scheme)
        config.userContentController.add(self, name: "wujiHistory")
        return config
    }()

    private var currentSpace: Space { spaces[currentSpaceIndex] }
    private var currentTab: Tab? { currentSpace.current }

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        layout.sidebar.onSpaceClick = { [weak self] anchor in self?.showSpacesPanel(from: anchor) }

        favicons.onUpdate = { [weak self] in self?.syncSidebar() }

        window.contentView = layout

        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()

        history.purge(olderThan: settings.historyRetention)
        restoreSession()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // La sauvegarde différée peut être en attente au moment où l'on quitte.
        session.save(snapshot())
    }

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
        StoredSession(
            spaces: spaces.map { space in
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
        NSApp.appearance = settings.theme.appearance

        for tab in spaces.flatMap(\.allTabs) {
            tab.webView.pageZoom = settings.pageZoom
            tab.webView.isInspectable = settings.safariInspection
            // Une couleur dynamique posée sur WebKit est résolue à l'affectation : il faut
            // la réécrire quand le thème change.
            tab.webView.underPageBackgroundColor = Tokens.chromeBackground
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = SettingsWindow(settings: settings)
            window.historyCount = { [weak self] in self?.history.count ?? 0 }
            window.onClearHistory = { [weak self] in self?.history.clear() }
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Le libellé du menu suit ce que la touche va réellement faire. « Fermer l'onglet »
    /// affiché alors que ⌘W fermera les Réglages serait un mensonge, même bref.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeTab(_:)) {
            let auxiliary = NSApp.keyWindow != nil && NSApp.keyWindow !== window
            item.title = auxiliary ? "Fermer la fenêtre" : "Fermer l'onglet"
        }
        return true
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
        let tab = Tab(configuration: override ?? configuration,
                      pendingURL: pendingURL, pendingTitle: pendingTitle)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.webView.pageZoom = settings.pageZoom
        tab.webView.isInspectable = settings.safariInspection
        // Un onglet vierge ne montre plus le blanc par défaut de WebKit : il prend le fond
        // du thème. Sans ça, ouvrir un onglet en thème sombre projette une page blanche
        // pleine hauteur, et c'est le contraire d'une interface qui se fait oublier.
        tab.webView.underPageBackgroundColor = Tokens.chromeBackground

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
        guard navigationAction.navigationType == .linkActivated,
              navigationAction.modifierFlags.contains(.command),
              let url = navigationAction.request.url else { return .allow }
        openInNewTab(url, activate: navigationAction.modifierFlags.contains(.shift))
        return .cancel
    }

    /// Une page vue est une page arrivée. Enregistrer au départ de la navigation
    /// compterait les redirections et les erreurs comme des visites.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        history.record(url: url, title: webView.title ?? "")
    }

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
        currentSpace.remove(tab)
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
        // C'est ici que le chargement différé se dénoue : un onglet restauré ne va
        // chercher sa page qu'au moment où on le regarde.
        tab.loadIfPending()
        layout.content.attach(tab.webView)
        syncChrome()
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
             isLoading: tab.webView.isLoading, favicon: favicons.icon(for: tab.url), depth: depth)
    }

    // MARK: - Dossiers et déplacements

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
        }
    }

    /// Le menu principal ne contient que ce qui existe. La maquette en montrait onze
    /// entrées ; les favoris, l'historique, les téléchargements et la session privée
    /// n'existent pas encore, et les afficher grisés donnerait l'illusion d'un produit
    /// plus avancé qu'il ne l'est.
    private func mainMenu() -> [ActionItem] {
        [
            ActionItem(title: "Nouvel onglet", symbol: "plus", shortcut: "⌘T",
                       action: { [weak self] in self?.newTab(nil) }),
            ActionItem(title: "Nouveau dossier", symbol: "folder.badge.plus", shortcut: "⇧⌘N",
                       action: { [weak self] in self?.newFolder(nil) }),
            .separator,
            ActionItem(title: "Historique", symbol: "clock", shortcut: "⌘Y",
                       action: { [weak self] in self?.showHistory(nil) }),
            ActionItem(title: "Rechercher dans la page…", symbol: "magnifyingglass", shortcut: "⌘F",
                       action: { [weak self] in self?.findInPage(nil) }),
            ActionItem(title: "Imprimer…", symbol: "printer", shortcut: "⌘P",
                       action: { [weak self] in self?.printPage(nil) }),
            .separator,
            ActionItem(title: "Réglages…", symbol: "gearshape", shortcut: "⌘,",
                       action: { [weak self] in self?.openSettings(nil) }),
            ActionItem(title: "À propos de Wuji", symbol: "info.circle",
                       action: { NSApp.orderFrontStandardAboutPanel(nil) })
        ]
    }

    @objc func showHistory(_ sender: Any?) {
        guard let url = URL(string: "wuji://history") else { return }
        // Dans l'onglet courant s'il est vierge, dans un nouveau sinon : ouvrir un onglet
        // par consultation de l'historique en laisserait une traînée.
        if let tab = currentTab, tab.url == nil || tab.url == Self.blankPage {
            tab.webView.load(URLRequest(url: url))
        } else {
            newTab(url: url)
        }
    }

    /// Les actions de la page d'historique. Elle ne touche pas la base elle-même : elle
    /// demande, l'application décide.
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any],
                  let action = payload["action"] as? String else { return }
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

    func spacesPanel(_ panel: SpacesPanel, didDelete index: Int) {
        guard spaces.indices.contains(index), spaces.count > 1 else { return }
        let doomed = spaces[index]

        // Supprimer un espace ferme ses onglets, et rien ne les rouvrira tant qu'il n'y a
        // pas d'historique : c'est une perte, donc on demande.
        guard !doomed.isEmpty else { return removeSpace(at: index) }
        layout.actionSheet.presentConfirmation(
            title: "Supprimer « \(doomed.name) » ?",
            message: doomed.tabCount == 1
                ? "Son onglet sera fermé, et rien ne le rouvrira."
                : "Ses \(doomed.tabCount) onglets seront fermés, et rien ne les rouvrira.",
            confirm: "Supprimer",
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

    /// Les onglets ouverts passent avant tout le reste : même avec une sidebar, chercher
    /// un onglet au clavier doit rester plus rapide que le viser à la souris.
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

        var results = matchingTabs
        // L'historique après les onglets ouverts : un onglet déjà là se retrouve plus vite
        // qu'une page à recharger, même si on l'a visitée cent fois.
        let openURLs = Set(spaces.flatMap(\.allTabs).compactMap(\.url?.absoluteString))
        for entry in history.search(trimmed) where !openURLs.contains(entry.url.absoluteString) {
            results.append(.history(url: entry.url, title: entry.title,
                                    icon: favicons.icon(for: entry.url)))
        }
        if let url = Self.directURL(trimmed) { results.append(.url(url)) }
        results.append(.search(trimmed))
        return results
    }

    func omnibox(_ omnibox: Omnibox, didActivate result: OmniboxResult) {
        switch result {
        case .tab(let spaceIndex, let tabID, _, _, _):
            currentSpaceIndex = spaceIndex
            if let tab = currentSpace.tab(with: tabID) { currentSpace.current = tab }
            activateCurrentTab()
        case .history(let url, _, _):
            go(to: url)
        case .url(let url):
            go(to: url)
        case .search(let query):
            if let url = settings.searchEngine.url(for: query) { go(to: url) }
        }
    }

    func omniboxDidDismiss(_ omnibox: Omnibox) {}

    /// Une adresse ou une recherche — la seule ambiguïté que l'omnibox doit lever.
    static func directURL(_ input: String) -> URL? {
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
        let folderItem = NSMenuItem(title: "Nouveau dossier",
                                    action: #selector(newFolder(_:)), keyEquivalent: "n")
        folderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(folderItem)
        fileMenu.addItem(withTitle: "Fermer l'onglet", action: #selector(closeTab(_:)), keyEquivalent: "w")
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
        viewMenu.addItem(withTitle: "Historique", action: #selector(showHistory(_:)), keyEquivalent: "y")
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
