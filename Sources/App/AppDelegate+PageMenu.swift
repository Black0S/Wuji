import AppKit
import WebKit

/// Le menu contextuel d'une page.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - Menu contextuel de la page

    /// Ancré sur le curseur, et non sur les coordonnées de l'événement : le clic vient
    /// d'avoir lieu, la souris est encore dessus. C'est vrai jusque dans les cadres
    /// imbriqués, où les coordonnées de la page ne sont plus celles de la fenêtre.
    func showPageMenu(_ target: PageContextMenu.Target) {
        let items = contextItems(for: target)
        guard !items.isEmpty, let window, let layout else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        NativeMenu.popUp(items, at: layout.convert(inWindow, from: nil), in: layout)
    }

    /// Le menu parle de ce qui est sous le curseur, et de rien d'autre. Sur un lien il
    /// parle du lien ; sur une image, de l'image ; sur du vide, de la page. Un menu qui
    /// dirait tout à chaque fois obligerait à chercher la seule ligne qui s'applique.
    func contextItems(for target: PageContextMenu.Target) -> [ActionItem] {
        var items: [ActionItem] = []
        func startGroup() {
            if !items.isEmpty { items.append(.separator) }
        }

        if let link = target.link {
            items.append(ActionItem(title: "Ouvrir dans un nouvel onglet", symbol: "square.on.square",
                                    action: { [weak self] in self?.openInNewTab(link, activate: false) }))
            items.append(ActionItem(title: "Copier l'adresse du lien", symbol: "link",
                                    action: { Self.copy(link.absoluteString) }))
        }

        if let image = target.image, PageContextMenu.isAddressable(image) {
            startGroup()
            items.append(ActionItem(title: "Ouvrir l'image dans un nouvel onglet", symbol: "photo",
                                    action: { [weak self] in self?.openInNewTab(image, activate: false) }))
            items.append(ActionItem(title: "Copier l'adresse de l'image", symbol: "link",
                                    action: { Self.copy(image.absoluteString) }))
            items.append(ActionItem(title: "Enregistrer l'image…", symbol: "arrow.down.circle",
                                    action: { [weak self] in self?.download(image) }))
        }

        if target.isEditable {
            // Dans un champ, l'ordre est celui que tout le monde connaît. Ces trois-là
            // passent par les actions standard plutôt que par le presse-papiers : c'est
            // le champ de la page qui sait où insérer, pas nous.
            var edit: [ActionItem] = []
            if !target.selection.isEmpty {
                edit.append(ActionItem(title: "Couper", symbol: "scissors", shortcut: "⌘X",
                                       action: { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }))
                edit.append(ActionItem(title: "Copier", symbol: "doc.on.doc", shortcut: "⌘C",
                                       action: { Self.copy(target.selection) }))
            }
            if NSPasteboard.general.string(forType: .string) != nil {
                edit.append(ActionItem(title: "Coller", symbol: "doc.on.clipboard", shortcut: "⌘V",
                                       action: { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }))
            }
            if !edit.isEmpty {
                startGroup()
                items.append(contentsOf: edit)
            }
        } else if !target.selection.isEmpty {
            startGroup()
            items.append(ActionItem(title: "Copier", symbol: "doc.on.doc", shortcut: "⌘C",
                                    action: { Self.copy(target.selection) }))
            if let url = settings.searchEngine.url(for: target.selection) {
                // La recherche part dans un nouvel onglet : on cherche un mot **en lisant**
                // une page, et perdre la page serait perdre la raison de chercher.
                items.append(ActionItem(title: Self.searchTitle(for: target.selection),
                                        symbol: "magnifyingglass",
                                        action: { [weak self] in self?.openInNewTab(url, activate: true) }))
            }
        }

        guard items.isEmpty else { return items }

        // Rien sous le curseur : le menu parle alors de la page elle-même. Précédent et
        // suivant n'apparaissent que s'il y a quelque chose derrière ou devant — une
        // entrée grisée en permanence est une entrée qu'on apprend à ne plus lire.
        guard let tab = currentTab else { return [] }
        if tab.webView.canGoBack {
            items.append(ActionItem(title: "Précédent", symbol: "chevron.left",
                                    action: { [weak self] in self?.goBack(nil) }))
        }
        if tab.webView.canGoForward {
            items.append(ActionItem(title: "Suivant", symbol: "chevron.right",
                                    action: { [weak self] in self?.goForward(nil) }))
        }
        items.append(ActionItem(title: "Recharger", symbol: "arrow.clockwise", shortcut: "⌘R",
                                action: { [weak self] in self?.reload(nil) }))
        if let url = tab.url, !isBlank(tab) {
            items.append(.separator)
            items.append(ActionItem(title: "Copier l'adresse de la page", symbol: "link",
                                    action: { Self.copy(url.absoluteString) }))
        }
        return items
    }

    /// Assez de la sélection pour la reconnaître, jamais assez pour étirer le menu.
    ///
    /// **La coupe se fait ici et pas dans le menu.** `NSMenu` tronque de lui-même, mais au
    /// milieu du libellé : le guillemet fermant partait, et on ne savait plus où finissait
    /// ce qu'on avait sélectionné. Quarante-huit caractères, parce qu'un menu de page tient
    /// autour de cette largeur sans qu'une seule ligne le fasse doubler.
    static let selectionLimit = 48

    static func searchTitle(for selection: String) -> String {
        let flat = selection.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > selectionLimit else { return "Rechercher « \(flat) »" }
        let court = flat.prefix(selectionLimit).trimmingCharacters(in: .whitespaces)
        return "Rechercher « \(court)… »"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Télécharger sans naviguer : enregistrer une image ne doit pas quitter la page où
    /// on l'a trouvée.
    func download(_ url: URL) {
        guard let webView = currentTab?.webView else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated { self?.register(download, source: url) }
        }
    }

    @objc func showHistory(_ sender: Any?) {
        openInternal(URL(string: "wuji://history")!)
    }

    /// Ouvre une page de l'application — et **il n'y en a qu'une par espace**.
    ///
    /// Pas une par page : **une, pour toutes.** Les favoris, l'historique, le blocage,
    /// les réglages ne sont pas quatre destinations, ce sont les sections d'un même endroit
    /// — elles partagent le sommaire, et y cliquer « Historique » depuis les favoris navigue
    /// sur place. Le raccourci fait ce que fait le lien, sans quoi les deux chemins d'une
    /// même intention ne mènent pas au même endroit. Un espace finissait sinon avec quatre
    /// onglets qui affichaient la même colonne à quatre lignes de sélection près.
    ///
    /// **Deux onglets sur la même page de l'application ne sont pas deux vues, ce sont deux
    /// vérités.** Elles divergent à la première modification — on éteint un réglage d'un
    /// côté, l'autre continue d'afficher l'ancien état — et la seule façon de savoir
    /// laquelle a raison est de recharger celle qu'on regarde. Un site peut se permettre
    /// deux onglets ; une page qui pilote l'application, non.
    ///
    /// **L'espace courant d'abord.** On y travaille : y rester est le comportement qui ne
    /// surprend jamais. Ce n'est qu'à défaut qu'on rejoint l'onglet ouvert ailleurs, parce
    /// qu'il n'y a bien qu'un historique et qu'un jeu de réglages. Un espace privé n'est
    /// jamais rejoint : on n'en sort pas les pages, et l'on n'y entre pas par un raccourci.
    ///
    /// **Rien n'est refermé.** Un espace qui portait déjà plusieurs de ces onglets les
    /// garde : aucun onglet ne se ferme sans qu'on l'ait fermé, et la règle vaut aussi
    /// quand c'est nous qui aurions rangé.
    func openInternal(_ url: URL) {
        if let found = internalTab(preferring: url.host()) {
            if found.space != currentSpaceIndex { currentSpaceIndex = found.space }
            currentSpace.current = found.tab
            activateCurrentTab()
            // Recharger la même adresse pour rien perdrait le défilement et l'état de la page.
            if found.tab.url != url { found.tab.webView.load(URLRequest(url: url)) }
            return
        }
        newTab(url: url)
    }

    /// L'onglet de l'application, où qu'il soit.
    ///
    /// Trois préférences, dans cet ordre. **Celui qui affiche déjà la page demandée** : un
    /// espace hérité d'avant la règle peut en porter plusieurs, et ⌘Y doit alors tomber sur
    /// l'historique ouvert plutôt que de transformer les favoris. **Puis n'importe lequel
    /// qui montre quelque chose.** **L'onglet vierge en dernier** : il annonce `wuji://`,
    /// donc il compte, et c'est voulu — il ne montre rien qu'on perdrait ; mais le préférer
    /// à un onglet qui travaille laisserait les deux ouverts.
    func internalTab(preferring host: String?) -> (space: Int, tab: Tab)? {
        func find(_ index: Int) -> (Int, Tab)? {
            guard spaces.indices.contains(index), !spaces[index].isPrivate else { return nil }
            let internals = spaces[index].allTabs.filter {
                $0.url?.scheme == InternalPageHandler.scheme
            }
            let chosen = internals.first { $0.url?.host() == host && host != nil }
                ?? internals.first { !isBlank($0) }
                ?? internals.first
            return chosen.map { (index, $0) }
        }
        if let here = find(currentSpaceIndex) { return here }
        return spaces.indices.lazy.compactMap(find).first
    }

    /// Les actions des pages internes. Elles ne touchent à rien elles-mêmes : elles
    /// demandent, l'application décide.
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any] else { return }
            if message.name == MediaWatcher.handler {
                // La page dit ce qu'elle joue ; l'onglet le retient pour la sidebar.
                let playing = payload["playing"] as? Bool ?? false
                if let tab = message.webView.flatMap(tab(for:)),
                   tab.isPlayingMedia != playing {
                    tab.isPlayingMedia = playing
                    syncSidebar()
                }
                return
            }
            if message.name == PageContextMenu.handler {
                showPageMenu(PageContextMenu.Target(payload: payload))
                return
            }
            if message.name == PasswordForm.handler {
                handlePasswordMessage(message, payload: payload)
                return
            }
            if message.name == RouteWatcher.handler {
                // La vue qui parle, et pas l'onglet courant : un onglet de fond change
                // d'adresse lui aussi, et ses scripts lui appartiennent.
                if let webView = message.webView { replayUserScripts(in: webView) }
                return
            }
            if message.name == "wujiError" {
                guard let raw = payload["url"] as? String, let url = URL(string: raw) else { return }
                switch payload["action"] as? String {
                // « Continuer quand même » sur un certificat refusé : l'exception vaut pour
                // cet hôte et cette session, et rien n'en est écrit sur le disque.
                case "trust":
                    trustHost(of: url)
                // Une règle de contenu vient d'une liste de blocage : on mène là où elle
                // se lève, plutôt que de recharger une adresse qui échouera encore.
                case "blocking":
                    showBlocking(nil)
                    return
                default:
                    break
                }
                currentTab?.webView.load(URLRequest(url: url))
                return
            }
            // **Avant la garde sur « action », et c'est tout le correctif.** Le sélecteur
            // d'éléments renvoie `{selector, host}` : il n'a pas d'action, parce qu'il n'en
            // demande pas une — il rapporte ce qu'on a désigné. Rangé après la garde, son
            // message était écarté sans un mot, et le masquage ne faisait rien du tout.
            //
            // La leçon vaut au-delà : une garde commune posée au milieu d'un aiguillage
            // décide pour des messages qu'elle ne connaît pas.
            if message.name == ElementPicker.handler {
                handlePickedElement(payload)
                return
            }
            guard let action = payload["action"] as? String else { return }
            if message.name == "wujiDownloads" {
                handleDownloadAction(action, id: payload["id"] as? String)
                return
            }
            if message.name == "wujiFavorites" {
                handleFavoriteAction(action, id: payload["id"] as? String)
                return
            }
            if message.name == "wujiSettings" {
                handlePasswordAction(action, payload: payload)
                handleSettingsAction(action, payload: payload)
                return
            }
            if message.name == "wujiBlocking" {
                handleBlockingAction(action, id: payload["id"] as? String)
                return
            }
            if message.name == "wujiScripts" {
                handleScriptAction(action, payload: payload)
                return
            }
            switch action {
            case "delete":
                if let url = payload["url"] as? String { history.delete(url: url) }
            case "clear":
                history.clear()
                currentTab?.webView.reload()
            default:
                break
            }
        }
    }

    func handleDownloadAction(_ action: String, id: String?) {
        switch action {
        case "clear":
            downloads.clearFinished()
            currentTab?.webView.reload()

        case "reveal":
            guard let destination = downloads.item(id: id)?.destination else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])

        case "pause":
            guard let item = downloads.item(id: id), let download = item.download else { return }
            item.sample()
            item.state = .paused
            item.observation = nil
            // Mettre en pause, c'est annuler en gardant de quoi reprendre : WebKit n'a pas
            // d'autre mécanisme, et sans ces données la reprise repartirait de zéro.
            download.cancel { [weak self] data in
                MainActor.assumeIsolated {
                    item.resumeData = data
                    item.download = nil
                    self?.refreshDownloads(reload: true)
                }
            }

        case "resume":
            guard let item = downloads.item(id: id), let webView = currentTab?.webView else {
                return
            }
            item.state = .running

            // **Avec les données de reprise si on les a, du début sinon.**
            //
            // Une pause les fournit ; une fermeture de l'application, non — WebKit ne les
            // rend qu'à l'annulation, et il n'y a pas de temps pour la demander en partant.
            // Repartir de zéro est alors la seule chose honnête, et le fichier visé reste le
            // même : c'est ce qu'on attendait de la ligne qu'on vient de rouvrir.
            if let data = item.resumeData {
                item.resumeData = nil
                webView.resumeDownload(fromResumeData: data) { [weak self] download in
                    MainActor.assumeIsolated { self?.attach(download, to: item) }
                }
            } else {
                if let destination = item.destination {
                    try? FileManager.default.removeItem(at: destination)
                    item.destination = nil
                }
                webView.startDownload(using: URLRequest(url: item.source)) { [weak self] download in
                    MainActor.assumeIsolated { self?.attach(download, to: item) }
                }
            }

        case "cancel":
            guard let item = downloads.item(id: id) else { return }
            item.download?.cancel { _ in }
            item.state = .failed("Annulé")
            item.observation = nil
            item.download = nil
            // Le fichier partiel n'a plus d'usage : le laisser dans Téléchargements
            // ferait croire à un fichier complet.
            if let destination = item.destination { try? FileManager.default.removeItem(at: destination) }
            refreshDownloads(reload: true)

        case "retry":
            guard let item = downloads.item(id: id), let webView = currentTab?.webView else { return }
            downloads.remove(item)
            // `startDownload` plutôt qu'une navigation : réessayer ne doit pas déplacer la
            // page qu'on est en train de regarder.
            webView.startDownload(using: URLRequest(url: item.source)) { [weak self] download in
                MainActor.assumeIsolated { self?.register(download, source: item.source) }
            }

        default:
            break
        }
    }

    /// Rebranche un téléchargement repris sur l'élément existant : c'est un nouvel objet
    /// WebKit, mais la même ligne pour l'utilisateur.
    func attach(_ download: WKDownload, to item: DownloadItem) {
        download.delegate = self
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDownloads() }
        }
        refreshDownloads(reload: true)
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = currentTab?.webView else { return }
        webView.printOperation(with: .shared).run()
    }
}
