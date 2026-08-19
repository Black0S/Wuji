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
        let tab = makeTab()
        currentSpace.append(tab)
        activateCurrentTab()
        tab.webView.load(URLRequest(url: url ?? Self.blankPage))
    }

    func makeTab(configuration override: WKWebViewConfiguration? = nil,
                         pendingURL: URL? = nil, pendingTitle: String? = nil) -> Tab {
        let tab = Tab(configuration: override ?? makeConfiguration(isPrivate: isPrivateSpace),
                      pendingURL: pendingURL, pendingTitle: pendingTitle)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.webView.pageZoom = zoom(for: pendingURL)
        tab.webView.isInspectable = settings.safariInspection
        // Un onglet vierge ne montre plus le blanc par défaut de WebKit : il prend le fond
        // du thème. Sans ça, ouvrir un onglet en thème sombre projette une page blanche
        // pleine hauteur, et c'est le contraire d'une interface qui se fait oublier.
        // Le fond des pages internes est celui de la sidebar : la fenêtre reste une seule
        // surface, sans cadre autour d'une page qui appartient à l'application.
        applyPageBackground(to: tab)

        // Chaque onglet s'observe lui-même, pas seulement celui qui est affiché : sinon un
        // onglet ouvert en arrière-plan reste figé sur son titre provisoire et son marqueur
        // de chargement jusqu'au prochain événement venu d'ailleurs.
        let sync: @Sendable (WKWebView, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncChrome() }
        }
        tab.observations = [
            tab.webView.observe(\.url, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.title, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.isLoading, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.estimatedProgress, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.canGoBack, options: [.initial, .new], changeHandler: sync),
            tab.webView.observe(\.canGoForward, options: [.initial, .new], changeHandler: sync)
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
        let tab = makeTab(pendingURL: closed.url, pendingTitle: closed.title)
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
        currentSpace.current = tab
        tab.lastSeen = Date()
        tab.wake()
        // C'est ici que le chargement différé se dénoue : un onglet restauré ne va
        // chercher sa page qu'au moment où on le regarde.
        tab.loadIfPending()
        layout.content.attach(tab.webView)
        syncChrome()
        scheduleSleep()
    }

    /// Endort les onglets qu'on ne regarde plus depuis un moment.
    ///
    /// **Un onglet en veille rend son processus de rendu et sa mémoire.** Une vue web
    /// invisible les garde : WebKit n'offre aucune API pour l'endormir, la seule façon est
    /// de vider la page en conservant de quoi la reconstruire. Dix minutes, parce que
    /// revenir sur un onglet après dix minutes coûte un rechargement qu'on accepte, alors
    /// qu'après trente secondes il surprendrait.
    /// Au bout de combien de temps un onglet qu'on ne regarde plus rend sa mémoire.
    ///
    /// **Cinq minutes.** Deux, c'était trop court à l'usage : on revenait sur un onglet
    /// quitté le temps d'une recherche et il fallait le recharger. Le survol le réveille
    /// avant le clic, mais ça ne rachète pas un délai qui se déclenche pendant qu'on
    /// travaille.
    ///
    /// Le processeur, lui, n'attend pas ce délai : une page qui n'est pas à l'écran est
    /// déjà bridée par WebKit, ses minuteries comprises.
    ///
    /// La valeur d'usine seulement : le délai réel vient des réglages, parce qu'aucune
    /// durée ne convient à toutes les machines ni à tous les usages.
    static let defaultSleepDelay = 300

    func scheduleSleep() {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs() }
        }
    }

    /// Réveille un onglet survolé, s'il l'est encore dans un cinquième de seconde.
    func prewake(_ id: UUID) {
        prewakeItem?.cancel()
        guard let tab = spaces.flatMap(\.allTabs).first(where: { $0.id == id }), tab.isSleeping
        else { return }
        let item = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let tab, tab.isSleeping else { return }
                tab.wake()
                self?.syncSidebar()
            }
        }
        prewakeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func sleepIdleTabs() {
        // Zéro veut dire jamais, et jamais se vérifie ici : aucun onglet n'est examiné.
        let delay = settings.sleepDelay
        guard delay > 0 else { return }
        let now = Date()
        for space in spaces {
            for tab in space.allTabs where tab !== space.current {
                guard now.timeIntervalSince(tab.lastSeen) > TimeInterval(delay), !tab.isSleeping,
                      tab.webView.url != nil else { continue }
                // **On demande au moteur, pas à la page.** Le drapeau posé par la page vient
                // d'un évènement `play` ou `pause` ; il suffit qu'un lecteur change de piste,
                // ou que WebKit bride l'onglet en arrière-plan, pour qu'un `pause` passe et
                // qu'on croie la musique finie. On endormait alors un onglet qui jouait, et
                // le son s'arrêtait — exactement ce que la mise en veille promettait
                // d'éviter.
                tab.webView.requestMediaPlaybackState { [weak self, weak tab] state in
                    MainActor.assumeIsolated {
                        guard let tab, state != .playing, !tab.isPlayingMedia else { return }
                        tab.sleep()
                        self?.syncSidebar()
                    }
                }
            }
        }
    }

    func syncChrome() {
        // Les observations posées avec `.initial` se déclenchent pendant la construction
        // des onglets — donc avant que `spaces` existe, au moment de la restauration.
        guard !spaces.isEmpty, let tab = currentTab else { return }
        let state = tab.security
        layout.content.border.set(state)
        layout.content.setProgress(tab.webView.estimatedProgress, isLoading: tab.webView.isLoading)
        layout.topBar.show(url: tab.url,
                           security: state,
                           canGoBack: tab.webView.canGoBack,
                           canGoForward: tab.webView.canGoForward)
        window.title = tab.title
        syncBlockingButton()
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
             depth: depth, isPlaying: tab.isPlayingMedia, isSleeping: tab.isSleeping)
    }

    // MARK: - Dossiers et déplacements

    /// Un espace privé neuf, et on y va.
    @objc func newPrivateSpace(_ sender: Any?) {
        let space = Space(name: "Privé", symbol: Space.privateSymbol)
        space.isPrivate = true
        spaces.append(space)
        currentSpaceIndex = spaces.count - 1
        newTab(url: nil)
        openOmnibox()
        layout.toast.show("Espace privé : rien ne sera enregistré")
    }

    @objc func newFolder(_ sender: Any?) {
        let folder = currentSpace.addFolder(named: "Dossier \(currentSpace.folders.count + 1)")
        // Le nouvel onglet courant y entre : créer un dossier vide qu'il faudrait ensuite
        // remplir à la main serait deux gestes pour une intention.
        if let tab = currentSpace.current { currentSpace.place(tab, at: .into(folder)) }
        syncSidebar()
    }

    func toggleFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        folder.isExpanded.toggle()
        syncSidebar()
    }

    func drop(tabID: UUID, on drop: SidebarDrop) {
        let space = currentSpace

        // Un dossier glissé ne porte pas d'onglet : c'est le même geste et le même
        // rappel, mais une autre collection.
        if let folder = space.folder(with: tabID) {
            switch drop {
            case .folderBefore(let otherID):
                if let other = space.folder(with: otherID) { space.moveFolder(folder, before: other) }
            case .folderEnd:
                space.moveFolderToEnd(folder)
            default:
                break
            }
            syncSidebar()
            return
        }

        guard let tab = space.tab(with: tabID) else { return }
        switch drop {
        case .before(let otherID):
            guard let other = space.tab(with: otherID) else { return }
            space.place(tab, at: .before(other))
        case .into(let folderID):
            guard let folder = space.folder(with: folderID) else { return }
            space.place(tab, at: .into(folder))
        case .end:
            space.place(tab, at: .looseEnd)
        case .folderBefore, .folderEnd:
            break
        }
        syncSidebar()
    }

    func showTabMenu(_ id: UUID, _ event: NSEvent) {
        let space = currentSpace
        guard space.tab(with: id) != nil else { return }

        // Le glisser-déposer reste le geste principal ; ce niveau est le chemin
        // équivalent pour qui préfère ne pas viser.
        var destinations = space.folders.map { folder in
            ActionItem(title: folder.name, symbol: "folder",
                       action: { [weak self] in
                           guard let self, let tab = self.currentSpace.tab(with: id) else { return }
                           self.currentSpace.place(tab, at: .into(folder))
                           self.syncSidebar()
                       })
        }
        if !destinations.isEmpty { destinations.append(.separator) }
        destinations.append(ActionItem(title: "Hors dossier", symbol: "tray",
                                       action: { [weak self] in
                                           guard let self, let tab = self.currentSpace.tab(with: id) else { return }
                                           self.currentSpace.place(tab, at: .looseEnd)
                                           self.syncSidebar()
                                       }))

        let items: [ActionItem] = [
            ActionItem(title: "Déplacer vers", symbol: "arrow.right.doc.on.clipboard",
                       children: destinations),
            .separator,
            ActionItem(title: "Fermer l'onglet", symbol: "xmark", shortcut: "⌘W",
                       isDestructive: true,
                       action: { [weak self] in self?.close(tabID: id) })
        ]
        presentSheet(items, at: event)
    }

    func showFolderMenu(_ id: UUID, _ event: NSEvent) {
        let items: [ActionItem] = [
            ActionItem(title: "Renommer", symbol: "pencil",
                       action: { [weak self] in self?.renameFolder(id) }),
            ActionItem(title: "Supprimer le dossier", symbol: "trash", isDestructive: true,
                       action: { [weak self] in self?.deleteFolder(id) })
        ]
        presentSheet(items, at: event)
    }

    func presentSheet(_ items: [ActionItem], at event: NSEvent) {
        let point = layout.convert(event.locationInWindow, from: nil)
        layout.actionSheet.present(items, at: point)
    }

    /// Renommer un dossier passe par une boîte de dialogue, faute d'une ligne qui puisse
    /// devenir éditable comme dans le panneau des espaces — la sidebar reconstruit ses
    /// lignes à chaque changement, l'édition en place n'y survivrait pas.
    func renameFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        layout.actionSheet.presentPrompt(title: "Renommer le dossier",
                                         value: folder.name,
                                         confirm: "Renommer") { [weak self] name in
            guard let self, let folder = self.currentSpace.folder(with: id) else { return }
            folder.name = name
            self.syncSidebar()
        }
    }

    /// Supprimer un dossier ne ferme pas ses onglets : ils redeviennent des onglets de
    /// passage. Rien à confirmer, rien n'est perdu.
    func deleteFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        currentSpace.removeFolder(folder)
        syncSidebar()
    }

    // MARK: - Espaces

    var spaceSnapshots: [SpaceRowSnapshot] {
        spaces.map {
            SpaceRowSnapshot(name: $0.name, symbol: $0.symbol, tabCount: $0.tabCount)
        }
    }

    func showSpacesPanel(from anchor: NSView) {
        layout.spacesPanel.present(spaces: spaceSnapshots,
                                   current: currentSpaceIndex,
                                   symbol: currentSpace.symbol,
                                   anchor: anchor)
    }

    func spacesPanel(_ panel: SpacesPanel, didSelect index: Int) {
        guard spaces.indices.contains(index), index != currentSpaceIndex else { return }
        currentSpaceIndex = index
        // Un espace vide n'existe pas : on y entre toujours sur un onglet.
        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
    }

    func spacesPanel(_ panel: SpacesPanel, didPick symbol: String) {
        // Le symbole d'un espace privé ne se change pas : c'est à quoi on le reconnaît.
        guard !currentSpace.isPrivate else {
            layout.toast.show("Le symbole d'un espace privé ne change pas")
            return
        }
        currentSpace.symbol = symbol
        refreshSpaces(panel)
    }

    func spacesPanel(_ panel: SpacesPanel, didRename index: Int, to name: String) {
        guard spaces.indices.contains(index) else { return }
        spaces[index].name = name
        refreshSpaces(panel)
    }

    func spacesPanel(_ panel: SpacesPanel, didMove index: Int, to destination: Int) {
        guard spaces.indices.contains(index), spaces.indices.contains(destination) else { return }
        // L'espace courant est suivi par son identité, pas par sa position : réordonner
        // ne doit pas faire basculer l'utilisateur dans un autre espace.
        let staying = currentSpace
        let moved = spaces.remove(at: index)
        spaces.insert(moved, at: destination)
        if let position = spaces.firstIndex(where: { $0 === staying }) {
            currentSpaceIndex = position
        }
        refreshSpaces(panel)
    }

    func spacesPanel(_ panel: SpacesPanel, menuFor index: Int, canDelete: Bool, at event: NSEvent) {
        let items: [ActionItem] = [
            ActionItem(title: "Renommer", symbol: "pencil",
                       action: { [weak panel] in panel?.beginRename(at: index) }),
            ActionItem(title: spaces.indices.contains(index) && spaces[index].isPrivate
                              ? "Rendre cet espace normal" : "Rendre cet espace privé",
                       symbol: spaces.indices.contains(index) && spaces[index].isPrivate
                              ? "eye" : "eye.slash",
                       action: { [weak self, weak panel] in
                           panel?.dismiss()
                           self?.togglePrivate(at: index)
                       }),
            .separator,
            ActionItem(title: "Supprimer", symbol: "trash", isEnabled: canDelete,
                       isDestructive: true,
                       action: { [weak self, weak panel] in
                           panel?.dismiss()
                           guard let self else { return }
                           self.spacesPanel(panel ?? self.layout.spacesPanel, didDelete: index)
                       })
        ]
        presentSheet(items, at: event)
    }

    /// Bascule un espace entre normal et privé.
    ///
    /// Les onglets déjà ouverts ne changent pas de monde : leurs vues web sont nées avec
    /// un magasin de données, et on ne le remplace pas sous leurs pieds. La bascule vaut
    /// donc pour la suite, et on le dit plutôt que de laisser croire à un effacement.
    func togglePrivate(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        let space = spaces[index]
        space.isPrivate.toggle()
        layout.toast.show(space.isPrivate
                          ? "« \(space.name) » est privé : rien ne sera enregistré"
                          : "« \(space.name) » redevient normal")
        syncSidebar()
        session.save(snapshot())
    }

    func spacesPanel(_ panel: SpacesPanel, didDelete index: Int) {
        guard spaces.indices.contains(index), spaces.count > 1 else { return }
        let doomed = spaces[index]

        // Supprimer un espace ferme ses onglets, et rien ne les rouvrira tant qu'il n'y a
        // pas d'historique : c'est une perte, donc on demande.
        guard !doomed.isEmpty else { return removeSpace(at: index) }
        layout.toast.ask(
            title: "Supprimer « \(doomed.name) » ?",
            message: doomed.tabCount == 1
                ? "Son onglet sera fermé, et rien ne le rouvrira."
                : "Ses \(doomed.tabCount) onglets seront fermés, et rien ne les rouvrira.",
            confirm: "Supprimer", isDestructive: true, onCancel: {},
            onConfirm: { [weak self] in self?.removeSpace(at: index) })
    }

    func removeSpace(at index: Int) {
        guard spaces.indices.contains(index), spaces.count > 1 else { return }
        spaces.remove(at: index)
        currentSpaceIndex = min(currentSpaceIndex, spaces.count - 1)
        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
    }

    /// Le panneau reste ouvert pendant qu'on règle un espace : il faut donc rafraîchir
    /// les deux surfaces, la sidebar et le panneau lui-même.
    func refreshSpaces(_ panel: SpacesPanel) {
        syncSidebar()
        panel.reload(spaces: spaceSnapshots,
                     current: currentSpaceIndex,
                     symbol: currentSpace.symbol)
    }

    func spacesPanelDidRequestNew(_ panel: SpacesPanel) {
        let index = spaces.count
        spaces.append(Space(name: "Espace \(index + 1)", symbol: Space.symbol(forIndex: index)))
        currentSpaceIndex = index
        newTab(url: nil)
    }
}
