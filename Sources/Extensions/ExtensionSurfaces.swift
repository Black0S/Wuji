import AppKit
import WebKit

/// Ce qu'une extension voit de Wuji.
///
/// `browser.tabs` et `browser.windows` ne sont pas des objets de WebKit : ce sont **nos**
/// onglets et **notre** fenêtre, vus à travers deux protocoles. Tout y est facultatif, et
/// ce fichier ne répond qu'à ce que Wuji sait vraiment — un onglet n'est ni épinglé, ni en
/// mode lecture, et prétendre le contraire ferait échouer l'appel suivant.
///
/// Le détour par `NSApp.delegate` est assumé : ces méthodes sont appelées par WebKit sur
/// un onglet isolé, sans rien pour remonter à l'application. Un lien direct depuis chaque
/// onglet aurait créé un cycle de références sur l'objet le plus souvent créé et détruit
/// du programme.
@MainActor
private var browser: AppDelegate? { NSApp.delegate as? AppDelegate }

extension Tab: WKWebExtensionTab {

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func url(for context: WKWebExtensionContext) -> URL? { url }

    func title(for context: WKWebExtensionContext) -> String? { title }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser?.window
    }

    /// Le rang de l'onglet dans la fenêtre, dossiers aplatis : c'est l'ordre affiché, le
    /// seul dont une extension puisse parler avec l'utilisateur.
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.currentSpace.allTabs.firstIndex { $0 === self } ?? 0
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        browser?.currentTab === self
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingMedia }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }

    func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }

    func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        webView.pageZoom = zoomFactor
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        webView.load(URLRequest(url: url))
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        _ = fromOrigin ? webView.reloadFromOrigin() : webView.reload()
    }

    func goBack(for context: WKWebExtensionContext) async throws { webView.goBack() }

    func goForward(for context: WKWebExtensionContext) async throws { webView.goForward() }

    func activate(for context: WKWebExtensionContext) async throws {
        browser?.select(tabID: id)
    }

    func close(for context: WKWebExtensionContext) async throws {
        browser?.close(tabID: id)
    }

    /// **Un clic dans la page vaut accord pour `activeTab`.**
    ///
    /// C'est la contrepartie du modèle : une extension qui n'a demandé aucun hôte peut
    /// quand même agir sur la page où l'on vient d'invoquer son bouton. Le refuser
    /// casserait la plupart des extensions sans rien protéger — sans geste de
    /// l'utilisateur, elle n'obtient toujours rien.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

extension BrowserWindow: WKWebExtensionWindow {

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        browser?.currentSpace.allTabs ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser?.currentTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        if isMiniaturized { return .minimized }
        if styleMask.contains(.fullScreen) { return .fullscreen }
        return isZoomed ? .maximized : .normal
    }

    /// **Un espace privé n'est pas une fenêtre privée, et on le dit tel quel.**
    ///
    /// Le privé de Wuji tient à l'espace, pas à la fenêtre : les deux peuvent coexister
    /// dans celle-ci. On répond donc pour l'espace ouvert — c'est celui dont les onglets
    /// sont visibles, donc celui dont l'extension parle.
    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        browser?.isPrivateSpace ?? false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { frame }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext) async throws {
        makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
