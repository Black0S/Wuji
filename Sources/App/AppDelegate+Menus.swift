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
        // ⇧⌘N est le raccourci de la navigation privée partout ailleurs : le dossier lui
        // cède la place et passe sur ⌥⌘N.
        let privateItem = NSMenuItem(title: "Nouvel espace privé",
                                     action: #selector(newPrivateSpace(_:)), keyEquivalent: "N")
        privateItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(privateItem)
        let folderItem = NSMenuItem(title: "Nouveau dossier",
                                    action: #selector(newFolder(_:)), keyEquivalent: "n")
        folderItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(folderItem)
        fileMenu.addItem(withTitle: "Fermer l'onglet", action: #selector(closeTab(_:)), keyEquivalent: "w")
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
        viewMenu.addItem(withTitle: "Blocage", action: #selector(showAdBlock(_:)), keyEquivalent: "")
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

        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}
