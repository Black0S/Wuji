import AppKit
import WebKit

/// La barre de menus.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - Menus

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Réglages…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Wuji", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Wuji", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Fichier")
        fileMenu.addItem(withTitle: "Nouvel onglet", action: #selector(newTab(_:)), keyEquivalent: "t")
        // **⌥ agit sur l'espace, ⌘ sur ce qu'il contient.** C'est la règle de toute cette
        // barre — ⌥T ouvre un espace quand ⌘T ouvre un onglet, ⌥W ferme l'un quand ⌘W ferme
        // l'autre. Un espace privé est un espace : son raccourci appartient donc à la même
        // famille, ⇧⌥N, et non à ⇧⌘N.
        //
        // ⇧⌘N était emprunté à la navigation privée des autres navigateurs. L'emprunt
        // coûtait une exception au milieu d'une règle simple, pour un geste qui ne se
        // trompe de toute façon pas de sens : sur macOS, ⇧⌘N crée un dossier — et c'est
        // à lui qu'il revient ici.
        let privateItem = NSMenuItem(title: "Nouvel espace privé",
                                     action: #selector(newPrivateSpace(_:)), keyEquivalent: "N")
        privateItem.keyEquivalentModifierMask = [.option, .shift]
        fileMenu.addItem(privateItem)
        let folderItem = NSMenuItem(title: "Nouveau dossier",
                                    action: #selector(newFolder(_:)), keyEquivalent: "N")
        folderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(folderItem)
        fileMenu.addItem(withTitle: "Enregistrer la page…", action: #selector(savePage(_:)),
                         keyEquivalent: "s")
        // **Le raccourci doit exister quelque part pour exister.** L'impression était
        // offerte par la feuille du bouton « … », qui annonçait ⌘P — mais aucune entrée de
        // la barre de menus ne portait ce raccourci, et macOS n'attribue les frappes qu'à
        // partir d'elle. La touche ne faisait donc rien, et le libellé mentait sur ce qu'il
        // fallait taper : le pire des deux, parce qu'il apprend à ne plus faire confiance
        // aux autres.
        fileMenu.addItem(withTitle: "Imprimer…", action: #selector(printPage(_:)),
                         keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Fermer l'onglet", action: #selector(closeTab(_:)), keyEquivalent: "w")
        // ⌘ agit sur l'onglet, ⌥ sur l'espace : la même règle que ⌘] et ⌥].
        let newSpaceItem = NSMenuItem(title: "Nouvel espace",
                                      action: #selector(newSpace(_:)), keyEquivalent: "t")
        newSpaceItem.keyEquivalentModifierMask = [.option]
        fileMenu.addItem(newSpaceItem)
        let closeSpaceItem = NSMenuItem(title: "Fermer l'espace",
                                        action: #selector(closeSpace(_:)), keyEquivalent: "w")
        closeSpaceItem.keyEquivalentModifierMask = [.option]
        fileMenu.addItem(closeSpaceItem)
        let reopenItem = NSMenuItem(title: "Rouvrir l'onglet fermé",
                                    action: #selector(reopenClosedTab(_:)), keyEquivalent: "T")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(reopenItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Indispensable : sans menu Édition, ⌘C/⌘V ne fonctionnent pas dans l'omnibox.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Présentation")
        viewMenu.addItem(withTitle: "Omnibox", action: #selector(focusOmnibox(_:)), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Recharger", action: #selector(reload(_:)), keyEquivalent: "r")
        let readerItem = NSMenuItem(title: "Mode lecture", action: #selector(toggleReader(_:)),
                                    keyEquivalent: "R")
        readerItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(readerItem)
        viewMenu.addItem(withTitle: "Traduire la page", action: #selector(translatePage(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Agrandir", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Réduire", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Taille réelle", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Ajouter aux favoris", action: #selector(toggleFavorite(_:)),
                         keyEquivalent: "d")
        let favoritesItem = NSMenuItem(title: "Favoris", action: #selector(showFavorites(_:)),
                                       keyEquivalent: "B")
        favoritesItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(favoritesItem)
        viewMenu.addItem(withTitle: "Blocage", action: #selector(showBlocking(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Scripts", action: #selector(showScripts(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Historique", action: #selector(showHistory(_:)), keyEquivalent: "y")
        viewMenu.addItem(withTitle: "Téléchargements", action: #selector(showDownloads(_:)), keyEquivalent: "j")
        viewMenu.addItem(withTitle: "Rechercher dans la page…", action: #selector(findInPage(_:)), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "Résultat suivant", action: #selector(findNext(_:)), keyEquivalent: "g")
        let previousMatch = NSMenuItem(title: "Résultat précédent",
                                       action: #selector(findPrevious(_:)), keyEquivalent: "G")
        previousMatch.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(previousMatch)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Onglet suivant", action: #selector(nextTab(_:)), keyEquivalent: "]")
        viewMenu.addItem(withTitle: "Onglet précédent", action: #selector(previousTab(_:)), keyEquivalent: "[")
        // **Les mêmes touches, l'autre modificateur.** ⌘ change d'onglet, ⌥ change
        // d'espace : le geste est le même, ce sur quoi il porte est d'un cran au-dessus.
        // Ce sont les deux touches à droite du P — « ^ » et « $ » sur un clavier français,
        // les crochets ailleurs ; macOS fait lui-même la correspondance.
        let nextSpaceItem = NSMenuItem(title: "Espace suivant",
                                       action: #selector(nextSpace(_:)), keyEquivalent: "]")
        nextSpaceItem.keyEquivalentModifierMask = [.option]
        viewMenu.addItem(nextSpaceItem)
        let previousSpaceItem = NSMenuItem(title: "Espace précédent",
                                           action: #selector(previousSpace(_:)), keyEquivalent: "[")
        previousSpaceItem.keyEquivalentModifierMask = [.option]
        viewMenu.addItem(previousSpaceItem)

        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // **Le menu Fenêtre, pour que ⌘M existe.**
        //
        // macOS ne fournit rien de lui-même : sans l'entrée de menu, la touche est morte —
        // et tout Mac s'attend à minimiser avec ⌘M.
        //
        // `windowsMenu` confie la liste des fenêtres au système : elle se tient à jour
        // toute seule, et on n'écrit pas un inventaire qu'on devrait maintenir.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Minimiser",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Tout ramener au premier plan",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
