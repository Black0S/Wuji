import AppKit
import WebKit

/// La session : ce qui survit à la fermeture.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - Session

    func restoreSession() {
        guard let stored = session.load(), !stored.spaces.isEmpty else {
            spaces = [Space(name: "Personnel", symbol: Space.symbol(forIndex: 0))]
            newTab(url: nil)
            return
        }

        spaces = stored.spaces.map { storedSpace in
            let space = Space(name: storedSpace.name, symbol: storedSpace.symbol)
            for storedFolder in storedSpace.folders {
                let folder = space.addFolder(named: storedFolder.name)
                folder.isExpanded = storedFolder.isExpanded
                storedFolder.tabs.forEach { space.place(restore($0), at: .into(folder)) }
                folder.isExpanded = storedFolder.isExpanded
            }
            storedSpace.loose.forEach { space.place(restore($0), at: .looseEnd) }
            let order = space.allTabs
            if let index = storedSpace.currentTab, order.indices.contains(index) {
                space.current = order[index]
            } else {
                space.current = order.first
            }
            return space
        }
        currentSpaceIndex = min(max(0, stored.currentSpace), spaces.count - 1)

        if currentSpace.isEmpty {
            newTab(url: nil)
        } else {
            activateCurrentTab()
        }
    }

    func restore(_ stored: StoredTab) -> Tab {
        makeTab(pendingURL: stored.url.flatMap(URL.init(string:)), pendingTitle: stored.title)
    }

    func snapshot() -> StoredSession {
        // Un espace privé n'est pas écrit : le retrouver au prochain lancement serait le
        // contraire de ce qu'il promet.
        StoredSession(
            spaces: spaces.filter { !$0.isPrivate }.map { space in
                let order = space.allTabs
                return StoredSpace(
                    name: space.name,
                    symbol: space.symbol,
                    folders: space.folders.map { folder in
                        StoredFolder(name: folder.name, isExpanded: folder.isExpanded,
                                     tabs: folder.tabs.filter { !isBlank($0) }.map(store))
                    },
                    loose: space.loose.filter { !isBlank($0) }.map(store),
                    currentTab: order.firstIndex { $0 === space.current })
            },
            currentSpace: currentSpaceIndex)
    }

    func store(_ tab: Tab) -> StoredTab {
        StoredTab(url: tab.url?.absoluteString, title: tab.title)
    }

    /// Un seul endroit où les réglages descendent dans l'application. Sans ça, chaque
    /// réglage finirait branché depuis sa propre rangée d'interface, et on ne saurait
    /// plus qui pilote quoi.
    func applySettings() {
        let themeChanged = appliedTheme != settings.theme
        appliedTheme = settings.theme
        NSApp.appearance = settings.theme.appearance

        for tab in spaces.flatMap(\.allTabs) {
            tab.webView.pageZoom = settings.pageZoom
            tab.webView.customUserAgent = settings.agent == .safari ? nil
                : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                  + "(KHTML, like Gecko) " + settings.agent.applicationName
            tab.webView.isInspectable = settings.safariInspection
            // Une couleur dynamique posée sur WebKit est résolue à l'affectation : il faut
            // la réécrire quand le thème change.
            // Une page interne suit le thème par `prefers-color-scheme`, qui reflète
            // l'apparence de la vue. Le basculement est instantané pour le CSS, mais le
            // HTML a pu être produit avec des couleurs figées : on le régénère.
            if themeChanged, tab.url?.scheme == InternalPageHandler.scheme {
                tab.webView.reload()
            }
        }

        spaces.flatMap(\.allTabs).forEach(applyPageBackground)
    }

    /// Le fond hors page — celui qu'on découvre au rebond du défilement.
    ///
    /// Résolu contre l'apparence **déduite du réglage**, et non contre celle de la vue :
    /// au moment où l'on applique un thème, les vues n'ont pas encore basculé, et lire
    /// leur apparence rendait toujours la précédente. Le réglage, lui, est déjà à jour.
    func applyPageBackground(to tab: Tab) {
        let appearance = settings.theme.appearance ?? NSApp.effectiveAppearance
        tab.webView.underPageBackgroundColor =
            Tokens.resolve(Tokens.sidebarBackground, for: appearance)
    }

    func refreshInternalPages() {
        for tab in spaces.flatMap(\.allTabs) {
            applyPageBackground(to: tab)
            if tab.url?.scheme == InternalPageHandler.scheme { tab.webView.reload() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Le libellé du menu suit ce que la touche va réellement faire. « Fermer l'onglet »
    /// affiché alors que ⌘W fermera les Réglages serait un mensonge, même bref. Et une
    /// entrée qui n'a rien à faire — rien à rouvrir, rien à mettre de côté — se désactive
    /// plutôt que d'attendre un clic sans effet.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTab(_:)):
            let auxiliary = NSApp.keyWindow != nil && NSApp.keyWindow !== window
            item.title = auxiliary ? "Fermer la fenêtre" : "Fermer l'onglet"
            return true
        case #selector(toggleFavorite(_:)):
            guard let tab = currentTab, let url = favoritableURL(of: tab) else { return false }
            item.title = favorites.contains(url) ? "Retirer des favoris" : "Ajouter aux favoris"
            return true
        case #selector(reopenClosedTab(_:)):
            return !closedTabs.isEmpty
        default:
            return true
        }
    }
}
