import AppKit

/// Les modes d'affichage des onglets. **États mutuellement exclusifs, pas des couches
/// empilées** (spec §2.2) : un seul est monté à la fois, les autres n'existent pas.
enum TabsMode: String, CaseIterable {
    case horizontal = "Horizontal"
    case vertical   = "Vertical"
    case hidden     = "Masqué"
}

/// Ce qu'une vue d'onglets a le droit de savoir. Volontairement pauvre : ni `WKWebView`,
/// ni `Tab`, ni index de navigation.
///
/// C'est ici que se joue la décision d'architecture la plus importante du projet —
/// **le modèle d'onglets ne connaît pas son affichage**. Le spike la met à l'épreuve pour
/// trois vues au lieu d'une, et c'est ce qui doit rendre J2b tenable en 1,5 mois.
struct TabSnapshot {
    let title: String
    let host: String
    let isLoading: Bool
}

@MainActor
protocol TabsView: NSView {
    func update(tabs: [TabSnapshot], selected: Int)
    var onSelect: ((Int) -> Void)? { get set }
    var onClose: ((Int) -> Void)? { get set }
    var onNew: (() -> Void)? { get set }
}

/// Fabrique le module du mode demandé. Le mode masqué ne rend pas une vue vide :
/// **il ne rend rien du tout**, et rien n'est instancié (principe 4).
@MainActor
enum TabsFactory {
    static func make(_ mode: TabsMode) -> TabsView? {
        switch mode {
        case .horizontal: return TabStrip()
        case .vertical:   return TabSidebar()
        case .hidden:     return nil
        }
    }
}

// MARK: - Vocabulaire commun aux deux vues

@MainActor
enum TabsStyle {
    static let rowHeight: CGFloat = 30
    static let sidebarWidth: CGFloat = 232
    static let stripHeight = Tokens.Chrome.stripHeight

    static func makeSurface() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = Tokens.Radius.pill
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: view)
        return view
    }

    static func paint(_ surface: NSView) {
        surface.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        surface.layer?.borderColor = Tokens.chromeHairline.cgColor
    }
}
