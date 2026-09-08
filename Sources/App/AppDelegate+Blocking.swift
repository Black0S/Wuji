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
    /// **La page répond un mot convenu.** Elle le faisait déjà, mais le correctif ne
    /// renvoyait rien : `undefined` traverse WebKit comme « rien », c'est-à-dire comme un
    /// crochet absent, et l'on rechargeait la page qu'on venait de mettre à jour. Le repli
    /// sur le rechargement ne vaut plus que pour ce qu'il visait — le premier affichage,
    /// où la page n'a pas encore posé son crochet.
    ///
    /// Les deux pages passent par ici : les règles personnelles ont leur adresse depuis
    /// qu'elles ont quitté le catalogue, et elles bougent aux mêmes moments.
    func refreshBlockingPages() {
        let ids = ruleCatalog.map(\.id)
        let renewed = ids != patchedCatalog
        patchedCatalog = ids
        let patches = ["blocking": BlockingPage.patch(blockingState, catalog: renewed),
                       "rules": RulesPage.patch(rulesState)]
        for tab in spaces.flatMap(\.allTabs) {
            guard let host = tab.url?.host(), let patch = patches[host] else { continue }
            tab.webView.evaluateJavaScript(patch) { value, _ in
                MainActor.assumeIsolated {
                    guard (value as? String) != "wuji-ok" else { return }
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
            working: blocking.working,
            failure: blocking.failure,
            unreachable: catalogUnreachable,
            paused: settings.pausedHosts,
            orphans: orphanedLists,
            injection: {
                let hôte = currentTab?.url.flatMap { $0.host() } ?? ""
                return BlockingPage.Injection(
                    enabled: settings.injectedRulesEnabled,
                    rules: extended.count, lists: extended.listCount,
                    here: injectionPayload(for: currentTab?.url).count,
                    host: hôte)
            }())
    }

    /// Reprend les listes cochées sous les identités que le catalogue publie aujourd'hui.
    ///
    /// **Le dépôt est passé du nom de fichier à un identifiant explicite.** Sans reprise,
    /// dix-sept listes en service seraient sorties des réglages d'un coup : décochées sans
    /// qu'on l'ait demandé, leurs règles compilées laissées sur le disque, et le balayage du
    /// lancement suivant les aurait jetées. La seule clé que les deux catalogues partagent
    /// est le nom du fichier d'origine — c'est par elle qu'on passe, une fois.
    func adoptCatalogIdentities() {
        var repris = 0
        for liste in ruleCatalog where liste.id != liste.source {
            guard settings.ruleListFiles[liste.source] != nil,
                  settings.ruleListFiles[liste.id] == nil else { continue }
            settings.renameRuleList(from: liste.source, to: liste.id)
            repris += 1
        }
        guard repris > 0 else { return }
        // Les règles compilées vivent sous le nom de leurs fichiers, pas sous celui de la
        // liste : rien à recompiler, il suffit de les retrouver sous la nouvelle clé.
        blocking.restore()
        syncExtendedRules()
    }

    /// Les listes en service que le catalogue ne publie plus.
    ///
    /// **Elles bloquent encore.** Leurs règles compilées sont dans le magasin de WebKit et
    /// y restent ; ce qu'elles ne peuvent plus, c'est être mises à jour — personne ne les
    /// publie. Les cacher aurait été le pire des deux : une protection qu'on croit disparue
    /// et qui agit encore, ou l'inverse.
    var orphanedLists: [String] {
        guard !ruleCatalog.isEmpty else { return [] }
        let connues = Set(ruleCatalog.map(\.id)).union(ruleCatalog.map(\.source))
        return settings.enabledRuleLists.filter { !connues.contains($0) }.sorted()
    }

    /// Ce que la page des règles personnelles affiche.
    var rulesState: RulesPage.State { RulesPage.State(mine: userRules.rules) }

    /// Va chercher le catalogue. **Rien d'autre n'est téléchargé** : les règles ne partent
    /// qu'à la demande, liste par liste.
    func loadRuleCatalog() {
        Task { @MainActor in
            do {
                ruleCatalog = try await RuleCatalog.fetch()
                catalogUnreachable = false
                adoptCatalogIdentities()
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

        // **Ce que le menu annonce est vrai, et rien de plus.** WebKit applique les règles
        // dans son processus réseau et n'en rend aucun compte : mesuré, aucun rappel de
        // blocage n'existe pour une application tierce. Un « 247 éléments bloqués sur cette
        // page » serait un nombre inventé — le genre de chiffre qui rassure et qu'on ne peut
        // pas vérifier. On dit donc ce qu'on sait : combien de règles sont en service, et
        // combien d'éléments *nos* règles masquent ici, celles-là étant comptables.
        let lists = blocking.installed.count
        let rules = blocking.ruleCount
        items.append(ActionItem(
            title: lists == 0 ? "Aucune liste en service"
                              : "\(lists) liste\(lists > 1 ? "s" : "") · \(Self.grouped(rules)) règles",
            symbol: "shield.lefthalf.filled", isEnabled: false, action: {}))

        // Ce que les règles à injection font ici, et rien de plus : le nombre est celui
        // des règles retenues pour cette page, pas celui du magasin.
        let injectées = injectionPayload(for: currentTab?.url).count
        if injectées > 0 {
            items.append(ActionItem(
                title: "\(injectées) règle\(injectées > 1 ? "s" : "") à injection ici",
                symbol: "curlybraces", isEnabled: false, action: {}))
        }

        if let host {
            let mine = userRules.rules.filter { $0.host == host }
            if !mine.isEmpty {
                items.append(ActionItem(
                    title: "\(mine.count) élément\(mine.count > 1 ? "s" : "") masqué"
                        + "\(mine.count > 1 ? "s" : "") sur \(host)",
                    symbol: "eye.slash", isEnabled: false, action: {}))
            }
        }
        items.append(.separator)

        if let host, currentTab?.url?.scheme?.hasPrefix("http") == true {
            let paused = blocking.isPaused(host)
            items.append(ActionItem(
                title: paused ? "Reprendre le blocage sur \(host)"
                              : "Suspendre le blocage sur \(host)",
                symbol: paused ? "play" : "pause",
                action: { [weak self] in
                    guard let self else { return }
                    blocking.setPaused(!paused, host: host)
                    // Une pause qui n'atteindrait pas les vues déjà ouvertes ne vaudrait
                    // qu'à la navigation suivante : on repose donc les règles tout de suite.
                    applyBlockingToOpenTabs()
                    layout.toast.show(paused ? "Blocage repris sur « \(host) »"
                                             : "Blocage suspendu sur « \(host) »") {
                        [weak self] in self?.currentTab?.webView.reload()
                    }
                }))
            items.append(ActionItem(title: "Masquer un élément…", symbol: "square.dashed",
                                    action: { [weak self] in self?.startElementPicker() }))
            let mine = userRules.rules.filter { $0.host == host }
            if !mine.isEmpty {
                items.append(ActionItem(
                    title: mine.count == 1 ? "Retirer ma règle sur \(host)"
                                           : "Retirer mes \(mine.count) règles sur \(host)",
                    symbol: "arrow.uturn.left", isDestructive: true,
                    action: { [weak self] in
                        self?.forgetRules(of: host)
                    }))
            }
            items.append(.separator)
        }
        items.append(ActionItem(title: "Listes de blocage…", symbol: "list.bullet",
                                action: { [weak self] in self?.showBlocking(nil) }))
        items.append(ActionItem(title: "Mes règles…", symbol: "eye.slash",
                                action: { [weak self] in self?.showRules(nil) }))
        return items
    }

    /// Les grands nombres se lisent par groupes de trois, ou ne se lisent pas.
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }


    static let rulesPage = URL(string: "wuji://rules")!

    @objc func showRules(_ sender: Any?) { openInternal(Self.rulesPage) }

    /// Masque — ou démasque — tout de suite, dans les documents déjà ouverts sur ce site.
    ///
    /// **La règle compilée ne vaut qu'au chargement suivant.** WebKit pose un bloqueur de
    /// contenu au moment où le document commence : la règle qu'on vient d'écrire est juste,
    /// elle est en service, et l'élément reste pourtant à l'écran jusqu'au rechargement.
    /// Demander de recharger pour voir l'effet d'un clic qu'on vient de faire est un détour
    /// qu'on n'accepterait d'aucun autre bouton — et recharger d'office ferait perdre un
    /// formulaire à moitié rempli pour cacher un encart.
    ///
    /// Ce n'est pas un second mécanisme de blocage : une feuille de style d'une ligne, posée
    /// sur ce document-ci, qui meurt avec lui. La règle compilée reste la seule chose
    /// durable, et c'est elle qui vaudra dès la prochaine visite.
    ///
    /// Tous les onglets du site, pas seulement celui de devant : la même page ouverte deux
    /// fois n'a aucune raison de se comporter de deux façons.
    func hideNow(selector: String, on host: String, hiding: Bool = true) {
        let script = hiding ? ElementPicker.hide(selector) : ElementPicker.unhide(selector)
        for tab in spaces.flatMap(\.allTabs)
        where tab.url.flatMap({ UserRules.registrable($0.host() ?? "") }) == host {
            tab.webView.evaluateJavaScript(script)
        }
    }

    /// Retire toutes les règles d'un site, et rend ce qu'elles cachaient.
    func forgetRules(of host: String) {
        let rules = userRules.rules.filter { $0.host == host }
        guard !rules.isEmpty else { return }
        userRules.removeAll(for: host)
        for rule in rules { hideNow(selector: rule.selector, on: host, hiding: false) }
        refreshBlockingPages()
        syncChrome()
        layout.toast.show(rules.count == 1 ? "Règle de « \(host) » retirée"
                                           : "Règles de « \(host) » retirées")
    }

    /// Ouvre le sélecteur sur la page courante.
    ///
    /// Il n'y a rien à ouvrir sur une page interne ou une page d'erreur : une règle y
    /// désignerait un élément de Wuji, pas du web.
    @objc func startElementPickerCommand(_ sender: Any?) { startElementPicker() }

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
            hideNow(selector: selector, on: site)
            syncChrome()
            refreshBlockingPages()
            layout.toast.show("Masqué sur « \(site) »")
        }
    }

    func handleBlockingAction(_ action: String, id: String?) {
        switch action {
        case "reload":
            loadRuleCatalog()
        case "forget-rule":
            // On lit la règle avant de la retirer : c'est elle qui dit quoi démasquer.
            guard let id, let rule = userRules.rules.first(where: { $0.id == id }) else { return }
            userRules.remove(id: id)
            hideNow(selector: rule.selector, on: rule.host, hiding: false)
            refreshBlockingPages()
            syncChrome()
        case "forget-host":
            guard let id else { return }
            forgetRules(of: id)
        case "injection-on", "injection-off":
            settings.injectedRulesEnabled = action == "injection-on"
            syncExtendedRules()
            if !settings.injectedRulesEnabled { extended.purge() }
            refreshBlockingPages()
            // Les scripts se posent à la navigation : les pages ouvertes gardent ceux
            // qu'elles ont reçus jusqu'à leur prochain chargement, et le dire vaut mieux
            // que de laisser croire que rien ne s'est passé.
            layout.toast.show(settings.injectedRulesEnabled
                ? "Règles à injection en service — rechargez pour les voir agir"
                : "Règles à injection coupées — rechargez pour les retirer") {
                    [weak self] in self?.currentTab?.webView.reload()
                }
        case "forget-orphan":
            guard let id else { return }
            blocking.remove(id)
            applyBlockingToOpenTabs()
            syncExtendedRules()
            refreshBlockingPages()
            syncChrome()
            layout.toast.show("« \(id) » retirée — règles supprimées du disque")
        case "resume":
            guard let id else { return }
            blocking.setPaused(false, host: id)
            applyBlockingToOpenTabs()
            refreshBlockingPages()
        case "install", "update":
            guard let id, let list = ruleCatalog.first(where: { $0.id == id }) else { return }
            Task { @MainActor in
                // **Mettre à jour n'est plus « retirer puis réinstaller ».** Une coupure
                // entre les deux laissait la liste décochée alors qu'on avait demandé le
                // contraire : la nouvelle version se compile d'abord, et les anciennes
                // tranches ne partent qu'une fois la nouvelle en service.
                let failure = action == "update" ? await blocking.update(list)
                                                 : await blocking.install(list)
                if let failure {
                    layout.toast.show("« \(list.name) » : \(failure)")
                } else {
                    layout.toast.show("« \(list.name) » en service — \(list.rules) règles")
                }
                applyBlockingToOpenTabs()
                syncExtendedRules()
                refreshBlockingPages()
                syncChrome()
            }
        case "update-all":
            let périmées = BlockingPage.updatable(blockingState)
            guard !périmées.isEmpty else { return }
            Task { @MainActor in
                let échecs = await blocking.updateAll(périmées)
                syncExtendedRules()
                // **Un seul repositionnement des règles, à la fin.** Reposer dix-neuf fois
                // les listes sur chaque onglet ouvert coûte plus que la mise à jour
                // elle-même, et rien de visible ne se produit entre-temps.
                applyBlockingToOpenTabs()
                refreshBlockingPages()
                syncChrome()
                layout.toast.show(échecs.isEmpty
                    ? "\(périmées.count) liste\(périmées.count > 1 ? "s" : "") à jour"
                    : "\(périmées.count - échecs.count) sur \(périmées.count) — \(échecs[0])")
            }
        case "remove":
            guard let id else { return }
            let name = ruleCatalog.first { $0.id == id }?.name ?? id
            // Les règles compilées partent du magasin avec elle : elles pèsent sur le
            // disque bien plus que le fichier téléchargé, et rien ne les jetterait plus
            // tard si on les laissait là.
            blocking.remove(id)
            applyBlockingToOpenTabs()
            syncExtendedRules()
            refreshBlockingPages()
            syncChrome()
            layout.toast.show("« \(name) » retirée — règles supprimées du disque")
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
            blocking.reapply(to: tab.webView.configuration.userContentController,
                             host: tab.url?.host())
        }
    }

    /// Repose les règles sur **un** onglet, pour l'adresse où il va.
    ///
    /// Appelé à chaque navigation : la pause vaut pour un site, et une vue qui passe d'un
    /// site en pause à un autre doit retrouver ses règles — sans quoi la pause deviendrait
    /// permanente pour cet onglet, ce que personne n'a demandé.
    func applyBlocking(to tab: Tab, for url: URL?) {
        blocking.reapply(to: tab.webView.configuration.userContentController,
                         host: url?.host())
    }
}
