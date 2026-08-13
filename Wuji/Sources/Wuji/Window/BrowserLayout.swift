import AppKit

/// Toute la géométrie de la fenêtre, à un seul endroit.
///
/// La leçon de la version précédente : chaque vue qui calculait sa propre position a fini
/// par se superposer à une autre. Ici, personne ne se place tout seul.
///
/// Layout unique : **vertical ancré**. La sidebar occupe la colonne de gauche, le contenu
/// commence après elle. L'interface est permanente — plus rien ne s'escamote.
@MainActor
final class BrowserLayout: ThemedView {

    let sidebar = Sidebar()
    let topBar = ContentTopBar()
    let content = BrowserContent()
    let findBar = FindBar()
    let toast = Toast()
    let spacesPanel = SpacesPanel()
    let omnibox = Omnibox()
    let actionSheet = ActionSheet()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // La palette passe au-dessus de tout le reste, y compris de la barre de recherche.
        [content, topBar, sidebar, findBar, toast,
         spacesPanel, omnibox, actionSheet].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor

        let sidebarWidth = Tokens.Chrome.sidebarWidth
        let barHeight = Tokens.Chrome.topBarHeight
        let contentWidth = bounds.width - sidebarWidth
        let contentHeight = bounds.height - barHeight

        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        content.frame = NSRect(x: sidebarWidth, y: 0, width: contentWidth, height: contentHeight)
        topBar.frame = NSRect(x: sidebarWidth, y: contentHeight, width: contentWidth, height: barHeight)
        // Palette et recherche vivent dans la zone de contenu : elles ne peuvent jamais
        // recouvrir la sidebar ni la barre du haut.
        omnibox.frame = content.frame
        findBar.frame = content.frame
        toast.frame = content.frame
        // Le panneau des espaces déborde sur la sidebar : il s'ancre sur elle.
        spacesPanel.frame = bounds
        // La feuille d'action couvre toute la fenêtre : elle s'ouvre aussi bien sous un
        // bouton de la barre que sous le curseur, au fond de la sidebar.
        actionSheet.frame = bounds
    }
}
