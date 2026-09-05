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

        // **La page a demandé un téléchargement, pas une navigation.**
        //
        // C'est ce que dit `shouldPerformDownload` : un lien porteur de l'attribut
        // `download`, ou un `blob:`/`data:` qu'un script fait cliquer pour livrer un
        // fichier. Sans ce test, l'attribut était purement décoratif — le fichier
        // s'affichait dans l'onglet quand son type était affichable, et le nom demandé par
        // la page était perdu. Mesuré sur les cinq formes du banc d'essai : aucune ne
        // téléchargeait.
        if navigationAction.shouldPerformDownload { return .download }

        // Une adresse en `.user.js` est une offre d'installation, pas une page à lire.
        // Le type du document appartient à la page affichée : une nouvelle navigation le
        // périme. Sans cette remise à zéro, une page interne — qui n'a pas de réponse
        // réseau — hériterait du type du PDF qu'on regardait, et garderait son bouton de
        // téléchargement.
        if navigationAction.targetFrame?.isMainFrame ?? false,
           let tab = tab(for: webView) {
            tab.documentMIME = nil
        }

        if let url = navigationAction.request.url, Self.looksLikeUserScript(url),
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
        // **Aucun onglet ne se ferme tout seul. Jamais.**
        //
        // Une fenêtre ouverte par un script et dont l'adresse échouait se refermait
        // d'elle-même. L'intention était bonne — personne n'avait demandé cette fenêtre —
        // mais le drapeau qui la désignait restait posé pour toute la vie de l'onglet :
        // n'importe quel échec ultérieur le faisait disparaître de la colonne. Des
        // onglets s'évanouissaient sans raison visible.
        //
        // La règle est donc absolue, et c'est celle du propriétaire du produit : un onglet
        // ne part que si on le ferme. Une page qui échoue montre son échec, y compris dans
        // une fenêtre qu'on n'avait pas demandée — on la ferme d'un ⌘W, ce qui est un
        // geste, pas une surprise.
        // Le certificat refusé, s'il y en a un pour cet hôte : la page doit montrer ce
        // qu'elle propose d'accepter.
        var certificate: [String] = []
        if ErrorPage.isUntrusted(error), let host = url.host(),
           let trust = rejectedCertificates[host] {
            certificate = Certificate.describe(trust)
            if let print = Certificate.fingerprint(trust) { certificate.append("SHA-256 " + print) }
        }

        webView.loadSimulatedRequest(URLRequest(url: url),
                                     responseHTML: ErrorPage.html(url: url, error: error,
                                                                  certificate: certificate))
    }

    /// Une page vue est une page arrivée. Enregistrer au départ de la navigation
    /// compterait les redirections et les erreurs comme des visites.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        offerScriptInstall(in: webView)

        // Une navigation quitte le mode lecture : le document qu'on avait remplacé n'est
        // plus là, et laisser la marque poserait un « Quitter le mode lecture » sur une page
        // qui n'y est pas.
        if let tab = tab(for: webView) { readingTabs.remove(tab.id) }

        // L'onglet retient où il en est. Sans ce rappel, sa mémoire resterait celle de la
        // session restaurée et vieillirait à chaque navigation.
        if let tab = tab(for: webView),
           let arrivée = webView.url {
            tab.remember(url: arrivée)
        }

        // Le zoom suit le site, donc il se réévalue à l'arrivée : d'un onglet qui va de
        // `a.com` à `b.com`, on attend la taille de `b.com`.
        webView.pageZoom = zoom(for: webView.url)

        // Y a-t-il un article ici ? La question se pose une fois, à l'arrivée, et le bouton
        // du mode lecture s'affiche ou non selon la réponse.
        webView.evaluateJavaScript(Reader.detect) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self, let tab = self.tab(for: webView) else { return }
                let article = found as? Bool == true
                guard tab.hasArticle != article else { return }
                tab.hasArticle = article
                self.syncChrome()
            }
        }

        guard let url = webView.url else { return }
        // Rien n'est noté depuis un espace privé — c'est tout ce qu'il promet.
        guard !isPrivateSpace else { return }
        history.record(url: url, title: webView.title ?? "")
    }

    /// Une réponse que WebKit ne sait pas afficher est un fichier, pas une page.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Le suffixe convenu court-circuite l'affichage : `.user.js` **est** une offre
        // d'installation, et une redirection peut l'avoir amené jusqu'ici sans passer par
        // le test de l'action.
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url,
           Self.looksLikeUserScript(url) {
            installScript(from: url)
            return .cancel
        }

        // **Le serveur peut dire « ceci se télécharge », et il faut l'écouter.**
        //
        // `canShowMIMEType` ne répond qu'à « saurais-je l'afficher ? ». Un `text/plain`
        // servi avec `Content-Disposition: attachment` sait s'afficher et ne doit pas
        // l'être : c'est une pièce jointe, et le serveur vient de le dire. Mesuré, elle
        // s'ouvrait dans l'onglet — le fichier n'arrivait jamais, et le nom que le serveur
        // proposait était perdu avec lui.
        if Self.isAttachment(navigationResponse.response) { return .download }

        // Le type du document est **retenu ici**, parce qu'il n'est nulle part ailleurs :
        // `WKWebView` ne l'expose pas, et c'est lui qui dit si la page affichée est du
        // texte — donc, peut-être, un script utilisateur.
        if navigationResponse.isForMainFrame,
           let tab = tab(for: webView) {
            tab.documentMIME = navigationResponse.response.mimeType?.lowercased()
        }

        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// La réponse s'annonce-t-elle comme une pièce jointe ?
    ///
    /// La comparaison est faite sur le premier segment et sans tenir compte de la casse :
    /// l'en-tête s'écrit `attachment; filename="…"`, et `Attachment` est aussi valide que
    /// `attachment`. Chercher le mot n'importe où dans l'en-tête ferait prendre un
    /// `inline; filename="attachment.pdf"` pour une pièce jointe.
    static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return false
        }
        let type = header.split(separator: ";").first ?? ""
        return type.trimmingCharacters(in: .whitespaces).lowercased() == "attachment"
    }

    /// Une page qui **est** un script utilisateur propose de l'installer.
    ///
    /// **L'adresse ment souvent.** Un dépôt sert son script sous `/refs/heads/main/x.js`,
    /// un lien raccourci perd le suffixe, une redirection le mange : on tombait alors sur
    /// un mur de JavaScript affiché en texte, et il fallait deviner qu'il y avait quelque
    /// chose à faire. Le suffixe `.user.js`, lui, est une déclaration explicite et
    /// court-circuite l'affichage plus haut.
    ///
    /// **Ce n'est plus la page qu'on interroge.** On lui demandait, en JavaScript, si son
    /// corps ressemblait à un script. Mesuré sur `raw.githubusercontent.com` :
    /// `evaluateJavaScript` **échoue** dans un document texte — WebKit n'y exécute rien, et
    /// l'offre n'arrivait donc jamais sur exactement le genre de page où elle sert. C'est
    /// maintenant le type du document qui décide, retenu à la réponse, et l'en-tête du
    /// fichier qui confirme.
    ///
    /// **Et la page reste affichée.** Un script utilisateur s'exécute avec les pouvoirs des
    /// pages qu'il vise ; le proposer par-dessus son propre code est la seule façon de
    /// pouvoir le lire avant de dire oui.
    func offerScriptInstall(in webView: WKWebView) {
        guard settings.userScriptsEnabled, !layout.toast.isAsking,
              let url = webView.url, url.scheme == "https" || url.scheme == "http",
              !Self.looksLikeUserScript(url),
              let tab = tab(for: webView), Self.isTextDocument(tab.documentMIME),
              url.path.lowercased().hasSuffix(".js") else { return }

        // Le fichier est relu pour de bon : c'est son en-tête qui tranche, pas son nom.
        // `installScript` ne pose la question que s'il en trouve un.
        installScript(from: url, requiringHeader: true)
    }

    /// Le document affiché est-il du texte ou du JavaScript ?
    ///
    /// Une page HTML qui parlerait de scripts n'a pas ce type-là, et ne sera donc jamais
    /// prise pour un script — c'est la moitié de la garde, l'autre étant l'en-tête.
    static func isTextDocument(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return ["text/plain", "text/javascript", "application/javascript",
                "application/x-javascript", "text/x-javascript"].contains(mime)
    }

    /// L'adresse annonce-t-elle un script utilisateur ?
    ///
    /// Le suffixe `.user.js` est la convention de Greasemonkey, respectée par Greasy Fork,
    /// OpenUserJS et les dépôts. Il se lit sur le **chemin** et non sur l'adresse entière :
    /// `…/loop.user.js?version=1420` en est un, et le chercher dans la chaîne complète le
    /// manquerait.
    static func looksLikeUserScript(_ url: URL) -> Bool {
        url.path.hasSuffix(".user.js")
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
    /// **Aucune bulle pour le zoom.** Elle annonçait « Zoom 90 % sur exemple.fr » à chaque
    /// pression, en bas à droite — pendant que la barre du haut affichait déjà le chiffre,
    /// à demeure et à l'endroit où l'on regarde en réglant. Deux surfaces pour un seul
    /// fait, et la bulle était la moins utile des deux : elle s'efface au bout de quelques
    /// secondes, là où le badge reste tant que le zoom n'est pas celui par défaut.
    @objc func zoomIn(_ sender: Any?)  { setZoom(zoomForCurrentSite + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoomForCurrentSite - 0.1) }

    @objc func zoomReset(_ sender: Any?) {
        guard let site = Site.name(of: currentTab?.url) else {
            // Une page interne n'a pas de site à qui retirer un écart. `⌘+` y règle le zoom
            // général : `⌘0` doit donc l'y ramener à cent, sans quoi les deux gestes ne
            // parleraient pas de la même chose au même endroit.
            guard settings.pageZoom != 1 else { return }
            settings.pageZoom = 1
            syncChrome()
            return
        }
        settings.siteZoom.removeValue(forKey: site)
        applySettings()
        // **Le badge doit suivre, et il ne suivait pas.** `applySettings` change les pages,
        // pas le chrome : le chiffre restait affiché — « 60 % » sur une page revenue à sa
        // taille normale. C'est déjà la raison du `syncChrome` de `setZoom` ; il manquait
        // ici, où l'on remet justement les choses en place.
        syncChrome()
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
            syncChrome()
            return
        }
        guard clamped != zoomForCurrentSite else { return }
        if clamped == settings.pageZoom {
            settings.siteZoom.removeValue(forKey: site)
        } else {
            settings.siteZoom[site] = Double(clamped)
        }
        applySettings()
        // Le badge de la barre suit tout de suite : `applySettings` change les pages, pas
        // le chrome, et attendre le prochain signal de WebKit ferait afficher l'ancien
        // chiffre — ou rien du tout sur une page qui a fini de charger.
        syncChrome()
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
