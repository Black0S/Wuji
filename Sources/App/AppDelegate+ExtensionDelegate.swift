import AppKit
import WebKit

/// Ce que WebKit vient demander aux extensions : fenêtres, onglets, permissions, bulles.
///
// MARK: - Ce que WebKit vient demander

extension AppDelegate: WKWebExtensionControllerDelegate {

    /// Wuji n'a qu'une fenêtre de navigation : la liste en tient une, et c'est vrai.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        window.map { [$0] } ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    /// `browser.tabs.create`. L'onglet naît comme n'importe quel autre — même
    /// configuration, même place dans la colonne : une extension n'a pas de raison de
    /// produire un onglet d'une autre nature que celui qu'on ouvre à la main.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        // Une extension ouvre un onglet **depuis sa bulle** la plupart du temps : sa page
        // de réglages, un lien d'aide, un rapport. La bulle a fini de parler.
        if configuration.shouldBeActive { closeExtensionPopups() }
        return openInNewTab(configuration.url ?? Self.blankPage,
                            activate: configuration.shouldBeActive)
    }

    /// La page de réglages d'une extension s'ouvre dans un onglet, comme les nôtres : ce
    /// sont des pages, elles se rechargent et se mettent en favori.
    ///
    /// **La bulle se referme d'abord.** C'est presque toujours d'elle qu'on part —
    /// l'engrenage d'uBlock Origin Lite, le lien « Preferences » d'une autre — et la
    /// laisser flotter par-dessus l'onglet qu'on vient d'ouvrir donne deux surfaces qui
    /// parlent de la même extension, dont une qu'on croyait avoir quittée.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext) async throws {
        guard let url = context.optionsPageURL else { return }
        closeExtensionPopups()
        openInNewTab(url, activate: true)
    }

    /// Referme la bulle de toute extension qui en tient une ouverte.
    ///
    /// WebKit ne dit pas laquelle est affichée : on demande à chacune de fermer la sienne,
    /// ce qui ne coûte rien à celles qui n'en ont pas.
    func closeExtensionPopups() {
        for context in extensions.loaded {
            context.action(for: currentTab)?.closePopup()
        }
    }

    /// Ce qu'une extension demande **après** son activation.
    ///
    /// C'est le seul cas qui mérite d'interrompre : on a accordé une liste en connaissance
    /// de cause, et l'extension en demande une autre. La question passe par la bulle, au
    /// même endroit que la caméra et la position — et fermer sans répondre vaut « non ».
    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async
                                -> (Set<WKWebExtension.Permission>, Date?) {
        let name = context.webExtension.displayName ?? "Cette extension"
        let asked = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let granted = await confirm(title: "\(name) demande un pouvoir de plus",
                                    message: "Elle réclame : \(asked).")
        return (granted ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async
                                -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let name = context.webExtension.displayName ?? "Cette extension"
        let asked = patterns.map(\.string).sorted().prefix(6).joined(separator: ", ")
        let granted = await confirm(title: "\(name) demande d'autres sites",
                                    message: "Elle veut lire et modifier : \(asked).")
        return (granted ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let name = context.webExtension.displayName ?? "Cette extension"
        let asked = urls.map(\.absoluteString).sorted().prefix(6).joined(separator: ", ")
        let granted = await confirm(title: "\(name) demande d'autres adresses",
                                    message: "Elle veut lire et modifier : \(asked).")
        return (granted ? urls : [], nil)
    }

    /// La bulle d'une extension, ancrée sous le bouton qui vient de l'ouvrir.
    ///
    /// WebKit fabrique le `NSPopover` : il porte déjà la vue web de l'extension, sa taille
    /// et son cycle de vie. On ne fait que dire **où** il s'accroche — sous le bouton du
    /// puzzle, à l'endroit d'où le geste est parti.
    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        guard let popover = action.popupPopover, let layout else { return }
        // Sous l'icône épinglée quand il y en a une, sous le bouton des extensions sinon :
        // une bulle qui s'ouvre ailleurs que sous le bouton cliqué fait douter d'avoir
        // cliqué au bon endroit.
        let anchor = layout.topBar.anchor(forExtension: context.uniqueIdentifier)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// L'icône ou la pastille d'une extension a changé. Le bouton de la barre suit — le
    /// libellé et le compteur sont relus à l'ouverture du menu, mais l'apparition d'une
    /// première extension doit faire apparaître le bouton sans attendre un clic.
    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        syncToolbarButtons()
    }

    /// Une question fermée, posée dans la bulle, et attendue.
    ///
    /// Fermer sans répondre vaut « non » : c'est la seule réponse qu'on puisse déduire
    /// d'un silence sans se tromper.
    private func confirm(title: String, message: String) async -> Bool {
        await withCheckedContinuation { continuation in
            var answered = false
            layout.toast.ask(title: title, message: message, confirm: "Autoriser",
                             isDestructive: false,
                             onCancel: {
                                 guard !answered else { return }
                                 answered = true
                                 continuation.resume(returning: false)
                             }) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: true)
            }
        }
    }
}
