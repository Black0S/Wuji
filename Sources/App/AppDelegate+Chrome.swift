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
        case .menu:    layout.actionSheet.present(mainMenu(), below: bar.menuButton)
        case .blocking: layout.actionSheet.present(blockingMenu(), below: bar.blockingButton)
        case .scripts:  layout.actionSheet.present(scriptsMenu(), below: bar.scriptsButton)
        case .security: layout.actionSheet.present(securityMenu(), below: bar.securityButton)
        }
    }

    /// Ce que le cadenas promet, en clair.
    ///
    /// **Il affirmait « chiffré » sans jamais dire par qui.** Or c'est exactement la
    /// question qu'on se pose au moment où l'on regarde ce symbole — surtout sur un site
    /// où l'on va taper quelque chose. Un indicateur de sécurité qui ne mène à rien demande
    /// qu'on lui fasse confiance, ce qui est le contraire de son rôle.
    ///
    /// Rien n'est inventé : ce qui n'est pas lisible dans le certificat n'est pas affiché.
    func securityMenu() -> [ActionItem] {
        guard let tab = currentTab, let url = tab.url, let host = url.host() else { return [] }
        var items: [ActionItem] = []

        if tab.isInsecure {
            items.append(ActionItem(title: "Connexion non chiffrée",
                                    symbol: "exclamationmark.triangle", isEnabled: false))
            items.append(ActionItem(title: "Ce que vous tapez ici circule en clair",
                                    symbol: "eye", isEnabled: false))
        } else {
            items.append(ActionItem(title: "Connexion chiffrée avec \(host)",
                                    symbol: "lock", isEnabled: false))
            for line in Certificate.describe(tab.webView.serverTrust) {
                items.append(ActionItem(title: line, symbol: "checkmark.seal", isEnabled: false))
            }
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
            // ⇧⌘N appartient à l'espace privé, ici comme dans la barre de menus. La
            // feuille annonçait encore l'ancien raccourci : un libellé qui ment sur ce
            // qu'il faut taper est pire que pas de libellé du tout.
            ActionItem(title: "Nouveau dossier", symbol: "folder.badge.plus", shortcut: "⌥⌘N",
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

        guard !input.contains(" "), input.contains(".") else { return nil }
        let candidate = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }
}
