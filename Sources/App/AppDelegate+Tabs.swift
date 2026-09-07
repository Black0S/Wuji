import AppKit
import WebKit

/// Les onglets, les dossiers et les espaces.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - Onglets

    /// `⌘T` n'ouvre que la palette. L'onglet ne naît qu'au moment où l'on choisit une
    /// destination — et pas du tout si l'on bascule sur un onglet déjà ouvert, ce qui est
    /// le cas le plus fréquent. Créer l'onglet d'abord laissait une page vide derrière
    /// chaque changement d'onglet fait au clavier.
    @objc func newTab(_ sender: Any?) {
        openOmnibox(creatingTab: true)
    }

    /// Sans adresse, l'onglet ouvre la page vierge de Wuji plutôt que de rester blanc :
    /// elle porte le fond de la sidebar, donc la fenêtre reste une seule surface tant
    /// qu'il n'y a rien à afficher.
    static let blankPage = URL(string: "wuji://")!

    /// Un onglet vierge n'est pas encore un onglet : il n'a ni adresse ni titre à montrer.
    /// Il reste donc hors de la liste, hors de la palette et hors de la session — sinon on
    /// listerait une ligne qui ne désigne rien, et on la restaurerait au lancement suivant.
    ///
    /// **L'invariant que ce filtre exige.** Il ne juge que sur l'adresse, donc tout onglet
    /// qui a montré quelque chose doit continuer d'en annoncer une, y compris pendant qu'il
    /// dort et sa vue vidée. C'est `Tab.resolvedURL` qui le garantit, et c'est là qu'il
    /// faut regarder si une ligne disparaît sans qu'on l'ait fermée — le filtre, lui, fait
    /// exactement ce qu'on lui demande.
    func isBlank(_ tab: Tab) -> Bool {
        tab.url == nil || tab.url == Self.blankPage
    }

    func newTab(url: URL?) {
        let tab = makeTab(configuration: nil)
        currentSpace.append(tab)
        activateCurrentTab()
        tab.webView.load(URLRequest(url: url ?? Self.blankPage))
    }

    func makeTab(configuration override: WKWebViewConfiguration? = nil,
                         url: URL? = nil, title: String? = nil) -> Tab {
        let tab = Tab(configuration: override ?? makeConfiguration(isPrivate: isPrivateSpace),
                      url: url, title: title)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        // **Rien qui touche à la page ici.** `pageZoom` et `underPageBackgroundColor` sont
        // des propriétés de page : les poser oblige WebKit à instancier la page, donc à
        // lancer un processus de rendu — pour un onglet restauré que personne ne regarde
        // encore. Ils sont posés à l'affichage, par `activateCurrentTab`.
        if url != nil || title != nil {
            // Un onglet restauré : il attendra d'être regardé.
        } else {
            tab.webView.pageZoom = zoom(for: nil)
            // Un onglet vierge ne montre plus le blanc par défaut de WebKit : il prend le
            // fond du thème. Sans ça, ouvrir un onglet en thème sombre projette une page
            // blanche pleine hauteur, et c'est le contraire d'une interface qui se fait
            // oublier.
            applyPageBackground(to: tab)
        }

        // Chaque onglet s'observe lui-même, pas seulement celui qui est affiché : sinon un
        // onglet ouvert en arrière-plan reste figé sur son titre provisoire et son marqueur
        // de chargement jusqu'au prochain événement venu d'ailleurs.
        //
        // **Sans `.initial`.** L'observation se déclenchait à la pose, sur une vue qui
        // n'avait encore ni adresse ni titre : cinq synchronisations complètes du chrome
        // par onglet créé, soit soixante-cinq pour une session de treize onglets, toutes
        // sur du vide. Chaque chemin qui crée un onglet finit par `activateCurrentTab`,
        // qui synchronise une fois — ce qui suffit et ce qui est vrai.
        let sync: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncChrome() }
        }
        tab.observations = [
            tab.webView.observe(\.url, options: [.new], changeHandler: sync),
            tab.webView.observe(\.title, options: [.new], changeHandler: sync),
            tab.webView.observe(\.isLoading, options: [.new], changeHandler: sync),
            tab.webView.observe(\.canGoBack, options: [.new], changeHandler: sync),
            tab.webView.observe(\.canGoForward, options: [.new], changeHandler: sync)
        ]

        tab.observations += [
            // L'adresse seulement : rejouer ici les scripts de l'utilisateur ferait deux
            // mécanismes pour un seul propos. C'est `RouteWatcher` qui s'en charge, et lui
            // sait distinguer une vraie navigation d'un `pushState` — cette observation, non.
            tab.webView.observe(\.url, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let tab else { return }
                }
            },
            tab.webView.observe(\.title, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let tab else { return }
                }
            },
            tab.webView.observe(\.isLoading, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let tab else { return }
                }
            }
        ]

        return tab
    }

    // MARK: - Rouvrir un onglet fermé

    /// Un onglet fermé, et de quoi le rendre **là où il était**.
    ///
    /// L'espace et le dossier sont désignés par leur identité, la place par un rang :
    /// entre la fermeture et la reprise, un voisin a pu disparaître, mais un conteneur
    /// nommé et un rang borné retombent toujours sur quelque chose de vrai.
    struct ClosedTab {
        let url: URL
        let title: String
        let space: UUID
        let folder: UUID?
        let index: Int
    }

    func remember(_ tab: Tab, in space: Space) {
        // Une page vierge n'a rien à rendre : la rouvrir donnerait une page vierge de plus.
        guard let url = tab.url, !isBlank(tab) else { return }
        let folder = space.folders.first { $0.tabs.contains { $0 === tab } }
        let index = folder.flatMap { $0.tabs.firstIndex { $0 === tab } }
            ?? space.loose.firstIndex { $0 === tab }
            ?? space.loose.count

        closedTabs.append(ClosedTab(url: url, title: tab.title, space: space.id,
                                    folder: folder?.id, index: index))
        // Borné : au-delà d'une poignée, ce n'est plus « rouvrir ce que je viens de
        // fermer », c'est un second historique — et il en existe déjà un vrai.
        if closedTabs.count > 12 { closedTabs.removeFirst() }
    }

    /// `⇧⌘T` rend le dernier onglet fermé, dans son espace et à sa place.
    ///
    /// Il revient chargé en différé, comme au démarrage : on rouvre souvent par réflexe,
    /// et une requête réseau immédiate pour un onglet qu'on regardera peut-être serait
    /// payée à chaque fois.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = closedTabs.popLast() else { return }

        // L'espace d'origine s'il existe encore, celui d'aujourd'hui sinon : rendre
        // l'onglet ailleurs vaut mieux que ne rien rendre.
        if let index = spaces.firstIndex(where: { $0.id == closed.space }) {
            currentSpaceIndex = index
        }
        let space = currentSpace
        let tab = makeTab(url: closed.url, title: closed.title)
        space.restore(tab, folder: closed.folder, index: closed.index)
        space.current = tab
        activateCurrentTab()
    }

    @objc func nextTab(_ sender: Any?) { step(by: 1) }
    @objc func previousTab(_ sender: Any?) { step(by: -1) }

    /// La navigation clavier suit l'ordre d'affichage, dossiers compris : c'est celui que
    /// l'utilisateur a sous les yeux.
    func step(by delta: Int) {
        let order = currentSpace.allTabs
        guard order.count > 1,
              let position = order.firstIndex(where: { $0 === currentSpace.current }) else { return }
        currentSpace.current = order[(position + delta + order.count) % order.count]
        activateCurrentTab()
    }

    func activateCurrentTab() {
        guard let tab = currentSpace.current ?? currentSpace.allTabs.first else { return }
        let previous = activeTab
        activeTab = tab
        currentSpace.current = tab
        // C'est ici que le chargement différé se dénoue : un onglet restauré ne va
        // chercher sa page qu'au moment où on le regarde — et c'est ici, pas avant, qu'il
        // reçoit ce qui touche à sa page.
        tab.webView.pageZoom = zoom(for: tab.url)
        applyPageBackground(to: tab)
        tab.loadIfPending()
        // La complétion est ancrée à un champ de la page qu'on quitte : elle n'a plus
        // rien à désigner dès que la vue change.
        layout.suggestions.dismiss()
        layout.content.attach(tab.webView)
        syncChrome()
    }

    func syncChrome() {
        // Les observations posées avec `.initial` se déclenchent pendant la construction
        // des onglets — donc avant que `spaces` existe, au moment de la restauration.
        guard !spaces.isEmpty, let tab = currentTab else { return }
        layout.topBar.show(url: tab.url,
                           insecure: tab.isInsecure,
                           canGoBack: tab.webView.canGoBack,
                           canGoForward: tab.webView.canGoForward,
                           extensionName: nil)
        // **L'écart se mesure au réglage par défaut, pas à cent pour cent.**
        //
        // Le badge disparaissait à 100 %. Quelqu'un dont le zoom général vaut 80 % voyait
        // donc « 80 % » sur chaque page, pour toujours — et `⌘0`, qui rend justement le
        // zoom par défaut, laissait le chiffre à l'écran comme si le geste n'avait pas
        // abouti. Le badge dit ce qui *diffère* de ce qu'on a choisi ; quand plus rien ne
        // diffère, il n'a rien à dire.
        let percent = Int((zoom(for: tab.url) * 100).rounded())
        let byDefault = Int((settings.pageZoom * 100).rounded())
        layout.topBar.setZoom(percent == byDefault ? nil : percent)
        let reading = readingTabs.contains(tab.id)
        layout.topBar.setReader(available: tab.hasArticle || reading, active: reading)
        window.title = tab.title
        syncToolbarButtons()
        syncSidebar()
    }

    /// Construit la liste affichée : les dossiers avec leur contenu, puis les onglets de
    /// passage. La sidebar ne reçoit que des identités et de quoi dessiner.
    func syncSidebar() {
        guard !spaces.isEmpty else { return }
        let space = currentSpace
        layout.sidebar.update(space: SpaceSnapshot(name: space.name, symbol: space.symbol))

        var items: [SidebarItem] = []
        for folder in space.folders {
            let visible = folder.tabs.filter { !isBlank($0) }
            items.append(.folder(id: folder.id, name: folder.name,
                                 isExpanded: folder.isExpanded, count: visible.count))
            if folder.isExpanded {
                items.append(contentsOf: visible.map { item(for: $0, depth: 1) })
            }
        }
        items.append(contentsOf: space.loose.filter { !isBlank($0) }.map { item(for: $0, depth: 0) })

        layout.sidebar.update(items: items, selected: space.current?.id)
        session.scheduleSave(self.snapshot())
    }

    func item(for tab: Tab, depth: Int) -> SidebarItem {
        .tab(id: tab.id, title: tab.title, host: tab.url?.host() ?? "",
             isLoading: tab.webView.isLoading, favicon: favicons.icon(for: tab.url),
             depth: depth, isPlaying: tab.isPlayingMedia)
    }
}
