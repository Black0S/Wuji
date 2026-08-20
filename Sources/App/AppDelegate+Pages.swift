import AppKit
import WebKit

/// Les pages internes et leurs actions.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

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
    func favoritableURL(of tab: Tab) -> URL? {
        guard let url = tab.url, !isBlank(tab),
              url.scheme != InternalPageHandler.scheme else { return nil }
        return url
    }

    /// Les pages ouvertes sur la liste doivent refléter ce qui vient de changer ailleurs.
    func refreshFavorites() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url == Self.favoritesPage }
            .forEach { $0.webView.reload() }
    }

    func handleFavoriteAction(_ action: String, id: String?) {
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
    ///
    /// **Écrite en `async`, cette méthode n'existait pas pour WebKit.** Elle compilait sans
    /// une erreur, sans un avertissement, et n'était jamais appelée : le moteur posait sa
    /// propre question à la place, si bien que tout paraissait fonctionner — sauf que la
    /// réponse n'était retenue nulle part et que Réglages › Sites web restait vide. La
    /// complétion doit être annotée `@MainActor` pour satisfaire l'exigence du protocole,
    /// faute de quoi la méthode n'est pas exposée à Objective-C. Voir `DelegateSelectorTests`,
    /// qui demande à la classe ce que WebKit lui demande.
    @objc
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let host = origin.host
        let kind: Permissions.Kind = switch type {
        case .camera: .camera
        case .microphone: .microphone
        default: .both
        }

        // Déjà tranché pour ce site : on ne redemande pas.
        if let known = permissions.decision(host: host, kind: kind) {
            return decisionHandler(known ? .grant : .deny)
        }

        // Une question à la fois dans la bulle : une seconde chasserait la première, et la
        // page qui l'attendait resterait sans réponse.
        guard !layout.toast.isAsking else { return decisionHandler(.deny) }

        layout.toast.ask(
            title: "Autoriser \(kind.label) ?",
            message: "« \(host) » demande l'accès à \(kind.label). Cette réponse sera retenue pour ce site, et modifiable dans les réglages.",
            confirm: "Autoriser", isDestructive: false,
            onCancel: { [weak self] in
                self?.permissions.remember(host: host, kind: kind, isAllowed: false)
                decisionHandler(.deny)
            },
            onConfirm: { [weak self] in
                self?.permissions.remember(host: host, kind: kind, isAllowed: true)
                decisionHandler(.grant)
            })
    }

    /// Le choix d'un fichier à téléverser.
    ///
    /// **Sans cette méthode, `<input type="file">` ne fait rien.** WebKit n'ouvre aucun
    /// sélecteur de lui-même : le clic est reçu, la page attend, et rien n'arrive. Joindre
    /// une pièce à un message, envoyer une photo, importer un document dans une application
    /// web — trois gestes ordinaires qui échouaient sans un mot.
    ///
    /// **Et ici, le panneau du système est le bon.** La règle qui envoie les questions de
    /// Wuji dans la bulle vaut pour les questions que Wuji pose ; celle-ci n'en est pas une.
    /// C'est le navigateur de fichiers de macOS qu'on demande, avec ses favoris, sa
    /// recherche et ses raccourcis — le refaire serait le refaire moins bien.
    ///
    /// Annuler rend `nil` et non une liste vide : la page doit pouvoir distinguer « aucun
    /// fichier choisi » de « choix abandonné ».
    @objc
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Les deux réglages viennent de la page : `multiple` et `webkitdirectory`. Les
        // ignorer laisserait choisir ce que le formulaire ne sait pas recevoir.
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.prompt = "Choisir"

        // En feuille sur la fenêtre plutôt qu'en fenêtre flottante : le choix appartient à
        // la page qu'on regarde, et une fenêtre séparée se perdrait derrière.
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completionHandler(response == .OK ? panel.urls : nil)
            }
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

    func askLocation(host: String, then decide: @escaping (Bool) -> Void) {
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

    /// `target="_blank"` et `window.open` : WebKit demande une nouvelle vue plutôt que de
    /// naviguer. Rendre `nil` reviendrait à avaler le lien en silence — c'est le défaut le
    /// plus courant des navigateurs maison.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = makeTab(configuration: configuration)
        // **Ouverte par un script, pas par un clic.** `createWebViewWith` sert les deux :
        // `window.open` d'un côté, un lien en `target="_blank"` de l'autre. Le second est
        // un geste de l'utilisateur, et ce qu'il demande — même un échec — lui appartient.
        tab.isPopup = navigationAction.navigationType == .other
        currentSpace.append(tab)
        activateCurrentTab()
        return tab.webView
    }

    func openInNewTab(_ url: URL, activate: Bool) {
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

    func select(tabID: UUID) {
        guard let tab = currentSpace.tab(with: tabID) else { return }
        currentSpace.current = tab
        activateCurrentTab()
    }

    func close(tabID: UUID) {
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
}
