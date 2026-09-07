import AppKit
import WebKit

/// Les réglages, les scripts de page et les mises à jour.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - Scripts de page

    /// Pose sur l'onglet ce qui doit s'exécuter dans la page.
    ///
    /// Chaque onglet a son contrôleur de contenu : on peut donc remplacer ses scripts sans
    /// toucher aux autres. Rien n'est injecté ici qui ne serve à l'application ou à
    /// l'utilisateur.
    func installPageScripts(for url: URL?, in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(PageContextMenu.script)
        controller.addUserScript(MediaWatcher.script)
        controller.addUserScript(RouteWatcher.script)
        if settings.passwordsEnabled { controller.addUserScript(PasswordForm.script) }
        // Les règles à injection viennent avec les scripts de l'application : elles doivent
        // être en place avant le premier octet du document, sinon le site a déjà lu la
        // propriété qu'on voulait remplacer.
        installInjectedRules(for: url, in: controller)

        // Le document qui arrive recevra ses scripts par WebKit lui-même : on note pour
        // quelle adresse, afin que le guetteur ne les rejoue pas dans la foulée.
        if let tab = tab(for: webView) {
            tab.scriptedURL = url
        }

        guard settings.userScriptsEnabled else { return }
        for (script, code) in userScripts.matching(url) {
            let time: WKUserScriptInjectionTime = script.runAt == "document-start" ? .atDocumentStart
                                                                                  : .atDocumentEnd
            controller.addUserScript(WKUserScript(source: Self.wrap(code),
                                                  injectionTime: time, forMainFrameOnly: true))
        }
    }

    /// Le code d'un script utilisateur, enfermé dans sa propre portée.
    ///
    /// Sans cette enveloppe, deux scripts qui déclarent tous deux `const config` se
    /// cassent l'un l'autre — et le second échoue en silence, ce qui donne un script qui
    /// « ne marche pas » sans rien à lire nulle part.
    static func wrap(_ code: String) -> String {
        "(function(){\n" + code + "\n})();"
    }

    /// Rejoue les scripts de l'utilisateur quand la page a changé d'adresse **sans changer
    /// de document** — voir `RouteWatcher`.
    ///
    /// L'injection passe par `evaluateJavaScript` et non par un `WKUserScript` : le
    /// document existe déjà, et un script d'utilisateur posé maintenant n'y entrerait qu'au
    /// prochain chargement, c'est-à-dire jamais.
    func replayUserScripts(in webView: WKWebView) {
        guard let tab = tab(for: webView),
              let url = webView.url, tab.scriptedURL != url else { return }
        tab.scriptedURL = url
        // Le bouton des scripts dit ce qui tourne **ici** : la page a changé, sa réponse
        // aussi, alors même qu'aucune navigation n'a eu lieu.
        syncToolbarButtons()

        guard settings.userScriptsEnabled else { return }
        for (_, code) in userScripts.matching(url) {
            webView.evaluateJavaScript(Self.wrap(code))
        }
    }

    static let scriptsPage = URL(string: "wuji://scripts")!

    /// Ce que la page des reglages doit afficher.
    var settingsState: SettingsPage.State {
        SettingsPage.State(theme: settings.theme.rawValue,
                           searchEngine: settings.searchEngine.rawValue,
                           pageZoom: Double(settings.pageZoom),
                           retention: settings.historyRetention,
                           historyCount: history.count,
                           siteDataCount: siteDataCount,
                           siteData: siteDataRecords.map {
                               ($0.displayName, AppDelegate.kinds(of: $0))
                           },
                           isDefaultBrowser: isDefaultBrowser,
                           // Triés par site : la liste se lit comme un annuaire, pas comme
                           // un journal de ce qu'on a réglé en dernier.
                           siteZoom: settings.siteZoom.sorted { $0.key < $1.key }
                               .map { ($0.key, Int(($0.value * 100).rounded())) },
                           version: UpdateCheck.current,
                           checkUpdates: settings.checkUpdatesAtLaunch,
                           agent: settings.agent.rawValue,
                           permissions: permissions.decisions.map {
                               ($0.host, $0.kind.rawValue, $0.isAllowed)
                           },
                           logins: Vault.all().map { ($0.host, $0.user) },
                           passwordsEnabled: settings.passwordsEnabled,
                           vaultExists: Vault.exists,
                           vaultUnlocked: Vault.isUnlocked,
                           biometryAvailable: Biometrics.isAvailable,
                           biometryEnabled: Biometrics.isEnabled,
                           biometrySealed: Biometrics.protection == .secureEnclave,
                           biometryName: Biometrics.name)
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
            case "agent":      settings.agent = Settings.Agent(rawValue: value) ?? .safari
            case "biometry":
                setBiometricUnlock(value == "true")
            case "passwords":
                settings.passwordsEnabled = (value == "true")
                // Les onglets ouverts portent encore le script posé à leur navigation :
                // éteindre la fonction sans le retirer laisserait croire qu'elle ment.
                spaces.flatMap(\.allTabs).forEach { installPageScripts(for: $0.url, in: $0.webView) }
            case "updates":
                settings.checkUpdatesAtLaunch = (value == "true")
            case "userscripts":
                settings.userScriptsEnabled = (value == "true")
                syncToolbarButtons()
                // Les onglets ouverts portent encore les scripts posés à leur navigation :
                // éteindre la fonction sans les retirer laisserait croire qu'elle ment.
                spaces.flatMap(\.allTabs).forEach {
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
        case "forget-site-data":
            guard let host = payload["host"] as? String else { return }
            forgetSiteData(host: host)
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
                .sorted { $0.displayName < $1.displayName }
            guard siteDataCount != records.count
                || siteDataRecords.map(\.displayName) != records.map(\.displayName) else {
                return
            }
            siteDataCount = records.count
            siteDataRecords = records
            refreshSettingsPages()
        }
    }

    /// Ce qu'un site a laissé, en toutes lettres.
    ///
    /// **Les constantes de WebKit ne se lisent pas** : `WKWebsiteDataTypeLocalStorage` dit
    /// quelque chose à qui écrit du code et rien à qui veut savoir ce qu'il efface. Les
    /// trois qui comptent vraiment — cookies, stockage, cache — sont nommées ; le reste est
    /// compté, parce qu'énumérer huit familles de bases de données dans une ligne de liste
    /// la rend illisible sans rien apprendre.
    static func kinds(of record: WKWebsiteDataRecord) -> String {
        var parts: [String] = []
        if record.dataTypes.contains(WKWebsiteDataTypeCookies) { parts.append("cookies") }
        if !record.dataTypes.isDisjoint(with: [WKWebsiteDataTypeLocalStorage,
                                               WKWebsiteDataTypeSessionStorage]) {
            parts.append("stockage")
        }
        if !record.dataTypes.isDisjoint(with: [WKWebsiteDataTypeDiskCache,
                                               WKWebsiteDataTypeMemoryCache,
                                               WKWebsiteDataTypeOfflineWebApplicationCache]) {
            parts.append("cache")
        }
        let rest = record.dataTypes.count - record.dataTypes.intersection([
            WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache
        ]).count
        if rest > 0 { parts.append("+\(rest)") }
        return parts.isEmpty ? "données" : parts.joined(separator: " · ")
    }

    /// Efface ce qu'**un** site a laissé.
    ///
    /// **Sans confirmation, et c'est voulu.** Effacer tout déconnecte partout : la question
    /// s'y justifie. Effacer un site déconnecte de ce site-là, ce que le bouton dit déjà par
    /// son nom et sa ligne — demander confirmation pour chaque site transformerait un
    /// ménage en interrogatoire, et apprendrait à répondre oui sans lire.
    ///
    /// L'enregistrement est repris dans la liste plutôt que reconstruit : WebKit efface
    /// pour un objet qu'il a rendu, pas pour un nom de domaine qu'on lui donne. C'est aussi
    /// ce qui garantit qu'on efface exactement ce que la ligne annonçait.
    func forgetSiteData(host: String) {
        guard let record = siteDataRecords.first(where: { $0.displayName == host }) else {
            return
        }
        Task { @MainActor in
            await WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes,
                                                          for: [record])
            siteDataRecords.removeAll { $0.displayName == host }
            siteDataCount = siteDataRecords.count
            refreshSettingsPages()
            layout.toast.show("Données de « \(host) » effacées")
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
            siteDataRecords = []
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

    func refreshScriptsPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "scripts" }
            .forEach { $0.webView.reload() }
    }

    /// Télécharge un script et l'installe, après accord.
    ///
    /// Un script utilisateur s'exécute avec les pouvoirs de la page : l'installer sans le
    /// demander serait exécuter du code tiers sur simple visite d'une adresse.
    /// `requiringHeader` : ne rien proposer si le fichier ne porte pas d'en-tête de script.
    ///
    /// **Vrai quand c'est Wuji qui a deviné, faux quand c'est vous qui avez demandé.** Une
    /// page de texte en `.js` peut n'être qu'un fichier JavaScript ordinaire ; proposer de
    /// l'installer à chaque fois apprendrait à répondre non sans lire. Une adresse en
    /// `.user.js`, ou collée à la main, est une demande explicite — on ne la refuse pas
    /// parce que l'en-tête manque, on la montre.
    func installScript(from url: URL, requiringHeader: Bool = false) {
        Task { [weak self] in
            guard let (data, _) = try? await Fetch.data(from: url),
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
            // L'en-tête se trouve toujours en tête de fichier : le chercher plus loin
            // ferait prendre un script qui *parle* de scripts pour l'un d'eux.
            let head = String(text.prefix(8192))
            if requiringHeader,
               !(head.contains("==UserScript==") && head.contains("==/UserScript==")) {
                return
            }
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
        case "master":
            // L'interrupteur général vit maintenant sur la page des scripts : c'est là
            // qu'on regarde quand rien ne s'exécute.
            guard let value = payload["value"] as? Bool else { return }
            settings.userScriptsEnabled = value
            syncChrome()
            refreshScriptsPages()
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
                guard let (data, _) = try? await Fetch.data(from: source),
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

    /// Ce que la barre du haut doit montrer à droite : le blocage et les scripts.
    func syncToolbarButtons() {
        guard layout != nil else { return }
        layout.topBar.setBlocking(active: true)
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
                                        syncToolbarButtons()
                                    }))
        }

        items.append(.separator)
        items.append(ActionItem(title: "Gérer les scripts…", symbol: "list.bullet",
                                action: { [weak self] in self?.showScripts(nil) }))
        return items
    }
}
