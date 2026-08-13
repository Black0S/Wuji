import AppKit

/// Toute la géométrie de la fenêtre, à un seul endroit.
///
/// La leçon de la version précédente : chaque vue qui calculait sa propre position a fini
/// par se superposer à une autre. Ici, personne ne se place tout seul.
///
/// Layout unique : **vertical ancré**. La sidebar occupe la colonne de gauche, le contenu
/// commence après elle. Quand le chrome s'escamote, la sidebar sort par la gauche et le
/// contenu reprend toute la fenêtre.
@MainActor
final class BrowserLayout: ThemedView {

    let sidebar = Sidebar()
    let topBar = ContentTopBar()
    let content = BrowserContent()
    let omnibox = Omnibox()

    private(set) var isChromeVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [content, topBar, sidebar, omnibox].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor
        apply(progress: isChromeVisible ? 1 : 0)
    }

    /// `progress` : 0 = tout escamoté, 1 = chrome complet.
    private func apply(progress: CGFloat) {
        let sidebarWidth = Tokens.Chrome.sidebarWidth
        let barHeight = Tokens.Chrome.topBarHeight
        let inset = sidebarWidth * progress
        let barVisible = barHeight * progress

        sidebar.frame = NSRect(x: inset - sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height)
        content.frame = NSRect(x: inset, y: 0,
                               width: bounds.width - inset,
                               height: bounds.height - barVisible)
        topBar.frame = NSRect(x: inset, y: bounds.height - barVisible,
                              width: bounds.width - inset, height: barHeight)
        omnibox.frame = NSRect(x: inset, y: 0, width: bounds.width - inset, height: bounds.height - barVisible)
    }

    func setChrome(visible: Bool, animated: Bool) {
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible

        // Respect de « Réduire le mouvement » (spec §4.5).
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
        guard animated, duration > 0 else {
            apply(progress: visible ? 1 : 0)
            return
        }

        // Animer les cadres redimensionne la vue web à chaque image, donc la page se
        // remet en page pendant toute l'animation. C'est le coût du layout ancré, et
        // c'est ce que la semaine 3 doit juger : si ça saccade sur une page lourde,
        // il faudra choisir entre sidebar ancrée et sidebar flottante.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            apply(progress: visible ? 1 : 0)
        }
    }
}
