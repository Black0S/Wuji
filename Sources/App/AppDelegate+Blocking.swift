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

    func refreshBlockingPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "blocking" }
            .forEach { $0.webView.reload() }
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
