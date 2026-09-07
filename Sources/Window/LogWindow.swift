import AppKit
import WebKit

/// Le journal du blocage, dans **sa** fenêtre.
///
/// **Un onglet n'était pas le bon endroit.** On consulte le journal *pendant* qu'on regarde
/// une page qui se comporte mal : dans un onglet, il fallait quitter la page pour le lire,
/// puis y revenir, et l'on avait perdu ce qu'on voulait comparer. Il occupait aussi une
/// place dans la session, où il n'a rien à faire — on ne rouvre pas un journal au démarrage.
///
/// **Une seule, et elle revient au premier plan.** Ouvrir le journal trois fois de suite ne
/// doit pas empiler trois fenêtres identiques : la deuxième demande est une demande de
/// *voir*, pas d'avoir un second exemplaire.
@MainActor
final class LogWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var webView: WKWebView?

    /// Ce que la fenêtre doit afficher, redemandé à chaque ouverture et à chaque
    /// changement. Le journal ne se met pas à jour tout seul : c'est l'appelant qui sait
    /// quand il a bougé.
    var html: (() -> String)?

    /// Où les clics de la page reviennent — « Effacer », essentiellement.
    weak var handler: (any WKScriptMessageHandler)?

    func show(configuration: WKWebViewConfiguration) {
        if let window {
            refresh()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 620),
                             configuration: configuration)
        // Les pages internes ont leur propre fond ; celui de WebKit sous elles évite le
        // flash blanc à l'ouverture, sur lequel on cligne des yeux.
        view.setValue(false, forKey: "drawsBackground")
        webView = view

        let panel = NSWindow(contentRect: view.frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = "Journal du blocage"
        panel.contentView = view
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("wuji.journal")
        panel.center()
        window = panel

        refresh()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Recharge le contenu **sans recharger la page** : on remplace le document, ce qui
    /// évite une requête au gestionnaire de schéma pour une page qu'on a déjà en main.
    func refresh() {
        guard let webView, let html = html?() else { return }
        webView.loadHTMLString(html, baseURL: URL(string: "wuji://blocking/journal"))
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// La fenêtre fermée est vraiment fermée : garder la vue web en vie ferait tourner un
    /// processus de rendu pour un journal que personne ne regarde.
    func windowWillClose(_ notification: Notification) {
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        window = nil
    }
}
