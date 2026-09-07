import AppKit
import WebKit

/// Le blocage : sa page, ses actions, et ce qu'il faut reposer sur les onglets ouverts.
extension AppDelegate {

    static let blockingPage = URL(string: "wuji://blocking")!

    @objc func showBlocking(_ sender: Any?) {
        openInternal(Self.blockingPage)
        // Le catalogue est relu à chaque ouverture : deux cents kilo-octets, et un
        // catalogue d'hier ne se distingue pas d'un catalogue d'aujourd'hui.
        loadRuleCatalog()
    }

    /// Met à jour les pages de blocage ouvertes — **sur place, pas par un rechargement**.
    ///
    /// Recharger remettait la liste en haut et effaçait le filtre qu'on venait de taper, et
    /// cela deux fois par case cochée puisqu'installer produit un état « en cours » puis un
    /// état « en service ». Ce n'est pas un détail de confort : on ne peut pas cocher trois
    /// listes trouvées par un mot-clé si chaque clic efface le mot-clé.
    ///
    /// Le repli sur le rechargement reste pour le premier affichage — une page qui n'a pas
    /// encore posé son crochet ne saurait pas quoi faire du correctif.
    func refreshBlockingPages() {
        let patch = BlockingPage.patch(blockingState)
        for tab in spaces.flatMap(\.allTabs) where tab.url?.host() == "blocking" {
            tab.webView.evaluateJavaScript(patch) { value, _ in
                MainActor.assumeIsolated {
                    guard value == nil else { return }
                    tab.webView.reload()
                }
            }
        }
    }

    /// Ce que la page affiche, à l'instant où on la dessine.
    var blockingState: BlockingPage.State {
        BlockingPage.State(
            catalog: ruleCatalog,
            installed: Set(settings.enabledRuleLists),
            outdated: Set(ruleCatalog.filter { blocking.isOutdated($0) }.map(\.id)),
            activeRules: blocking.ruleCount,
            busy: {
                switch blocking.progress {
                case .downloading(let name): return "Téléchargement de « \(name) »"
                case .compiling(let name):   return "Compilation de « \(name) »"
                default:                     return nil
                }
            }(),
            failure: {
                if case .failed(let name, let why) = blocking.progress {
                    return "« \(name) » : \(why)"
                }
                return nil
            }(),
            unreachable: catalogUnreachable)
    }

    /// Va chercher le catalogue. **Rien d'autre n'est téléchargé** : les règles ne partent
    /// qu'à la demande, liste par liste.
    func loadRuleCatalog() {
        Task { @MainActor in
            do {
                ruleCatalog = try await RuleCatalog.fetch()
                catalogUnreachable = false
            } catch {
                // On garde ce qu'on avait : un catalogue affiché puis effacé par une coupure
                // de réseau ferait croire que les listes ont disparu.
                catalogUnreachable = ruleCatalog.isEmpty
            }
            refreshBlockingPages()
        }
    }

    // MARK: - Le menu du bouclier

    /// Ce que le bouclier ouvre.
    ///
    /// **Pas la page directement.** Le bouclier porte deux gestes de natures différentes :
    /// choisir des listes, ce qui se fait rarement, et masquer un élément de la page qu'on
    /// regarde, ce qui se fait sur le coup. Mener droit à la page aurait enterré le second
    /// derrière une navigation, pour le seul motif que le premier existait avant.
    func blockingMenu() -> [ActionItem] {
        var items: [ActionItem] = []
        let host = currentTab?.url.flatMap { UserRules.registrable($0.host ?? "") }

        if let host, currentTab?.url?.scheme?.hasPrefix("http") == true {
            items.append(ActionItem(title: "Masquer un élément…", symbol: "square.dashed",
                                    action: { [weak self] in self?.startElementPicker() }))
            let mine = userRules.rules.filter { $0.host == host }
            if !mine.isEmpty {
                items.append(ActionItem(
                    title: "Retirer mes \(mine.count) règle\(mine.count > 1 ? "s" : "") sur \(host)",
                    symbol: "arrow.uturn.left", isDestructive: true,
                    action: { [weak self] in
                        self?.userRules.removeAll(for: host)
                        self?.layout.toast.show("Règles de « \(host) » retirées")
                    }))
            }
            items.append(.separator)
        }
        items.append(ActionItem(title: "Listes de blocage…", symbol: "shield.lefthalf.filled",
                                action: { [weak self] in self?.showBlocking(nil) }))
        return items
    }

    /// Ouvre le sélecteur sur la page courante.
    ///
    /// Il n'y a rien à ouvrir sur une page interne ou une page d'erreur : une règle y
    /// désignerait un élément de Wuji, pas du web.
    func startElementPicker() {
        guard let tab = currentTab, let url = tab.url,
              url.scheme?.hasPrefix("http") == true else {
            layout.toast.show("Rien à masquer sur cette page")
            return
        }
        tab.webView.evaluateJavaScript(ElementPicker.script)
        layout.toast.show("Désignez l'élément à masquer — échap pour renoncer")
    }

    /// Ce que le sélecteur renvoie.
    func handlePickedElement(_ payload: [String: Any]) {
        guard let selector = payload["selector"] as? String,
              let host = payload["host"] as? String, !selector.isEmpty else { return }
        Task { @MainActor in
            let site = UserRules.registrable(host)
            guard await userRules.add(host: site, selector: selector) else {
                layout.toast.show("Cette règle existait déjà")
                return
            }
            applyBlockingToOpenTabs()
            syncChrome()
            layout.toast.show("Masqué sur « \(site) » — rechargez pour voir l'effet") {
                [weak self] in self?.currentTab?.webView.reload()
            }
        }
    }

    func handleBlockingAction(_ action: String, id: String?) {
        switch action {
        case "reload":
            loadRuleCatalog()
        case "install", "update":
            guard let id, let list = ruleCatalog.first(where: { $0.id == id }) else { return }
            Task { @MainActor in
                if action == "update" { blocking.remove(id) }
                if let failure = await blocking.install(list) {
                    layout.toast.show("« \(list.name) » : \(failure)")
                } else {
                    layout.toast.show("« \(list.name) » en service — "
                        + "\(list.rules) règles")
                }
                applyBlockingToOpenTabs()
                refreshBlockingPages()
                syncChrome()
            }
        case "remove":
            guard let id else { return }
            let name = ruleCatalog.first { $0.id == id }?.name ?? id
            blocking.remove(id)
            applyBlockingToOpenTabs()
            refreshBlockingPages()
            syncChrome()
            layout.toast.show("« \(name) » retirée")
        default:
            break
        }
    }

    /// Repose les règles sur tout ce qui est déjà ouvert.
    ///
    /// **Chaque onglet a son propre contrôleur de contenu** — c'est ce qui empêche deux
    /// pages qui chargent en même temps de se voler leurs scripts —, donc une liste
    /// nouvellement activée doit être posée sur chacun. Sans cela, elle ne vaudrait que
    /// pour les onglets ouverts *après*, ce qui est le genre de règle qu'on ne devine pas.
    ///
    /// La page n'est pas rechargée pour autant : les règles s'appliquent aux requêtes
    /// suivantes, et recharger trente onglets pour une case cochée coûterait plus que le
    /// blocage ne rapporte sur la page qu'on regarde déjà.
    func applyBlockingToOpenTabs() {
        for tab in spaces.flatMap(\.allTabs) {
            blocking.reapply(to: tab.webView.configuration.userContentController)
        }
    }
}
