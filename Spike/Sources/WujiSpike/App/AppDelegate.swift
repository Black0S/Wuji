import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ContentTopBarDelegate, OmniboxDelegate {

    private var window: SpikeWindow!
    private var layout: BrowserLayout!
    private var reveal: RevealController!

    private let overscroll = OverscrollGesture()
    private let threeFinger = ThreeFingerGesture()
    private let favicons = FaviconStore()
    private let settings = Settings()
    private var settingsWindow: SettingsWindow?

    private var tabs: [Tab] = []
    private var currentIndex = 0
    private var observations: [NSKeyValueObservation] = []

    /// Prévisualisation manuelle du liseré (⌥1/⌥2/⌥3), pour juger le vocabulaire
    /// visuel de la sécurité avant que les vrais signaux existent.
    private var borderPreview: SecurityBorderView.State?

    private lazy var configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Candidat A : le seul endroit d'où l'on voit à la fois la position de défilement
        // et l'intention de la molette est la page elle-même.
        config.userContentController.addUserScript(OverscrollGesture.userScript)
        config.userContentController.add(overscroll, name: OverscrollGesture.handlerName)
        return config
    }()

    private var currentTab: Tab? { tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil }

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        window = SpikeWindow()
        layout = BrowserLayout(frame: window.contentLayoutRect)
        layout.autoresizingMask = [.width, .height]
        layout.topBar.delegate = self
        layout.omnibox.delegate = self

        layout.sidebar.onSelect = { [weak self] index in
            guard let self, self.tabs.indices.contains(index) else { return }
            self.currentIndex = index
            self.activateCurrentTab()
        }
        layout.sidebar.onClose = { [weak self] index in
            guard let self, self.tabs.indices.contains(index) else { return }
            self.currentIndex = index
            self.closeTab(nil)
        }
        layout.sidebar.onNew = { [weak self] in self?.newTab(nil) }

        favicons.onUpdate = { [weak self] in self?.syncSidebar() }

        window.contentView = layout
        reveal = RevealController(window: window)
        reveal.applyChrome = { [weak self] visible, animated in
            self?.layout.setChrome(visible: visible, animated: animated)
        }
        overscroll.delegate = reveal
        threeFinger.delegate = reveal
        reveal.shouldStayRevealed = { [weak self] in self?.layout.omnibox.isOpen ?? false }

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

        reveal.isAlwaysVisible = settings.alwaysVisibleUI
        reveal.isEdgeEnabled = settings.edgeEnabled
        reveal.revealZone = settings.revealZone
        reveal.keepZone = settings.keepZone
        reveal.hideDelay = settings.hideDelay

        overscroll.isEnabled = settings.overscrollEnabled
        threeFinger.isEnabled = settings.threeFingerEnabled

        for tab in tabs {
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

    func applicationWillTerminate(_ notification: Notification) {
        // Journal de frictions, semaine 3 : c'est ce tableau qui tranche le geste,
        // pas une opinion en fin de semaine.
        print(reveal.summary())
        print("[spike] onglets ouverts en fin de session : \(tabs.count)")
    }

    // MARK: - Onglets

    @objc func newTab(_ sender: Any?) {
        newTab(url: nil)
        openOmnibox()
    }

    private func newTab(url: URL?) {
        let tab = Tab(configuration: configuration)
        tabs.append(tab)
        currentIndex = tabs.count - 1
        activateCurrentTab()
        if let url { tab.webView.load(URLRequest(url: url)) }
    }

    @objc func closeTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        tabs.remove(at: currentIndex)
        if tabs.isEmpty {
            newTab(url: nil)
            openOmnibox()
        } else {
            currentIndex = min(currentIndex, tabs.count - 1)
            activateCurrentTab()
        }
    }

    @objc func nextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        currentIndex = (currentIndex + 1) % tabs.count
        activateCurrentTab()
    }

    @objc func previousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        currentIndex = (currentIndex - 1 + tabs.count) % tabs.count
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
        let state = borderPreview ?? tab.security
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
        let snapshots = tabs.map {
            TabSnapshot(title: $0.title,
                        host: $0.url?.host() ?? "",
                        isLoading: $0.webView.isLoading,
                        favicon: favicons.icon(for: $0.url))
        }
        layout.sidebar.update(tabs: snapshots, selected: currentIndex)
    }

    // MARK: - Navigation

    @objc func focusOmnibox(_ sender: Any?) { openOmnibox() }
    @objc func reload(_ sender: Any?) { currentTab?.webView.reload() }
    @objc func goBack(_ sender: Any?) { currentTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { currentTab?.webView.goForward() }

    private func openOmnibox() {
        reveal.reveal(from: .keyboard)
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
        case .newTab:  newTab(nil)
        }
    }

    // MARK: - OmniboxDelegate

    /// Les onglets ouverts passent avant tout le reste : même avec une sidebar, chercher
    /// un onglet au clavier doit rester plus rapide que le viser à la souris.
    func omnibox(_ omnibox: Omnibox, resultsFor query: String) -> [OmniboxResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let matchingTabs = tabs.enumerated().compactMap { index, tab -> OmniboxResult? in
            guard index != currentIndex else { return nil }
            let haystack = "\(tab.title) \(tab.url?.absoluteString ?? "")".lowercased()
            guard trimmed.isEmpty || haystack.contains(trimmed.lowercased()) else { return nil }
            return .tab(index: index, title: tab.title, subtitle: tab.url?.host() ?? "onglet")
        }

        guard !trimmed.isEmpty else { return matchingTabs }

        var results = matchingTabs
        if let url = Self.directURL(trimmed) { results.append(.url(url)) }
        results.append(.search(trimmed))
        return results
    }

    func omnibox(_ omnibox: Omnibox, didActivate result: OmniboxResult) {
        switch result {
        case .tab(let index, _, _):
            currentIndex = index
            activateCurrentTab()
        case .url(let url):
            currentTab?.webView.load(URLRequest(url: url))
        case .search(let query):
            if let url = settings.searchEngine.url(for: query) {
                currentTab?.webView.load(URLRequest(url: url))
            }
        }
        reveal.hideNow()
    }

    func omniboxDidDismiss(_ omnibox: Omnibox) {
        reveal.hideNow()
    }

    /// Une adresse ou une recherche — la seule ambiguïté que l'omnibox doit lever.
    static func directURL(_ input: String) -> URL? {
        guard !input.contains(" "), input.contains(".") else { return nil }
        let candidate = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }

    @objc func printSummary(_ sender: Any?) {
        print(reveal.summary())
    }

    // MARK: - Prévisualisation du liseré

    @objc func previewInsecure(_ sender: Any?) { setPreview(.insecure) }
    @objc func previewPermission(_ sender: Any?) { setPreview(.permission) }
    @objc func previewPrivate(_ sender: Any?) { setPreview(.privateSession) }
    @objc func previewOff(_ sender: Any?) { setPreview(nil) }

    private func setPreview(_ state: SecurityBorderView.State?) {
        borderPreview = state
        syncChrome()
        print("[spike] liseré : \(state?.label ?? "réel")")
    }

    // MARK: - Menus

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Réglages…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Wuji Spike", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Wuji Spike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        viewMenu.addItem(withTitle: "Onglet suivant", action: #selector(nextTab(_:)), keyEquivalent: "]")
        viewMenu.addItem(withTitle: "Onglet précédent", action: #selector(previousTab(_:)), keyEquivalent: "[")
        viewMenu.addItem(.separator())

        let previews: [(String, Selector, String)] = [
            ("Liseré — réel", #selector(previewOff(_:)), "0"),
            ("Liseré — non chiffré", #selector(previewInsecure(_:)), "1"),
            ("Liseré — permission active", #selector(previewPermission(_:)), "2"),
            ("Liseré — session privée", #selector(previewPrivate(_:)), "3")
        ]
        for (title, action, key) in previews {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.option]
            viewMenu.addItem(item)
        }
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Les candidats de révélation ont quitté le menu pour les Réglages › Avancé :
        // ils s'y règlent avec leurs seuils, au même endroit, plutôt qu'en deux moitiés.
        let summaryItem = NSMenuItem(title: "Compteurs de révélation",
                                     action: #selector(printSummary(_:)), keyEquivalent: "s")
        summaryItem.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(.separator())
        viewMenu.addItem(summaryItem)

        NSApp.mainMenu = main
    }
}
