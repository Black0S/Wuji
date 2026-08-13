import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ContentTopBarDelegate, OmniboxDelegate, FindBarDelegate, SpacesPanelDelegate {

    private var window: BrowserWindow!
    private var layout: BrowserLayout!

    private let favicons = FaviconStore()
    private let settings = Settings()
    private var settingsWindow: SettingsWindow?

    /// Les onglets appartiennent à un espace, jamais à l'application. Tout ce qui suit
    /// passe donc par `currentSpace` — c'est ce qui évite d'avoir deux notions
    /// d'« onglet courant » qui se désynchronisent.
    private var spaces: [Space] = [Space(name: "Personnel", symbol: Space.symbol(forIndex: 0))]
    private var currentSpaceIndex = 0
    private var observations: [NSKeyValueObservation] = []

    /// Position et total de la recherche dans la page, tenus à la main — voir `countMatches`.
    private var findPosition = 1
    private var findTotal: Int?

    private lazy var configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return config
    }()

    private var currentSpace: Space { spaces[currentSpaceIndex] }
    private var currentTab: Tab? { currentSpace.currentTab }

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

        layout.sidebar.onSelect = { [weak self] index in
            guard let self, self.currentSpace.tabs.indices.contains(index) else { return }
            self.currentSpace.currentIndex = index
            self.activateCurrentTab()
        }
        layout.sidebar.onClose = { [weak self] index in
            guard let self, self.currentSpace.tabs.indices.contains(index) else { return }
            self.currentSpace.currentIndex = index
            self.closeTab(nil)
        }
        layout.sidebar.onNew = { [weak self] in self?.newTab(nil) }
        layout.sidebar.onSpaceClick = { [weak self] anchor in self?.showSpacesPanel(from: anchor) }

        favicons.onUpdate = { [weak self] in self?.syncSidebar() }

        window.contentView = layout

        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()

        newTab(url: URL(string: settings.homepage))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Un seul endroit où les réglages descendent dans l'application. Sans ça, chaque
    /// réglage finirait branché depuis sa propre rangée d'interface, et on ne saurait
    /// plus qui pilote quoi.
    private func applySettings() {
        NSApp.appearance = settings.theme.appearance

        for tab in spaces.flatMap(\.tabs) {
            tab.webView.pageZoom = settings.pageZoom
            tab.webView.isInspectable = settings.safariInspection
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(settings: settings)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }


    // MARK: - Onglets

    @objc func newTab(_ sender: Any?) {
        newTab(url: nil)
        openOmnibox()
    }

    private func newTab(url: URL?) {
        let tab = Tab(configuration: configuration)
        currentSpace.tabs.append(tab)
        currentSpace.currentIndex = currentSpace.tabs.count - 1
        activateCurrentTab()
        if let url { tab.webView.load(URLRequest(url: url)) }
    }

    @objc func closeTab(_ sender: Any?) {
        let space = currentSpace
        guard !space.tabs.isEmpty else { return }
        space.tabs.remove(at: space.currentIndex)
        if space.tabs.isEmpty {
            newTab(url: nil)
            openOmnibox()
        } else {
            space.currentIndex = min(space.currentIndex, space.tabs.count - 1)
            activateCurrentTab()
        }
    }

    @objc func nextTab(_ sender: Any?) {
        let space = currentSpace
        guard space.tabs.count > 1 else { return }
        space.currentIndex = (space.currentIndex + 1) % space.tabs.count
        activateCurrentTab()
    }

    @objc func previousTab(_ sender: Any?) {
        let space = currentSpace
        guard space.tabs.count > 1 else { return }
        space.currentIndex = (space.currentIndex - 1 + space.tabs.count) % space.tabs.count
        activateCurrentTab()
    }

    private func activateCurrentTab() {
        guard let tab = currentTab else { return }
        layout.content.attach(tab.webView)

        let sync: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncChrome() }
        }
        observations = [
            tab.webView.observe(\.url, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.title, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.canGoBack, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.canGoForward, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.isLoading, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.estimatedProgress, options: [.initial, .new], changeHandler: sync)
        ]
        syncChrome()
    }

    private func syncChrome() {
        guard let tab = currentTab else { return }
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

    private func syncSidebar() {
        let space = currentSpace
        layout.sidebar.update(space: SpaceSnapshot(name: space.name,
                                                   symbol: space.symbol,
                                                   color: space.tint.color))
        let snapshots = space.tabs.map {
            TabSnapshot(title: $0.title,
                        host: $0.url?.host() ?? "",
                        isLoading: $0.webView.isLoading,
                        favicon: favicons.icon(for: $0.url))
        }
        layout.sidebar.update(tabs: snapshots, selected: space.currentIndex)
    }

    // MARK: - Navigation

    @objc func focusOmnibox(_ sender: Any?) { openOmnibox() }
    @objc func reload(_ sender: Any?) { currentTab?.webView.reload() }
    @objc func goBack(_ sender: Any?) { currentTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { currentTab?.webView.goForward() }

    private func openOmnibox() {
        layout.omnibox.present(in: window, seed: currentTab?.url?.absoluteString ?? "")
    }

    // MARK: - ContentTopBarDelegate

    func topBarDidRequestOmnibox(_ bar: ContentTopBar) {
        openOmnibox()
    }

    func topBar(_ bar: ContentTopBar, didTrigger action: ContentTopBar.Action) {
        switch action {
        case .back:    currentTab?.webView.goBack()
        case .forward: currentTab?.webView.goForward()
        }
    }

    // MARK: - Espaces

    private var spaceSnapshots: [SpaceRowSnapshot] {
        spaces.map {
            SpaceRowSnapshot(name: $0.name, symbol: $0.symbol,
                             color: $0.tint.color, tabCount: $0.tabs.count)
        }
    }

    private func showSpacesPanel(from anchor: NSView) {
        layout.spacesPanel.present(spaces: spaceSnapshots,
                                   current: currentSpaceIndex,
                                   tint: currentSpace.tint,
                                   anchor: anchor)
    }

    func spacesPanel(_ panel: SpacesPanel, didSelect index: Int) {
        guard spaces.indices.contains(index), index != currentSpaceIndex else { return }
        currentSpaceIndex = index
        // Un espace vide n'existe pas : on y entre toujours sur un onglet.
        if currentSpace.tabs.isEmpty {
            newTab(url: URL(string: settings.homepage))
        } else {
            activateCurrentTab()
        }
    }

    func spacesPanel(_ panel: SpacesPanel, didPick tint: Space.Tint) {
        currentSpace.tint = tint
        syncSidebar()
        panel.reload(spaces: spaceSnapshots, current: currentSpaceIndex, tint: tint)
    }

    func spacesPanelDidRequestNew(_ panel: SpacesPanel) {
        let index = spaces.count
        spaces.append(Space(name: "Espace \(index + 1)", symbol: Space.symbol(forIndex: index)))
        currentSpaceIndex = index
        newTab(url: URL(string: settings.homepage))
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
            for (tabIndex, tab) in space.tabs.enumerated() {
                guard !(spaceIndex == currentSpaceIndex && tabIndex == space.currentIndex) else { continue }
                let haystack = "\(tab.title) \(tab.url?.absoluteString ?? "")".lowercased()
                guard trimmed.isEmpty || haystack.contains(trimmed.lowercased()) else { continue }
                // L'espace n'est rappelé que s'il n'est pas celui où l'on se trouve :
                // le préciser à chaque ligne serait du bruit dans le cas courant.
                let host = tab.url?.host() ?? "onglet"
                let subtitle = spaceIndex == currentSpaceIndex ? host : "\(space.name) · \(host)"
                matchingTabs.append(.tab(space: spaceIndex,
                                         tab: tabIndex,
                                         title: tab.title,
                                         subtitle: subtitle,
                                         icon: favicons.icon(for: tab.url)))
            }
        }

        guard !trimmed.isEmpty else { return matchingTabs }

        var results = matchingTabs
        if let url = Self.directURL(trimmed) { results.append(.url(url)) }
        results.append(.search(trimmed))
        return results
    }

    func omnibox(_ omnibox: Omnibox, didActivate result: OmniboxResult) {
        switch result {
        case .tab(let spaceIndex, let tabIndex, _, _, _):
            currentSpaceIndex = spaceIndex
            currentSpace.currentIndex = tabIndex
            activateCurrentTab()
        case .url(let url):
            currentTab?.webView.load(URLRequest(url: url))
        case .search(let query):
            if let url = settings.searchEngine.url(for: query) {
                currentTab?.webView.load(URLRequest(url: url))
            }
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
