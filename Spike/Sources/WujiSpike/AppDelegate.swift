import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ChromeOverlayDelegate {

    private var window: SpikeWindow!
    private var content: BrowserContent!
    private var chrome: ChromeOverlay!
    private var reveal: RevealController!

    private var tabs: [Tab] = []
    private var currentIndex = 0
    private var observations: [NSKeyValueObservation] = []

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

        window.contentView = root
        reveal = RevealController(window: window, chrome: chrome)
        overscroll.delegate = reveal
        threeFinger.delegate = reveal

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
        chrome.focusOmnibox()
        reveal.reveal(from: .keyboard)
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
            chrome.focusOmnibox()
            reveal.reveal(from: .keyboard)
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
        observations = [
            tab.webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncChrome() }
            },
            tab.webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncChrome() }
            }
        ]
        syncChrome()
    }

    private func syncChrome() {
        guard let tab = currentTab else { return }
        let state = borderPreview ?? tab.security
        content.border.set(state)
        chrome.show(url: tab.url, security: state)
        window.title = tab.title
    }

    // MARK: - Navigation

    @objc func focusOmnibox(_ sender: Any?) {
        reveal.reveal(from: .keyboard)
        chrome.focusOmnibox()
    }

    @objc func reload(_ sender: Any?) { currentTab?.webView.reload() }
    @objc func goBack(_ sender: Any?) { currentTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { currentTab?.webView.goForward() }

    func chromeOverlay(_ overlay: ChromeOverlay, didSubmit text: String) {
        guard let url = Self.resolve(text) else { return }
        currentTab?.webView.load(URLRequest(url: url))
        reveal.hideNow()
    }

    /// Une adresse ou une recherche — la seule ambiguïté que l'omnibox doit lever.
    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(" ") == false, trimmed.contains(".") {
            let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: candidate), url.host != nil { return url }
        }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

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
