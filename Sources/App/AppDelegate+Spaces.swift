import AppKit

/// Les espaces : en créer, en fermer, passer de l'un à l'autre.
extension AppDelegate {

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

    /// **⌘ change d'onglet, ⌥ change d'espace.**
    ///
    /// Les mêmes deux touches que `⌘[` et `⌘]`, avec l'autre modificateur : le geste est le
    /// même, ce sur quoi il porte est d'un cran au-dessus. Deux raccourcis à retenir
    /// deviennent une règle, et une règle se retient toute seule.
    ///
    /// Ça boucle, comme les onglets : arriver au bout d'une liste circulaire ne doit pas
    /// obliger à repartir dans l'autre sens.
    @objc func nextSpace(_ sender: Any?) { stepSpace(by: 1) }

    @objc func previousSpace(_ sender: Any?) { stepSpace(by: -1) }

    /// **⌘ agit sur l'onglet, ⌥ sur l'espace.** Les mêmes touches, l'autre modificateur :
    /// `⌘T`/`⌘W` ouvrent et ferment un onglet, `⌥T`/`⌥W` un espace. Deux raccourcis de plus
    /// à retenir deviennent la suite d'une règle déjà connue.
    @objc func newSpace(_ sender: Any?) {
        spacesPanelDidRequestNew(layout.spacesPanel)
    }

    /// Fermer l'espace courant. **Le dernier ne se ferme pas** : il n'y a pas d'état où
    /// Wuji n'aurait aucun espace, et une touche qui ne fait rien vaut mieux qu'une fenêtre
    /// qui se vide.
    @objc func closeSpace(_ sender: Any?) {
        guard spaces.count > 1 else {
            layout.toast.show("C'est le dernier espace")
            return
        }
        removeSpace(at: currentSpaceIndex)
    }

    func stepSpace(by delta: Int) {
        guard spaces.count > 1 else { return }
        let target = (currentSpaceIndex + delta + spaces.count) % spaces.count
        layout.sidebar.slideNext(direction: delta)
        currentSpaceIndex = target
        // Un espace vide n'existe pas : on y entre toujours sur un onglet.
        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
        // Le panneau des espaces reste ouvert quand on l'a laissé : il doit suivre.
        if layout.spacesPanel.isOpen { refreshSpaces(layout.spacesPanel) }
    }

    func spacesPanel(_ panel: SpacesPanel, didSelect index: Int) {
        guard spaces.indices.contains(index), index != currentSpaceIndex else { return }
        // La colonne entre du côté d'où vient l'espace : aller vers la droite du sélecteur
        // fait entrer la liste par la droite. Sans direction, le mouvement dirait qu'il
        // s'est passé quelque chose sans dire quoi.
        layout.sidebar.slideNext(direction: index > currentSpaceIndex ? 1 : -1)
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
            .separator,
            ActionItem(title: "Supprimer", symbol: "trash", isEnabled: canDelete,
                       isDestructive: true,
                       action: { [weak self, weak panel] in
                           panel?.dismiss()
                           guard let self else { return }
                           self.spacesPanel(panel ?? self.layout.spacesPanel, didDelete: index)
                       })
        ]
        presentMenu(items, at: event)
    }

    // **Il n'y a pas de bascule privé/normal, et c'est délibéré.**
    //
    // Le menu d'un espace en proposait une. Elle ne pouvait pas tenir : le magasin de
    // données est choisi quand une vue web naît, donc « rendre cet espace privé »
    // laissait les onglets déjà ouverts écrire sur le disque sous un symbole qui disait
    // le contraire — et « rendre cet espace normal » aurait versé dans une session
    // enregistrée ce qu'un espace privé avait promis de ne pas garder.
    //
    // Un espace privé se crée avec ⌥N et le reste jusqu'à sa fermeture.

    /// **Fermer un espace ne demande plus rien.**
    ///
    /// Il y avait une confirmation, et elle se défendait : on ferme des onglets que rien ne
    /// rouvrira. Mais un espace se ferme rarement par accident — il faut ouvrir le panneau
    /// et viser une croix —, et la question tombait à chaque fois pour le cas où l'on se
    /// serait trompé une fois sur cent. Une interface qui se fait oublier ne redemande pas
    /// ce qu'on vient de dire. Ce qu'on a fermé se retrouve dans l'historique, et
    /// `session-précédente.json` garde l'état d'avant.
    func spacesPanel(_ panel: SpacesPanel, didDelete index: Int) {
        removeSpace(at: index)
    }

    func removeSpace(at index: Int) {
        guard spaces.indices.contains(index), spaces.count > 1 else { return }
        spaces.remove(at: index)
        // On tombe sur ce qui reste à gauche : la colonne entre donc de la gauche, comme
        // si l'on y était revenu.
        if index <= currentSpaceIndex { layout.sidebar.slideNext(direction: -1) }
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
        layout.sidebar.slideNext(direction: 1)
        currentSpaceIndex = index
        newTab(url: nil)
    }
}
