import AppKit
import WebKit

/// La navigation, telle que WebKit la rapporte.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

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
    func present(_ error: any Error, in webView: WKWebView) {
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
            blockLog.record(.blocked, host: url.host() ?? "", detail: url.absoluteString,
                            url: url.absoluteString, resource: .frame,
                            match: blocker.matcher.match(url, on: url.host()))
        }

        // **Aucun onglet ne se ferme tout seul. Jamais.**
        //
        // Une fenêtre ouverte par un script et dont l'adresse échouait se refermait
        // d'elle-même. L'intention était bonne — personne n'avait demandé cette fenêtre —
        // mais le drapeau qui la désignait restait posé pour toute la vie de l'onglet :
        // n'importe quel échec ultérieur, un réveil de veille compris, le faisait
        // disparaître de la colonne. Des onglets s'évanouissaient sans raison visible.
        //
        // La règle est donc absolue, et c'est celle du propriétaire du produit : un onglet
        // ne part que si on le ferme. Une page qui échoue montre son échec, y compris dans
        // une fenêtre qu'on n'avait pas demandée — on la ferme d'un ⌘W, ce qui est un
        // geste, pas une surprise.
        webView.loadSimulatedRequest(URLRequest(url: url),
                                     responseHTML: ErrorPage.html(url: url, error: error))
    }

    /// Une page vue est une page arrivée. Enregistrer au départ de la navigation
    /// compterait les redirections et les erreurs comme des visites.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // **Une page arrivée avant les règles n'est pas protégée, et rien ne le disait.**
        //
        // WebKit applique une liste au moment de la requête : la poser après coup ne
        // change rien à la page déjà là. Au lancement, la compilation prend un instant, et
        // la première page part souvent avant. On le note pour le dire — pas pour la
        // recharger d'office, ce qui ferait clignoter ce qu'on est en train de lire.
        if !blocker.isReady { loadedBeforeRules = true }

        // L'onglet retient où il en est. Sans ce rappel, sa mémoire resterait celle de la
        // session restaurée et vieillirait à chaque navigation.
        if let tab = spaces.flatMap(\.allTabs).first(where: { $0.webView === webView }),
           let arrivée = webView.url {
            tab.remember(url: arrivée)
        }

        // Le zoom suit le site, donc il se réévalue à l'arrivée : d'un onglet qui va de
        // `a.com` à `b.com`, on attend la taille de `b.com`.
        webView.pageZoom = zoom(for: webView.url)

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

    func register(_ download: WKDownload, source: URL?) {
        download.delegate = self
        let item = DownloadItem(download: download,
                                source: source ?? URL(string: "about:blank")!,
                                filename: source?.lastPathComponent ?? "fichier")
        downloads.add(item)
        attach(download, to: item)
    }

    // MARK: - Navigation

    @objc func focusOmnibox(_ sender: Any?) { openOmnibox() }
    @objc func reload(_ sender: Any?) { currentTab?.webView.reload() }
    /// Le zoom s'applique **au site qu'on regarde**, et se retient pour lui.
    ///
    /// Un site dont le texte est trop petit ne doit pas obliger à grossir tout le web, ni
    /// à refaire le réglage à chaque visite. Le réglage général reste la valeur de départ ;
    /// seuls les écarts sont conservés, ce qui évite d'enregistrer une ligne pour chaque
    /// site visité.
    ///
    /// `⌘0` efface l'écart plutôt que de poser 100 % : revenir au défaut et *imposer* cent
    /// pour cent sont deux gestes différents, et c'est le premier qu'on attend d'une remise
    /// à zéro.
    @objc func zoomIn(_ sender: Any?)  { setZoom(zoomForCurrentSite + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoomForCurrentSite - 0.1) }

    @objc func zoomReset(_ sender: Any?) {
        guard let site = Site.name(of: currentTab?.url) else { return }
        settings.siteZoom.removeValue(forKey: site)
        applySettings()
        layout.toast.show("Zoom par défaut sur \(site)")
    }

    /// Le zoom en vigueur ici : celui du site s'il en a un, le réglage général sinon.
    var zoomForCurrentSite: CGFloat {
        guard let site = Site.name(of: currentTab?.url),
              let zoom = settings.siteZoom[site] else { return settings.pageZoom }
        return CGFloat(zoom)
    }

    func setZoom(_ value: CGFloat) {
        let clamped = min(max(0.5, (value * 10).rounded() / 10), 2)
        guard let site = Site.name(of: currentTab?.url) else {
            // Sur une page interne il n'y a pas de site à retenir : le geste vaut alors
            // pour le réglage général, comme avant.
            guard clamped != settings.pageZoom else { return }
            settings.pageZoom = clamped
            layout.toast.show("Zoom \(Int(clamped * 100)) %")
            return
        }
        guard clamped != zoomForCurrentSite else { return }
        if clamped == settings.pageZoom {
            settings.siteZoom.removeValue(forKey: site)
        } else {
            settings.siteZoom[site] = Double(clamped)
        }
        applySettings()
        layout.toast.show("Zoom \(Int(clamped * 100)) % sur \(site)")
    }

    @objc func goBack(_ sender: Any?) { currentTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { currentTab?.webView.goForward() }

    /// `creatingTab` : la destination choisie ouvrira un onglet au lieu de remplacer la
    /// page courante.
    func openOmnibox(creatingTab: Bool = false) {
        omniboxCreatesTab = creatingTab
        layout.omnibox.present(in: window,
                               seed: creatingTab ? "" : (currentTab?.url?.absoluteString ?? ""))
    }

    /// Ouvre l'adresse là où il faut : dans un nouvel onglet si la palette a été appelée
    /// pour ça, dans la page courante sinon — et dans un onglet neuf s'il n'y en a aucun.
    func go(to url: URL) {
        guard !omniboxCreatesTab, let tab = currentTab else {
            newTab(url: url)
            return
        }
        tab.webView.load(URLRequest(url: url))
    }
}
