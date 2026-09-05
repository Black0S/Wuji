import AppKit
import WebKit

/// Le chrome : barre du haut, palette, recherche dans la page.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - ContentTopBarDelegate

    func topBarDidRequestOmnibox(_ bar: ContentTopBar) {
        openOmnibox()
    }

    func topBar(_ bar: ContentTopBar, didTrigger action: ContentTopBar.Action) {
        switch action {
        case .back:    currentTab?.webView.goBack()
        case .forward: currentTab?.webView.goForward()
        case .menu:       NativeMenu.popUp(mainMenu(), below: bar.menuButton)
        case .extensions: NativeMenu.popUp(extensionsMenu(), below: bar.extensionsButton)
        case .scripts:    NativeMenu.popUp(scriptsMenu(), below: bar.scriptsButton)
        case .security:   NativeMenu.popUp(securityMenu(), below: bar.securityButton)
        case .zoomReset:  zoomReset(nil)
        case .reader:     toggleReader(nil)
        }
    }

    /// Un clic sur une icône épinglée : exactement ce que ferait la ligne du menu.
    func topBar(_ bar: ContentTopBar, didTriggerExtension id: String) {
        guard let context = extensions.contexts[id] else { return }
        perform(context)
    }

    func topBar(_ bar: ContentTopBar, menuForExtension id: String) -> [ActionItem] {
        pinnedMenu(for: id)
    }

    /// Ce que le cadenas promet, en clair.
    ///
    /// **Il affirmait « chiffré » sans jamais dire par qui.** Or c'est exactement la
    /// question qu'on se pose au moment où l'on regarde ce symbole — surtout sur un site
    /// où l'on va taper quelque chose. Un indicateur de sécurité qui ne mène à rien demande
    /// qu'on lui fasse confiance, ce qui est le contraire de son rôle.
    ///
    /// **Deux lignes qui répondent, puis cinq portes.** Il a d'abord montré tout le
    /// certificat à plat : onze entrées, dont une empreinte de quatre-vingt-quinze
    /// caractères qui étirait le menu jusqu'au bord de l'écran. Ce n'était pas trop
    /// d'information, c'était la mauvaise forme — on ne lit pas un certificat en entier, on
    /// y cherche une chose. L'essentiel se lit sans cliquer ; le reste attend derrière le
    /// groupe qui le concerne.
    ///
    /// Rien n'est inventé : ce qui n'est pas lisible dans le certificat n'est pas affiché.
    func securityMenu() -> [ActionItem] {
        guard let tab = currentTab, let url = tab.url, let host = url.host() else { return [] }

        guard !tab.isInsecure else {
            return [
                ActionItem(title: "Connexion non chiffrée", symbol: "exclamationmark.triangle",
                           isEnabled: false),
                ActionItem(title: "Ce que vous tapez ici circule en clair", symbol: "eye",
                           isEnabled: false),
                .separator,
                ActionItem(title: "Copier l'adresse de la page", symbol: "link",
                           action: { Self.copy(url.absoluteString) })
            ]
        }

        let trust = tab.webView.serverTrust
        var items = [ActionItem(title: "Connexion chiffrée avec \(host)",
                                symbol: "lock", isEnabled: false)]
        if let authority = Certificate.authority(trust) {
            items.append(ActionItem(title: "Certificat attesté par \(authority)",
                                    symbol: "checkmark.seal", isEnabled: false))
        }

        items.append(contentsOf: passwordItems(for: host))

        let sections = Certificate.sections(trust)
        guard !sections.isEmpty else {
            // Pas de certificat lisible : le dire, plutôt que d'ouvrir des sous-menus vides.
            // Le cas arrive sur une page servie depuis le cache avant que la connexion soit
            // établie.
            items.append(ActionItem(title: "Certificat illisible pour l'instant",
                                    symbol: "questionmark.circle", isEnabled: false))
            return items
        }

        items.append(.separator)
        for section in sections {
            // Chaque ligne du détail se copie d'un clic : l'empreinte et le numéro de série
            // n'existent que pour être comparés ailleurs, et les retaper à la main est le
            // meilleur moyen de se tromper d'un caractère sans le voir.
            items.append(ActionItem(title: section.title, symbol: section.symbol,
                                    children: section.details.map { detail in
                                        ActionItem(title: detail.label.isEmpty
                                                       ? detail.value
                                                       : "\(detail.label) \(detail.value)",
                                                   action: { Self.copy(detail.value) })
                                    }))
        }

        // L'empreinte entière, en un seul morceau : elle est découpée en quatre lignes pour
        // se lire, et c'est d'un bloc qu'elle se colle ailleurs.
        if let print = Certificate.fingerprint(trust) {
            items.append(.separator)
            items.append(ActionItem(title: "Copier l'empreinte", symbol: "doc.on.doc",
                                    action: { Self.copy(print) }))
        }
        return items
    }

    /// Le menu principal ne contient que ce qui existe. La maquette en montrait onze
    /// entrées ; les favoris, l'historique, les téléchargements et la session privée
    /// n'existent pas encore, et les afficher grisés donnerait l'illusion d'un produit
    /// plus avancé qu'il ne l'est.
    func mainMenu() -> [ActionItem] {
        var items: [ActionItem] = [
            ActionItem(title: "Nouvel onglet", symbol: "plus", shortcut: "⌘T",
                       action: { [weak self] in self?.newTab(nil) }),
            // Le dossier a repris ⇧⌘N, que l'espace privé lui empruntait : un espace se
            // crée avec ⌥, comme tous les autres gestes qui le visent. Un libellé qui
            // ment sur ce qu'il faut taper est pire que pas de libellé du tout.
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

    func search(_ query: String, backwards: Bool) {
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
    func countMatches(of query: String) {
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
        guard !input.contains(" ") else { return nil }

        // Un schéma écrit à la main fait foi : on ne corrige pas ce qui est explicite.
        if input.contains("://") {
            guard let url = URL(string: input), url.host != nil else { return nil }
            return normalised(url)
        }

        // Le point ne suffit plus à distinguer une adresse d'une recherche : « localhost:8080 »
        // n'en a pas et n'est pas une question qu'on pose à un moteur.
        let authority = input.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let local = isLocalHost(host)
        guard input.contains(".") || local else { return nil }

        // **`https` par défaut, sauf chez soi.** Un serveur de développement ne présente
        // presque jamais de certificat : viser `https://pma.localhost` d'abord, c'est
        // échouer sur une adresse qui marche. Ailleurs le défaut reste le chiffrement —
        // on ne rétrograde pas le web entier pour le cas du poste local.
        guard let url = URL(string: "\(local ? "http" : "https")://\(input)"),
              url.host != nil else { return nil }
        return normalised(url)
    }

    /// **Un nom de domaine accentué doit ressortir en punycode.**
    ///
    /// `URL(string: "https://café.fr")` compose bien `https://xn--caf-dma.fr` — la
    /// navigation marche. Mais `host()` sur cette URL rend `caf%C3%A9.fr`, la forme
    /// pourcent-encodée de l'original, et non la forme du réseau. Tout ce que Wuji range
    /// par hôte hérite alors de cette chaîne : le nom du site devient « caf%c3%a9.fr », et
    /// une exception de blocage posée là ne correspondrait jamais à la page, qui, elle,
    /// s'annonce en punycode.
    ///
    /// Relire l'URL depuis sa propre chaîne suffit : la chaîne est déjà en punycode, donc
    /// la seconde lecture donne un hôte que la liste des suffixes publics reconnaît. C'est
    /// exactement ce que la bibliothèque demande à l'appelant de faire — elle prévient
    /// qu'elle ne s'occupe ni de la casse ni du punycode.
    private static func normalised(_ url: URL) -> URL {
        URL(string: url.absoluteString) ?? url
    }

    /// « Chez soi » : cette machine, ou le réseau qu'on a sous la main.
    ///
    /// `localhost` et ses sous-domaines — c'est ainsi qu'un routeur de conteneurs nomme
    /// chaque service (`pma.localhost`, `api.localhost`) —, les noms Bonjour en `.local`,
    /// la boucle locale et les plages privées.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "127.0.0.1" || host == "::1" || host == "[::1]" { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("169.254.") {
            return true
        }
        // 172.16.0.0 – 172.31.255.255 : la plage privée qui ne se lit pas au préfixe.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]), (16...31).contains(second) {
            return true
        }
        return false
    }
}
