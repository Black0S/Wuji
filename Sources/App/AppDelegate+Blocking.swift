import AppKit
import WebKit

/// Le blocage, les scripts de page et le journal.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - Blocage

    /// Pose sur l'onglet ce qui doit s'exécuter dans la page.
    ///
    /// Chaque onglet a son contrôleur de contenu : on peut donc remplacer ses scripts sans
    /// toucher aux autres. Il n'y a plus de scriptlets — les règles livrées ne visent que
    /// des domaines, et WebKit les applique lui-même — donc rien n'est injecté ici qui ne
    /// serve à l'application ou à l'utilisateur.
    func installPageScripts(for url: URL?, in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(PageContextMenu.script)
        controller.addUserScript(MediaWatcher.script)
        // Le mouchard du journal n'est posé que si quelqu'un regarde.
        if blockLogWindow.isOpen { controller.addUserScript(BlockLogWatcher.script) }

        // Les scripts de l'utilisateur s'appliquent même sur un site où la protection est
        // levée : ils sont à lui.
        guard settings.userScriptsEnabled else { return }
        for (script, code) in userScripts.matching(url) {
            let time: WKUserScriptInjectionTime = script.runAt == "document-start" ? .atDocumentStart
                                                                                  : .atDocumentEnd
            controller.addUserScript(WKUserScript(source: "(function(){\n" + code + "\n})();",
                                                  injectionTime: time, forMainFrameOnly: true))
        }
    }

    static let adBlockPage = URL(string: "wuji://ad-block/my-rules")!
    static let scriptsPage = URL(string: "wuji://scripts")!

    /// Ce que la page des reglages doit afficher.
    var settingsState: SettingsPage.State {
        SettingsPage.State(theme: settings.theme.rawValue,
                           searchEngine: settings.searchEngine.rawValue,
                           pageZoom: Double(settings.pageZoom),
                           retention: settings.historyRetention,
                           historyCount: history.count,
                           siteDataCount: siteDataCount,
                           blockingEnabled: settings.blockingEnabled,
                           isDefaultBrowser: isDefaultBrowser,
                           sleepDelay: settings.sleepDelay,
                           // Triés par site : la liste se lit comme un annuaire, pas comme
                           // un journal de ce qu'on a réglé en dernier.
                           siteZoom: settings.siteZoom.sorted { $0.key < $1.key }
                               .map { ($0.key, Int(($0.value * 100).rounded())) },
                           userScripts: settings.userScriptsEnabled,
                           version: UpdateCheck.current,
                           checkUpdates: settings.checkUpdatesAtLaunch,
                           agent: settings.agent.rawValue,
                           blockingSummary: blocker.state.summary,
                           permissions: permissions.decisions.map {
                               ($0.host, $0.kind.rawValue, $0.isAllowed)
                           })
    }

    static let settingsPage = URL(string: "wuji://settings")!

    @objc func openSettings(_ sender: Any?) {
        openInternal(Self.settingsPage)
    }

    func handleSettingsAction(_ action: String, payload: [String: Any]) {
        switch action {
        case "set":
            guard let key = payload["key"] as? String,
                  let value = payload["value"] as? String else { return }
            switch key {
            case "theme":      settings.theme = Settings.Theme(rawValue: value) ?? .auto
            case "engine":     settings.searchEngine = Settings.SearchEngine(rawValue: value) ?? .duckduckgo
            case "retention":  settings.historyRetention = Int(value) ?? 90
            case "zoom":       settings.pageZoom = (Double(value) ?? 100) / 100
            case "sleep":
                settings.sleepDelay = Int(value) ?? Self.defaultSleepDelay
                // Le minuteur ne sert plus à rien si l'on vient de choisir « jamais », et
                // il doit repartir si l'on vient de rallumer la veille.
                scheduleSleep()
            case "agent":      settings.agent = Settings.Agent(rawValue: value) ?? .safari
            case "blocking":
                settings.blockingEnabled = (value == "true")
                blocker.start()
            case "updates":
                settings.checkUpdatesAtLaunch = (value == "true")
            case "userscripts":
                settings.userScriptsEnabled = (value == "true")
                syncBlockingButton()
                // Les onglets ouverts portent encore les scripts posés à leur navigation :
                // éteindre la fonction sans les retirer laisserait croire qu'elle ment.
                spaces.flatMap(\.allTabs).filter { !$0.isSleeping }.forEach {
                    installPageScripts(for: $0.url, in: $0.webView)
                    $0.webView.reload()
                }
            default: break
            }
        case "make-default":
            askToBecomeDefault()
        case "check-updates":
            checkForUpdate(announcingWhenCurrent: true)
        case "clear-history":
            history.clear()
            refreshSettingsPages()
        case "clear-site-data":
            // Une confirmation, parce que c'est irréversible et que la conséquence n'est
            // pas dans le nom du bouton : on n'efface pas des fichiers, on se déconnecte.
            layout.toast.ask(title: "Effacer les données de tous les sites ?",
                             message: "Cookies, stockage local et caches. Vous serez déconnecté "
                                 + "partout. L'historique et les favoris ne sont pas touchés.",
                             confirm: "Effacer", isDestructive: true,
                             onCancel: {}) { [weak self] in self?.clearSiteData() }
        case "forget-zoom":
            guard let site = payload["site"] as? String else { return }
            settings.siteZoom.removeValue(forKey: site)
            applySettings()
            refreshSettingsPages()
        case "forget-permission":
            guard let host = payload["host"] as? String else { return }
            permissions.forget(host: host, kind: payload["kind"] as? String)
        default:
            break
        }
    }

    /// Combien de sites ont laissé des données. Relu quand on ouvre les réglages, parce
    /// qu'un chiffre affiché doit être celui d'aujourd'hui, pas celui du lancement.
    func countSiteData() {
        Task { @MainActor in
            let records = await WKWebsiteDataStore.default()
                .dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            guard siteDataCount != records.count else { return }
            siteDataCount = records.count
            refreshSettingsPages()
        }
    }

    /// Efface tout ce que les sites ont laissé, sur toute la durée.
    ///
    /// Les espaces privés n'ont rien à effacer ici : leur magasin est éphémère et vit en
    /// mémoire. C'est le magasin persistant — celui des espaces ordinaires — qu'on vide.
    func clearSiteData() {
        Task { @MainActor in
            let store = WKWebsiteDataStore.default()
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                   modifiedSince: .distantPast)
            siteDataCount = 0
            refreshSettingsPages()
            layout.toast.show("Données de sites effacées")
        }
    }

    /// Demande la dernière version publiée, et dit ce qu'elle vaut.
    ///
    /// **Le silence n'est pas une réponse acceptable quand on a cliqué.** Une vérification
    /// demandée qui ne dit rien laisse croire à une fonction cassée ; une vérification faite
    /// au lancement, elle, ne parle que si elle a quelque chose à annoncer.
    func checkForUpdate(announcingWhenCurrent: Bool) {
        Task { @MainActor in
            guard let dernière = await UpdateCheck.latest() else {
                if announcingWhenCurrent { layout.toast.show("Vérification impossible") }
                return
            }
            if UpdateCheck.isNewer(dernière.version, than: UpdateCheck.current) {
                layout.toast.show("Wuji \(dernière.version) est disponible") { [weak self] in
                    self?.openInNewTab(dernière.page, activate: true)
                }
            } else if announcingWhenCurrent {
                layout.toast.show("Version \(UpdateCheck.current) — c'est la dernière")
            }
        }
    }

    func refreshSettingsPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "settings" }
            .forEach { $0.webView.reload() }
    }

    @objc func showScripts(_ sender: Any?) {
        openInternal(Self.scriptsPage)
    }

    /// Ouvre le journal. **Il part de maintenant, et ne recharge rien.**
    ///
    /// Il rechargeait toutes les pages ouvertes pour y poser son mouchard, et remplissait
    /// donc sa première fenêtre en cassant ce que l'on regardait — une vidéo relancée, un
    /// formulaire vidé. Un journal est un témoin : il note ce qui se passe pendant qu'il
    /// est ouvert, pas ce qu'il aurait fallu provoquer pour avoir quelque chose à montrer.
    @objc func showBlockLog(_ sender: Any?) {
        // Bloquer un domaine depuis le journal : c'est là qu'on voit ce qui manque aux
        // listes, et la règle s'écrit au même format que tout le reste.
        blockLogWindow.onBlockDomain = { [weak self] domain in
            guard let self else { return }
            if self.blocker.addUserRule(WebKitRule.block(domain: domain)) {
                self.layout.toast.show("\(domain) bloqué") { [weak self] in
                    self?.openInternal(Self.adBlockPage)
                }
            } else {
                self.layout.toast.show("\(domain) était déjà dans vos règles")
            }
        }
        blockLogWindow.show()
        // Les pages déjà ouvertes recevront le mouchard à leur prochaine navigation ; les
        // nouvelles l'ont tout de suite.
    }

    func refreshScriptsPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "scripts" }
            .forEach { $0.webView.reload() }
    }

    /// Télécharge un script et l'installe, après accord.
    ///
    /// Un script utilisateur s'exécute avec les pouvoirs de la page : l'installer sans le
    /// demander serait exécuter du code tiers sur simple visite d'une adresse.
    func installScript(from url: URL) {
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let text = String(data: data, encoding: .utf8) else {
                // L'échec était muet : on cliquait sur une adresse en `.user.js`, et il ne
                // se passait plus jamais rien. Un refus qu'on ne voit pas ressemble à une
                // fonction cassée.
                self?.layout.toast.show(url.scheme == "http"
                    ? "Adresse non chiffrée : un script ne s'installe pas ainsi"
                    : "Téléchargement impossible")
                return
            }
            guard let self else { return }
            let preview = UserScript(text: text, source: url)
            self.layout.toast.ask(
                title: "Installer « \(preview.name) » ?",
                message: "Ce script s'exécutera sur : \(preview.patterns.prefix(3).joined(separator: ", ")). Il aura les mêmes pouvoirs que ces pages.",
                confirm: "Installer", isDestructive: false, onCancel: {}) { [weak self] in
                    self?.userScripts.add(text: text, source: url)
                    self?.layout.toast.show("Script installé") { self?.showScripts(nil) }
                    self?.refreshScriptsPages()
                }
        }
    }

    func handleScriptAction(_ action: String, payload: [String: Any]) {
        switch action {
        case "install":
            guard let raw = payload["url"] as? String, let url = URL(string: raw),
                  url.scheme == "https" || url.scheme == "http" else { return }
            installScript(from: url)
        case "enable":
            guard let value = payload["value"] as? Bool else { return }
            userScripts.setEnabled(value, id: payload["id"] as? String)
        case "update":
            // On retélécharge à la même adresse : c'est le script lui-même qui dit sa
            // version, et son en-tête sera relu comme à l'installation.
            guard let id = payload["id"] as? String,
                  let script = userScripts.scripts.first(where: { $0.id.uuidString == id }),
                  let source = script.source else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: source),
                      let text = String(data: data, encoding: .utf8) else {
                    self?.layout.toast.show("Mise à jour impossible")
                    return
                }
                let updated = self?.userScripts.add(text: text, source: source)
                self?.layout.toast.show(updated.map {
                    $0.version.isEmpty ? "« \($0.name) » mis à jour"
                                       : "« \($0.name) » en v\($0.version)"
                } ?? "Mise à jour impossible")
                self?.refreshScriptsPages()
            }
        case "remove":
            userScripts.remove(id: payload["id"] as? String)
        default:
            break
        }
    }

    @objc func showAdBlock(_ sender: Any?) {
        openInternal(Self.adBlockPage)
    }

    /// Ce que le bouclier de la barre doit montrer.
    ///
    /// Le bloqueur prévient dès qu'il change d'état, y compris avant que la session soit
    /// restaurée : d'où les gardes. Sans elles, la compilation qui se termine pendant le
    /// démarrage va chercher un onglet courant dans une liste d'espaces encore vide.
    var blockingBadge: ContentTopBar.Blocking {
        guard settings.blockingEnabled else { return .off }
        guard !spaces.isEmpty else { return .active }
        return blocker.isExcepted(currentTab?.url) ? .excepted : .active
    }

    func syncBlockingButton() {
        guard layout != nil else { return }
        layout.topBar.setBlocking(blockingBadge)
        layout.topBar.setScripts(
            installed: settings.userScriptsEnabled && !userScripts.scripts.isEmpty,
            activeHere: settings.userScriptsEnabled && !userScripts.matching(currentTab?.url).isEmpty)
    }

    /// Le menu des scripts.
    ///
    /// Il dit d'abord ce qui tourne **ici**, puis laisse allumer et éteindre chaque script
    /// sans passer par une page : c'est le geste qu'on fait quand un script casse le site
    /// qu'on est en train de lire, et il ne doit pas coûter une navigation.
    func scriptsMenu() -> [ActionItem] {
        var items: [ActionItem] = []
        let here = Set(userScripts.matching(currentTab?.url).map(\.0.id))

        items.append(ActionItem(title: here.isEmpty
                                    ? "Aucun script sur cette page"
                                    : "\(here.count) script\(here.count > 1 ? "s" : "") sur cette page",
                                symbol: "curlybraces", isEnabled: false))
        items.append(.separator)

        // Ceux qui s'appliquent ici d'abord : c'est la page ouverte qui motive l'ouverture
        // du menu, pas l'inventaire.
        let ordered = userScripts.scripts.sorted { first, second in
            here.contains(first.id) != here.contains(second.id) ? here.contains(first.id) : false
        }
        for script in ordered {
            // La coche dit l'état, et l'action le renverse. Un rond vide plutôt qu'une
            // absence de glyphe : sans forme, une ligne éteinte n'est qu'un texte, et on
            // ne sait plus si la liste est cochable.
            items.append(ActionItem(title: script.name,
                                    symbol: script.isEnabled ? "checkmark.circle.fill" : "circle",
                                    action: { [weak self] in
                                        guard let self else { return }
                                        userScripts.setEnabled(!script.isEnabled, id: script.id.uuidString)
                                        currentTab?.webView.reload()
                                        refreshScriptsPages()
                                        syncBlockingButton()
                                    }))
        }

        items.append(.separator)
        items.append(ActionItem(title: "Gérer les scripts…", symbol: "list.bullet",
                                action: { [weak self] in self?.showScripts(nil) }))
        return items
    }

    func refreshAdBlockPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "ad-block" }
            .forEach { $0.webView.reload() }
    }

    /// Le menu du bouclier.
    ///
    /// Il répond d'abord à « que se passe-t-il **ici** » — l'état du site ouvert et ce que
    /// les règles y font — avant d'offrir les outils. Une feuille qui commence par ses
    /// réglages oblige à chercher l'information à chaque fois.
    func blockingMenu() -> [ActionItem] {
        var items: [ActionItem] = []
        let url = currentTab.flatMap(favoritableURL(of:))

        if let url, let host = url.host() {
            let excepted = blocker.isExcepted(url)

            // L'état du site, en une ligne qu'on lit sans cliquer.
            items.append(ActionItem(title: excepted ? "Protection levée sur \(host)"
                                                    : "Protection active sur \(host)",
                                    symbol: excepted ? "shield.slash" : "shield.lefthalf.filled",
                                    isEnabled: false))
            items.append(.separator)

            items.append(ActionItem(title: excepted ? "Réactiver sur ce site" : "Désactiver sur ce site",
                                    symbol: excepted ? "shield" : "shield.slash",
                                    action: { [weak self] in self?.toggleBlocking(for: url) }))
            if !excepted {
                items.append(ActionItem(title: "Bloquer un élément…", symbol: "scope",
                                        action: { [weak self] in self?.pickElement() }))
            }
            items.append(.separator)
        }

        items.append(ActionItem(title: blocker.state.summary, symbol: "info.circle", isEnabled: false))
        items.append(ActionItem(title: "Mes règles…", symbol: "pencil",
                                action: { [weak self] in self?.showAdBlock(nil) }))
        items.append(ActionItem(title: "Journal de blocage…", symbol: "text.line.first.and.arrowtriangle.forward",
                                action: { [weak self] in self?.showBlockLog(nil) }))
        return items
    }

    /// Arme le sélecteur d'élément sur la page courante.
    func pickElement() {
        currentTab?.webView.evaluateJavaScript(ElementPicker.script)
    }

    /// La règle produite par le sélecteur, rangée avec le domaine où on l'a prise.
    ///
    /// Le domaine est indispensable : `##.promo` sans domaine masquerait les promos de tout
    /// le web. Une règle écrite en un clic doit rester bornée à l'endroit où on l'a écrite.
    func addPickedRule(_ selector: String) {
        guard let host = currentTab?.url?.host(), !selector.isEmpty else { return }
        blocker.addUserRule(WebKitRule.hide(selector: selector, on: host))
        // L'élément disparaît tout de suite, sans attendre la compilation : on vient de le
        // désigner, le voir survivre quelques secondes ferait douter du clic. La règle,
        // elle, prendra le relais au prochain chargement.
        let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        currentTab?.webView.evaluateJavaScript(
            "document.querySelectorAll('\(escaped)').forEach(n => n.style.setProperty('display','none','important'))")
        layout.toast.show("Élément masqué sur \(host)") { [weak self] in self?.showAdBlock(nil) }
    }

    func handleAdBlockAction(_ action: String, payload: [String: Any]) {
        switch action {
        // Une liste du catalogue. Le geste porte le nom qu'il portait déjà du temps où la
        // page servait un catalogue téléchargé — le vocabulaire de la page n'a pas changé,
        // c'est ce qu'il désigne qui a changé.
        case "enable":
            guard let id = payload["id"] as? String,
                  let value = payload["value"] as? Bool else { return }
            settings.setRuleList(id, enabled: value)
            // Recompiler et non recharger : la liste éteinte quitte le moteur et le
            // magasin, elle n'y reste pas neutralisée. Les pages ouvertes gardent les
            // règles posées à leur chargement — recharger d'office ce que quelqu'un est en
            // train de lire serait l'automatisme dont on ne veut pas.
            blocker.compile()
        case "unexcept":
            guard let host = payload["host"] as? String else { return }
            settings.blockingExceptions.removeAll { $0 == host }
            blocker.compile()
        case "rule":
            guard let rule = payload["rule"] as? String else { return }
            // Le refus se voit. Il était muet : on tapait une règle, le champ se vidait,
            // et rien n'apparaissait — on ne pouvait pas savoir si elle était en train de
            // se compiler ou si elle avait été jetée.
            if !blocker.addUserRule(rule) {
                layout.toast.show("Règle refusée : ce n'est pas une règle WebKit valide")
            }
        case "edit":
            guard let rule = payload["rule"] as? String,
                  let replacement = payload["replacement"] as? String else { return }
            if !blocker.replaceUserRule(rule, with: replacement) {
                layout.toast.show("Règle refusée : la précédente est conservée")
            }
        case "unrule":
            guard let rule = payload["rule"] as? String else { return }
            blocker.removeUserRule(rule)
        default:
            break
        }
    }

    /// Éteindre ou rallumer la protection sur un site, puis recharger.
    ///
    /// Le rechargement n'est pas une politesse : les règles de contenu s'appliquent au
    /// moment où la requête part. Sans lui, la page reste exactement telle qu'elle était
    /// et on croit que le réglage n'a rien fait.
    func toggleBlocking(for url: URL) {
        reloadAfterBlocking = true
        blocker.toggleException(for: url)
        let host = url.host() ?? ""
        layout.toast.show(blocker.isExcepted(url)
                          ? "Protection désactivée sur \(host)"
                          : "Protection réactivée sur \(host)")
    }

}
