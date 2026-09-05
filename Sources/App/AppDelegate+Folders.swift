import AppKit

/// Les dossiers de la colonne, et tout ce qui déplace une ligne : glisser-déposer, menus
/// de rangement, réordonnancement.
///
/// **Séparé des onglets et des espaces.** Les trois vivaient dans un fichier de six cents
/// lignes ; ils n'ont en commun que la colonne où ils s'affichent, et chacun se relit
/// mieux seul.
extension AppDelegate {

    // MARK: - Dossiers et déplacements

    /// Un espace privé neuf, et on y va.
    ///
    /// **C'est la seule façon d'en obtenir un.** Un espace existant ne se rend pas privé :
    /// ses onglets sont déjà nés avec un magasin de données qui écrit sur le disque.
    @objc func newPrivateSpace(_ sender: Any?) {
        spaces.append(Space.makePrivate())
        layout.sidebar.slideNext(direction: 1)
        currentSpaceIndex = spaces.count - 1
        newTab(url: nil)
        layout.toast.show("Espace privé : rien ne sera enregistré")
    }

    /// Crée un dossier — **et ne déplace rien**.
    ///
    /// Il y entrait l'onglet courant, au motif qu'un dossier vide serait deux gestes pour
    /// une intention. C'était supposer l'intention : on crée un dossier pour ranger *ce
    /// qu'on veut y mettre*, et l'onglet ouvert n'en fait pas partie plus souvent qu'autre
    /// chose. Le raccourci escamotait alors la page qu'on regardait dans un dossier qu'on
    /// venait d'inventer — un déplacement qu'on n'a pas demandé, qu'aucune annulation ne
    /// rattrape, et dont on ne comprend pas d'où il vient.
    ///
    /// **Créer, c'est créer.** Ranger est un autre geste : le glisser-déposer, ou le menu
    /// de l'onglet.
    @objc func newFolder(_ sender: Any?) {
        currentSpace.addFolder(named: "Dossier \(currentSpace.folders.count + 1)")
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

        // **Envoyer, et non glisser.** Traîner un onglet jusqu'à un espace qu'on ne voit
        // pas — il faudrait d'abord ouvrir le sélecteur — demande de viser une cible qui
        // n'est pas à l'écran. Nommer la destination est plus sûr et plus rapide.
        let elsewhere = spaces.filter { $0 !== space }.map { target in
            ActionItem(title: target.name, symbol: target.symbol,
                       action: { [weak self] in self?.send(tabID: id, to: target) })
        }

        var items: [ActionItem] = [
            ActionItem(title: "Déplacer vers", symbol: "arrow.right.doc.on.clipboard",
                       children: destinations)
        ]
        // Rien à proposer s'il n'y a qu'un espace : une entrée qui ouvrirait une liste vide
        // est un contrôle mort.
        if !elsewhere.isEmpty {
            items.append(ActionItem(title: "Envoyer vers l'espace", symbol: "arrow.turn.up.right",
                                    children: elsewhere))
        }
        items += [
            .separator,
            ActionItem(title: "Fermer l'onglet", symbol: "xmark", shortcut: "⌘W",
                       isDestructive: true,
                       action: { [weak self] in self?.close(tabID: id) })
        ]
        presentMenu(items, at: event)
    }

    /// Déplace un onglet vers un autre espace.
    ///
    /// **L'onglet part avec sa page vivante.** On ne recharge pas : la vue web est la même,
    /// elle change seulement d'appartenance. Recharger ferait perdre le défilement, un
    /// formulaire à moitié rempli, une vidéo en cours — pour un déplacement de rangement.
    ///
    /// Le cas qui compte est celui d'un espace privé. Y envoyer un onglet ordinaire ne le
    /// rend pas privé pour autant : sa vue garde le magasin de données avec lequel elle est
    /// née, et le contraire serait un mensonge tranquille. On le dit plutôt que de laisser
    /// croire.
    func send(tabID: UUID, to target: Space) {
        guard let tab = currentSpace.tab(with: tabID) else { return }
        let wasCurrent = currentSpace.current === tab
        currentSpace.remove(tab)
        target.append(tab)

        if wasCurrent { activateCurrentTab() }
        syncSidebar()

        let warning = target.isPrivate && !currentSpace.isPrivate
            ? " — sa page reste hors du privé" : ""
        layout.toast.show("Envoyé vers \(target.name)\(warning)") { [weak self] in
            guard let self, let index = self.spaces.firstIndex(where: { $0 === target }) else { return }
            self.spacesPanel(self.layout.spacesPanel, didSelect: index)
        }
    }

    func showFolderMenu(_ id: UUID, _ event: NSEvent) {
        let items: [ActionItem] = [
            ActionItem(title: "Renommer", symbol: "pencil",
                       action: { [weak self] in self?.renameFolder(id) }),
            ActionItem(title: "Supprimer le dossier", symbol: "trash", isDestructive: true,
                       action: { [weak self] in self?.deleteFolder(id) })
        ]
        presentMenu(items, at: event)
    }

    func presentMenu(_ items: [ActionItem], at event: NSEvent) {
        NativeMenu.popUp(items, at: layout.convert(event.locationInWindow, from: nil), in: layout)
    }

    /// Renommer un dossier passe par une feuille, faute d'une ligne qui puisse devenir
    /// éditable comme dans le panneau des espaces — la sidebar reconstruit ses lignes à
    /// chaque changement, l'édition en place n'y survivrait pas.
    func renameFolder(_ id: UUID) {
        guard let folder = currentSpace.folder(with: id) else { return }
        NativeMenu.prompt(title: "Renommer le dossier", value: folder.name,
                          confirm: "Renommer", in: window) { [weak self] name in
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
}
