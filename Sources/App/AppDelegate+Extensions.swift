import AppKit
import WebKit

/// Les extensions : leur page, leur bouton, et ce que WebKit vient nous demander.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    static let extensionsPage = URL(string: "wuji://extensions")!

    @objc func showExtensions(_ sender: Any?) {
        // Le disque a pu changer depuis le dernier passage — une extension installée
        // pendant que Wuji tournait doit apparaître sans qu'on relance l'application.
        extensions.rescan()
        openInternal(Self.extensionsPage)
    }

    func refreshExtensionPages() {
        spaces.flatMap(\.allTabs)
            .filter { $0.url?.host() == "extensions" }
            .forEach { $0.webView.reload() }
    }

    // MARK: - Le bouton et les épinglées

    /// Ce que le bouton de la barre ouvre.
    ///
    /// Il ne liste que les extensions **non épinglées** : celles qui le sont ont déjà leur
    /// icône dans la barre, et deux chemins vers la même action, c'est un élément à
    /// l'écran pour rien. Chaque ligne porte l'icône et l'étiquette que l'extension donne
    /// pour l'onglet courant — c'est là qu'elle annonce son état, par un mot qui change
    /// selon la page.
    func extensionsMenu() -> [ActionItem] {
        var items = extensions.unpinned
            .sorted { name(of: $0) < name(of: $1) }
            .map { entry(for: $0, pinnable: true) }

        if !items.isEmpty { items.append(.separator) }
        items.append(ActionItem(title: "Gérer les extensions…", symbol: "puzzlepiece",
                                action: { [weak self] in self?.showExtensions(nil) }))
        return items
    }

    /// Le clic droit sur une icône épinglée : ce qu'elle propose au-delà de son action.
    func pinnedMenu(for id: String) -> [ActionItem] {
        guard let context = extensions.contexts[id] else { return [] }
        var items = [entry(for: context, pinnable: false)]
        items.append(ActionItem(title: "Retirer de la barre", symbol: "pin.slash",
                                action: { [weak self] in
                                    self?.extensions.setPinned(false, id: id)
                                }))
        if context.optionsPageURL != nil {
            items.append(ActionItem(title: "Réglages de l'extension…", symbol: "gearshape",
                                    action: { [weak self] in
                                        guard let url = context.optionsPageURL else { return }
                                        self?.openInNewTab(url, activate: true)
                                    }))
        }
        items.append(.separator)
        items.append(ActionItem(title: "Gérer les extensions…", symbol: "puzzlepiece",
                                action: { [weak self] in self?.showExtensions(nil) }))
        return items
    }

    /// Une extension, en ligne de menu : son icône, son étiquette, sa pastille.
    private func entry(for context: WKWebExtensionContext, pinnable: Bool) -> ActionItem {
        let action = context.action(for: currentTab)
        // La pastille entre dans le libellé : c'est l'endroit exact où elle s'affiche
        // ailleurs, et un compteur qu'on ne voit qu'en ouvrant le menu ne compte pour
        // personne.
        let badge = action.map(\.badgeText).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        let id = context.uniqueIdentifier

        var item = ActionItem(title: name(of: context) + badge,
                              image: icon(of: context),
                              isEnabled: action?.isEnabled ?? true,
                              action: { [weak self] in self?.perform(context) })
        // L'épinglage vit dans un sous-menu plutôt que sur la ligne : cliquer la ligne
        // doit lancer l'extension, c'est ce qu'on vient faire. Le sous-menu ne s'ouvre
        // qu'en s'y attardant.
        if pinnable {
            item.children = [
                ActionItem(title: name(of: context), image: icon(of: context),
                           action: { [weak self] in self?.perform(context) }),
                .separator,
                ActionItem(title: "Épingler dans la barre", symbol: "pin",
                           action: { [weak self] in self?.extensions.setPinned(true, id: id) })
            ]
        }
        return item
    }

    /// Le nom d'une extension, tel qu'il doit s'afficher pour la page ouverte.
    private func name(of context: WKWebExtensionContext) -> String {
        let label = context.action(for: currentTab)?.label ?? ""
        if !label.isEmpty { return label }
        return context.webExtension.displayName ?? "Extension"
    }

    /// L'icône d'action pour l'onglet courant, avec le repli sur celle du manifeste : une
    /// extension qui n'a pas d'icône propre pour cette page en a toujours une par défaut.
    private func icon(of context: WKWebExtensionContext) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        return context.action(for: currentTab)?.icon(for: size)
            ?? context.webExtension.actionIcon(for: size)
    }

    // MARK: - Ce que les extensions doivent savoir

    /// **Une extension ne voit que ce qu'on lui raconte.**
    ///
    /// Les délégués `openWindowsFor` et `focusedWindowFor` répondent quand WebKit demande ;
    /// ils ne réveillent personne. `browser.tabs.onCreated`, `onActivated`, `onUpdated` et
    /// `onRemoved` sont des **événements** — sans ces appels, ils ne se déclenchent jamais.
    ///
    /// La conséquence n'est pas théorique : un bloqueur met à jour sa pastille sur
    /// `onUpdated`, et décide du mode de filtrage d'un site à `onActivated`. Sans ces
    /// signaux il tourne à moitié — il bloque, mais il ne sait pas où il est, et tout ce
    /// qui vise « la page courante » vise le vide.
    ///
    /// Ces méthodes n'ont pas de garde sur les extensions chargées : le contrôleur ne fait
    /// rien quand il n'en a aucune, et une garde de plus serait une occasion d'oublier un
    /// appel.
    func extensionsDidOpen(_ tab: Tab) {
        extensions.controller.didOpenTab(tab)
    }

    func extensionsDidClose(_ tab: Tab) {
        extensions.controller.didCloseTab(tab, windowIsClosing: false)
    }

    func extensionsDidActivate(_ tab: Tab, previous: Tab?) {
        guard tab !== previous else { return }
        extensions.controller.didActivateTab(tab, previousActiveTab: previous)
    }

    /// Ce qui a changé dans un onglet — adresse, titre, chargement, son.
    ///
    /// Le drapeau compte : `onUpdated` porte ce qui a bougé, et une extension qui reçoit
    /// « tout a changé » à chaque frappe refait à chaque fois le travail de la page entière.
    func extensionsDidChange(_ properties: WKWebExtension.TabChangedProperties, in tab: Tab) {
        guard !properties.isEmpty else { return }
        extensions.controller.didChangeTabProperties(properties, for: tab)
    }

    /// La configuration qu'une page d'extension exige, ou `nil` si l'adresse n'en est pas une.
    ///
    /// **Une page en `webkit-extension://` ne se charge pas dans n'importe quelle vue.**
    /// Elle a besoin de celle que son contexte fabrique : c'est par là que passent ses API
    /// `browser.*` et l'origine sous laquelle WebKit accepte de la servir. Dans une vue
    /// ordinaire elle reste muette — mesuré : la vue n'annonce même pas d'adresse, l'onglet
    /// se croit vierge et la colonne le retire. On voyait « rien ne s'est passé » là où le
    /// navigateur avait fait presque tout le chemin.
    ///
    /// C'est le chemin de l'engrenage d'uBlock Origin Lite, du lien « Preferences » d'une
    /// autre, et de tout `browser.tabs.create` visant une page de l'extension elle-même.
    func extensionConfiguration(for url: URL?) -> WKWebViewConfiguration? {
        guard let url else { return nil }
        return extensions.controller.extensionContext(for: url)?.webViewConfiguration
    }

    /// Cette adresse appartient-elle à une extension ?
    ///
    /// Deux chemins, et le second compte : le contrôleur répond tant que l'extension est
    /// chargée, le schéma répond encore après. C'est l'ordre dans lequel la question se
    /// pose quand on range une session au moment où l'on quitte.
    func isExtensionPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        if extensions.controller.extensionContext(for: url) != nil { return true }
        return url.scheme?.hasSuffix("-extension") ?? false
    }

    /// Le nom de l'extension à qui appartient cette adresse, s'il y en a une.
    func extensionName(for url: URL?) -> String? {
        guard let url,
              let context = extensions.controller.extensionContext(for: url) else { return nil }
        return context.webExtension.displayName
    }

    /// Ce qui, dans la barre, a pu changer — **sans toucher aux icônes**.
    ///
    /// L'étiquette et la pastille sont des chaînes que le contexte tient déjà ; l'icône,
    /// elle, se décode. L'adresse en fait partie parce qu'une extension change d'icône
    /// selon le site sans changer d'étiquette.
    var pinSignature: String {
        let here = currentTab?.url?.absoluteString ?? ""
        return extensions.pinned.reduce(into: here) { signature, context in
            let action = context.action(for: currentTab)
            signature += "|\(context.uniqueIdentifier)~\(action?.label ?? "")~\(action?.badgeText ?? "")"
        }
    }

    /// Ce que la barre doit porter : une icône par extension épinglée et chargée.
    var pins: [ContentTopBar.Pin] {
        extensions.pinned.map { context in
            ContentTopBar.Pin(id: context.uniqueIdentifier,
                              label: name(of: context),
                              icon: icon(of: context),
                              badge: context.action(for: currentTab)?.badgeText ?? "")
        }
    }

    /// Déclenche l'action d'une extension pour l'onglet courant.
    ///
    /// Le geste est signalé à WebKit avant : c'est lui qui ouvre la permission `activeTab`,
    /// et sans ce signal une extension qui n'a demandé aucun hôte ne verrait rien de la
    /// page — elle paraîtrait cassée alors qu'elle attend qu'on lui dise « ici ».
    func perform(_ context: WKWebExtensionContext) {
        if let tab = currentTab {
            context.userGesturePerformed(in: tab)
            context.performAction(for: tab)
        } else {
            context.performAction(for: nil)
        }
    }

    // MARK: - La page

    func handleExtensionAction(_ action: String, payload: [String: Any]) {
        switch action {
        case "enable":
            guard let id = payload["id"] as? String,
                  let value = payload["value"] as? Bool else { return }
            if value {
                askBeforeEnabling(id)
            } else {
                extensions.setEnabled(false, id: id)
                refreshExtensionPages()
            }
        case "pin":
            guard let id = payload["id"] as? String,
                  let value = payload["value"] as? Bool else { return }
            extensions.setPinned(value, id: id)
            refreshExtensionPages()
        case "remove":
            guard let id = payload["id"] as? String else { return }
            extensions.remove(id: id)
            refreshExtensionPages()
        case "add":
            chooseExtension()
        default:
            break
        }
    }

    /// Demande avant d'activer, et **dit ce qu'on accorde**.
    ///
    /// Le manifeste est lu ici, avant tout chargement : une extension activée reçoit les
    /// hôtes qu'elle déclare, et cette liste est la seule information qui compte. La cocher
    /// sans la voir reviendrait à donner la lecture et l'écriture de pages entières sur un
    /// clic dans une case.
    func askBeforeEnabling(_ id: String) {
        Task { @MainActor in
            guard let entry = extensions.installed.first(where: { $0.id == id }) else { return }
            guard let asked = await extensions.requested(id: id) else {
                layout.toast.show("Extension illisible : son manifeste a été refusé")
                refreshExtensionPages()
                return
            }
            let hosts = asked.hosts.isEmpty
                ? "Elle ne demande aucun site."
                : "Elle pourra lire et modifier : " + asked.hosts.prefix(6).joined(separator: ", ")
                    + (asked.hosts.count > 6 ? "…" : "")
            let powers = asked.permissions.isEmpty
                ? ""
                : " Pouvoirs demandés : " + asked.permissions.joined(separator: ", ") + "."

            layout.toast.ask(
                title: "Activer « \(entry.name) » ?",
                message: hosts + powers,
                confirm: "Activer", isDestructive: false,
                onCancel: { [weak self] in self?.refreshExtensionPages() }) { [weak self] in
                    self?.extensions.setEnabled(true, id: id)
                    self?.refreshExtensionPages()
                }
        }
    }

    /// **On va chercher l'extension, elle ne se propose pas.**
    ///
    /// Le panneau accepte une **application** — c'est sous cette forme qu'une extension
    /// Safari existe, un `.appex` rangé dans son paquet —, et aussi un dossier décompressé
    /// pour ce qu'on écrit soi-même ou ce qu'on a tiré d'ailleurs. Demander laquelle des
    /// trois formes on apporte serait demander de savoir ; Wuji regarde et le dit.
    ///
    /// `treatsFilePackagesAsDirectories` reste à `false` : sans quoi le sélecteur entrerait
    /// *dans* l'application au clic, et il faudrait aller chercher soi-même le `.appex` au
    /// fond de `Contents/PlugIns`.
    func chooseExtension() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ajouter"
        panel.message = "Choisissez l'application qui porte l'extension — ou le dossier "
            + "d'une extension décompressée."

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let found = extensions.add(source: url)
            guard !found.usable.isEmpty else {
                // Le cas le plus fréquent, et il mérite d'être nommé : beaucoup
                // d'applications de l'App Store portent une extension Safari **native**, du
                // code compilé que WebKit ne sait pas charger hors de Safari. On dit
                // laquelle et pourquoi — « il ne s'est rien passé » n'apprend rien à
                // quelqu'un qui vient de désigner l'application qu'il fallait.
                let app = url.deletingPathExtension().lastPathComponent
                let refused = found.rejected
                    .map { "« \($0.name) » \($0.explanation)" }
                    .joined(separator: " ; ")
                layout.toast.show(refused.isEmpty
                    ? "« \(app) » ne porte pas d'extension web"
                    : "« \(app) » ne porte pas d'extension web : \(refused)")
                return
            }
            // Une application se découpe couramment en plusieurs morceaux dont un seul est
            // du web — Noir livre « Noir for Web Apps » et « Noir », et Safari les montre
            // tous les deux. Ce qui est pris est nommé, ce qui est laissé aussi : sans la
            // seconde moitié, on cherche dans la liste une ligne qui n'y sera jamais.
            let added = found.usable.count == 1
                ? "« \(found.usable[0].name) » ajoutée — à activer dans la liste"
                : "\(found.usable.count) extensions ajoutées — à activer dans la liste"
            let aside = found.rejected.isEmpty ? "" : " · non prise\(found.rejected.count > 1 ? "s" : "") : "
                + found.rejected.map { "« \($0.name) » (\($0.shortReason))" }
                    .joined(separator: ", ")
            layout.toast.show(added + aside)
            showExtensions(nil)
        }

        guard let window else { return handle(panel.runModal()) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { handle(response) }
        }
    }
}
