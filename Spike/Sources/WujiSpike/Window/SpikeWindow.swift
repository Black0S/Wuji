import AppKit

/// **Question 1 du spike** : un `WKWebView` bord à bord, sans barre de titre,
/// avec des feux de circulation qui s'escamotent proprement.
///
/// Les feux ne peuvent pas être décolorés (spec §4.6, macOS impose sa couleur) —
/// ils ne peuvent qu'apparaître et disparaître. C'est exactement ce que veut Zero Interface.
@MainActor
final class SpikeWindow: NSWindow {

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

    // MARK: - Feux de circulation

    private var trafficLights: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap(standardWindowButton)
    }

    func setTrafficLights(visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard animated else {
            trafficLights.forEach { $0.alphaValue = target }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            trafficLights.forEach { $0.animator().alphaValue = target }
        }
    }
}
