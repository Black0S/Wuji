import AppKit

/// La fenêtre : contenu bord à bord, sans barre de titre, les feux de circulation posés
/// par macOS en haut de la sidebar.
///
/// Ils ne peuvent pas être décolorés (spec §4.6, macOS impose sa couleur) — c'est la
/// seule couleur permanente du chrome, et on ne peut rien y faire.
@MainActor
final class BrowserWindow: NSWindow {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        // Le fond de fenêtre en #1C1C1E / blanc, jamais #000000 : le noir pur est réservé
        // au vide immersif, et blanc pur sur noir pur fait baver le texte (spec §5).
        backgroundColor = Tokens.chromeBackground
        minSize = NSSize(width: 640, height: 480)
        center()
    }

    /// Sans barre de titre visible, la fenêtre doit quand même pouvoir devenir clé
    /// pour que le clavier et l'omnibox fonctionnent.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
