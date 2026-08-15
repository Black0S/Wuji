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
        layout.actionSheet.present(items, at: layout.convert(inWindow, from: nil))
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

    /// Assez de la sélection pour la reconnaître, jamais assez pour couper la ligne.
    ///
    /// La citation est raccourcie **jusqu'à ce qu'elle tienne**, et non à un nombre de
    /// caractères choisi d'avance : une troncature par la feuille emporterait le guillemet
    /// fermant, et on ne saurait plus où finit ce qu'on a sélectionné.
    static func searchTitle(for selection: String) -> String {
        let flat = selection.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        func title(_ quote: String) -> String { "Rechercher « \(quote) »" }
        guard !ActionSheet.fits(title: title(flat)) else { return title(flat) }

        var candidate = flat
        while !candidate.isEmpty, !ActionSheet.fits(title: title(candidate + "…")) {
            candidate.removeLast()
        }
        return title(candidate.trimmingCharacters(in: .whitespaces) + "…")
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

    /// Dans l'onglet courant s'il est vierge ou s'il montre déjà cette page, dans un
    /// nouveau sinon : consulter deux fois l'historique ne doit pas laisser deux onglets.
    func openInternal(_ url: URL) {
        if let tab = currentTab, tab.url == nil || tab.url == Self.blankPage || tab.url == url {
            tab.webView.load(URLRequest(url: url))
        } else {
            newTab(url: url)
        }
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
                if let tab = spaces.flatMap(\.allTabs).first(where: { $0.webView === message.webView }),
                   tab.isPlayingMedia != playing {
                    tab.isPlayingMedia = playing
                    syncSidebar()
                }
                return
            }
            if message.name == BlockLogWatcher.handler {
                let host = message.frameInfo.request.url?.host() ?? ""
                for raw in payload["refused"] as? [String] ?? [] {
                    guard let url = URL(string: raw) else { continue }
                    blockLog.record(.refused, host: host,
                                    detail: (url.host() ?? "") + url.path)
                }
                return
            }
            if message.name == ElementPicker.handler {
                addPickedRule(payload["selector"] as? String ?? "")
                return
            }
            if message.name == PageContextMenu.handler {
                showPageMenu(PageContextMenu.Target(payload: payload))
                return
            }
            if message.name == "wujiError" {
                guard let raw = payload["url"] as? String, let url = URL(string: raw) else { return }
                // « Ne pas bloquer ce site » depuis la page d'erreur : l'exception, puis
                // la page. Sans le second geste, on resterait devant l'échec en croyant
                // que le réglage n'a rien fait.
                if payload["action"] as? String == "allow" { blocker.toggleException(for: url) }
                currentTab?.webView.load(URLRequest(url: url))
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
                handleSettingsAction(action, payload: payload)
                return
            }
            if message.name == "wujiScripts" {
                handleScriptAction(action, payload: payload)
                return
            }
            if message.name == "wujiAdBlock" {
                handleAdBlockAction(action, payload: payload)
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
            guard let item = downloads.item(id: id), let data = item.resumeData,
                  let webView = currentTab?.webView else { return }
            item.state = .running
            item.resumeData = nil
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                MainActor.assumeIsolated { self?.attach(download, to: item) }
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
