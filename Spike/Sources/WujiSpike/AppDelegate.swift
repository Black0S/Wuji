import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ChromeOverlayDelegate, OmniboxDelegate {

    private var window: SpikeWindow!
    private var content: BrowserContent!
    private var chrome: ChromeOverlay!
    private var omnibox: Omnibox!
    private var reveal: RevealController!

    private var root: NSView!
    private var tabs: [Tab] = []
    private var currentIndex = 0
    private var observations: [NSKeyValueObservation] = []

    /// Le mode par défaut. Recommandation de la spec : horizontal — deux ruptures
    /// d'habitude en même temps (interface qui disparaît **et** onglets verticaux),
    /// c'est une de trop.
    private var mode: TabsMode = .horizontal
    private var tabsView: TabsView?

    /// Prévisualisation manuelle du liseré (⌥1/⌥2/⌥3), pour juger le vocabulaire
    /// visuel de la sécurité avant que les vrais signaux existent.
    private var borderPreview: SecurityBorderView.State?

    private let overscroll = OverscrollGesture()
    private let threeFinger = ThreeFingerGesture()

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

        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]
        // Sans ça, aucune touche indirecte du trackpad n'est livrée à l'app (candidat B).
        root.allowedTouchTypes = [.indirect]

        content = BrowserContent(frame: root.bounds)
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)

        chrome = ChromeOverlay(frame: root.bounds)
        chrome.autoresizingMask = [.width, .height]
        chrome.delegate = self
        root.addSubview(chrome)

        omnibox = Omnibox(frame: root.bounds)
        omnibox.autoresizingMask = [.width, .height]
        omnibox.delegate = self
        root.addSubview(omnibox)

        self.root = root
        window.contentView = root
        reveal = RevealController(window: window)
        overscroll.delegate = reveal
        threeFinger.delegate = reveal
        reveal.shouldStayRevealed = { [weak self] in self?.omnibox.isOpen ?? false }
        mount(mode: mode)

        newTab(url: URL(string: "https://www.apple.com")!)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        content.attach(tab.webView)
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
        content.border.set(state)
        content.setProgress(tab.webView.estimatedProgress, isLoading: tab.webView.isLoading)
        chrome.show(url: tab.url,
                    security: state,
                    canGoBack: tab.webView.canGoBack,
                    canGoForward: tab.webView.canGoForward)
        window.title = tab.title
        syncTabsView()
    }

    // MARK: - Navigation

    @objc func focusOmnibox(_ sender: Any?) { openOmnibox() }
    @objc func reload(_ sender: Any?) { currentTab?.webView.reload() }
    @objc func goBack(_ sender: Any?) { currentTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { currentTab?.webView.goForward() }

    private func openOmnibox() {
        reveal.reveal(from: .keyboard)
        omnibox.present(in: window, seed: currentTab?.url?.absoluteString ?? "")
    }

    // MARK: - ChromeOverlayDelegate

    func chromeOverlayDidRequestOmnibox(_ overlay: ChromeOverlay) {
        openOmnibox()
    }

    func chromeOverlay(_ overlay: ChromeOverlay, didTrigger action: ChromeOverlay.Action) {
        switch action {
        case .back:    currentTab?.webView.goBack()
        case .forward: currentTab?.webView.goForward()
        case .reload:  currentTab?.webView.reload()
        }
    }

    // MARK: - OmniboxDelegate

    /// **Les onglets ouverts passent avant tout le reste.** C'est là que se joue la thèse
    /// du spike : sans barre d'onglets, c'est cette liste qui doit rendre le changement
    /// d'onglet aussi rapide qu'un clic — sinon le concept ne tient pas.
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
            if let url = Self.searchURL(query) {
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

    static func searchURL(_ query: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    // MARK: - Modes d'onglets

    /// Changer de mode **démonte** le précédent : la vue est retirée et libérée, pas
    /// masquée. C'est le principe 4 à l'échelle du spike — et l'ancêtre du
    /// `activate()`/`deactivate()` de J1.
    private func mount(mode newMode: TabsMode) {
        tabsView?.removeFromSuperview()
        tabsView = nil
        mode = newMode

        if let view = TabsFactory.make(newMode) {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            view.onSelect = { [weak self] index in
                guard let self, self.tabs.indices.contains(index) else { return }
                self.currentIndex = index
                self.activateCurrentTab()
            }
            view.onClose = { [weak self] index in
                guard let self, self.tabs.indices.contains(index) else { return }
                self.currentIndex = index
                self.closeTab(nil)
            }
            view.onNew = { [weak self] in self?.newTab(nil) }
            // Sous l'omnibox : la palette passe toujours par-dessus.
            root.addSubview(view, positioned: .below, relativeTo: omnibox)
            tabsView = view
        }

        reveal.chromeViews = [chrome, tabsView].compactMap { $0 }
        syncTabsView()
        print("[spike] mode d'onglets : \(newMode.rawValue)")
    }

    private func syncTabsView() {
        let snapshots = tabs.map {
            TabSnapshot(title: $0.title, host: $0.url?.host() ?? "", isLoading: $0.webView.isLoading)
        }
        tabsView?.update(tabs: snapshots, selected: currentIndex)
    }

    @objc func useHorizontal(_ sender: Any?) { mount(mode: .horizontal) }
    @objc func useVertical(_ sender: Any?) { mount(mode: .vertical) }
    @objc func useHidden(_ sender: Any?) { mount(mode: .hidden) }

    // MARK: - Candidats de révélation

    /// Isoler un candidat est le seul moyen de le juger : tant que les trois sont actifs,
    /// on ne sait pas lequel a réellement servi.
    @objc func toggleEdge(_ sender: NSMenuItem) {
        reveal.isEdgeEnabled.toggle()
        sender.state = reveal.isEdgeEnabled ? .on : .off
        print("[spike] \(RevealSource.edge.rawValue) : \(reveal.isEdgeEnabled ? "actif" : "inactif")")
    }

    @objc func toggleOverscroll(_ sender: NSMenuItem) {
        overscroll.isEnabled.toggle()
        sender.state = overscroll.isEnabled ? .on : .off
        print("[spike] \(RevealSource.overscroll.rawValue) : \(overscroll.isEnabled ? "actif" : "inactif")")
    }

    @objc func toggleThreeFinger(_ sender: NSMenuItem) {
        threeFinger.isEnabled.toggle()
        sender.state = threeFinger.isEnabled ? .on : .off
        print("[spike] \(RevealSource.threeFinger.rawValue) : \(threeFinger.isEnabled ? "actif" : "inactif")")
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

        let modeItem = NSMenuItem()
        let modeMenu = NSMenu(title: "Onglets")
        let modes: [(String, Selector, String)] = [
            ("Horizontal", #selector(useHorizontal(_:)), "1"),
            ("Vertical", #selector(useVertical(_:)), "2"),
            ("Masqué — omnibox seule", #selector(useHidden(_:)), "3")
        ]
        for (title, action, key) in modes {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            // Raccourci de banc d'essai uniquement : dans le produit, le mode se choisit
            // dans les Réglages, une fois (spec §2.2). Ici, comparer est tout l'objet.
            item.keyEquivalentModifierMask = [.command, .option]
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        main.addItem(modeItem)

        let gestureItem = NSMenuItem()
        let gestureMenu = NSMenu(title: "Révélation")
        let candidates: [(String, Selector, String)] = [
            ("Bord haut (C)", #selector(toggleEdge(_:)), "1"),
            ("Overscroll (A)", #selector(toggleOverscroll(_:)), "2"),
            ("Trois doigts (B)", #selector(toggleThreeFinger(_:)), "3")
        ]
        for (title, action, key) in candidates {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control]
            item.state = .on
            gestureMenu.addItem(item)
        }
        gestureMenu.addItem(.separator())
        let summaryItem = NSMenuItem(title: "Compteurs par source",
                                     action: #selector(printSummary(_:)), keyEquivalent: "s")
        summaryItem.keyEquivalentModifierMask = [.control]
        gestureMenu.addItem(summaryItem)
        gestureItem.submenu = gestureMenu
        main.addItem(gestureItem)

        NSApp.mainMenu = main
    }
}
