import AppKit

/// Un dossier d'onglets, à l'intérieur d'un espace.
@MainActor
final class TabFolder {
    let id = UUID()
    var name: String
    var isExpanded = true
    var tabs: [Tab] = []

    init(name: String) { self.name = name }
}

/// Un espace : des onglets épinglés, des dossiers, et des onglets de passage.
///
/// **Trois collections plutôt qu'une seule avec des invariants.** Un tableau unique où
/// « les épinglés d'abord » tenait tant qu'il n'y avait qu'un niveau ; avec les dossiers,
/// chaque action aurait demandé de recalculer des plages d'index. Trois listes nommées
/// disent ce qu'elles contiennent et ne peuvent pas se désynchroniser.
///
/// **L'onglet courant est une référence, pas un index.** Un index désigne une position, et
/// une position change dès qu'on épingle, déplace ou ferme quelque chose ailleurs. C'est la
/// source de bugs classique de ce genre d'interface : on croit désigner un onglet, on
/// désigne un rang.
///
/// **Sur la couleur.** La spec §4.3 la réservait à la sécurité. La décision de produit est
/// allée dans l'autre sens, alors la règle de cohabitation est écrite ici : la couleur d'un
/// espace ne teinte qu'une pastille, jamais un liseré ni une grande surface. Le signal de
/// sécurité garde une forme et une position que rien d'autre n'occupe — un trait sur tout
/// le pourtour du contenu. Le **symbole** reste porteur de sens à égalité avec la couleur,
/// et non en décoration : c'est ce qui laisse les espaces distinguables sous « Différencier
/// sans couleur » de macOS.
@MainActor
final class Space {

    /// Des formes franchement différentes les unes des autres, pas des variantes du même
    /// dessin : à 14 pt, deux symboles voisins se confondent.
    static let symbols = ["square.stack", "briefcase", "book", "leaf", "bolt", "flask"]

    /// La palette des maquettes. Le premier choix est l'absence de couleur — un espace
    /// n'a pas à en porter une.
    enum Tint: Int, CaseIterable {
        case none, red, orange, green, blue, purple

        var color: NSColor? {
            switch self {
            case .none:   return nil
            case .red:    return NSColor(srgbRed: 0.902, green: 0.400, blue: 0.396, alpha: 1)
            case .orange: return NSColor(srgbRed: 0.960, green: 0.639, blue: 0.302, alpha: 1)
            case .green:  return NSColor(srgbRed: 0.373, green: 0.780, blue: 0.400, alpha: 1)
            case .blue:   return NSColor(srgbRed: 0.365, green: 0.678, blue: 0.937, alpha: 1)
            case .purple: return NSColor(srgbRed: 0.702, green: 0.565, blue: 0.941, alpha: 1)
            }
        }

        var label: String {
            switch self {
            case .none:   return "Sans couleur"
            case .red:    return "Rouge"
            case .orange: return "Orange"
            case .green:  return "Vert"
            case .blue:   return "Bleu"
            case .purple: return "Violet"
            }
        }
    }

    /// Où déposer un onglet. Le conteneur d'arrivée se déduit du voisin quand on dépose
    /// entre deux lignes — c'est ce qui permet de sortir d'un dossier en glissant sous lui.
    enum Destination {
        case before(Tab)
        case after(Tab)
        case into(TabFolder)
        case pinnedEnd
        case looseEnd
    }

    let id = UUID()
    var name: String
    var symbol: String
    var tint: Tint = .none

    private(set) var pinned: [Tab] = []
    private(set) var folders: [TabFolder] = []
    private(set) var loose: [Tab] = []
    var current: Tab?

    init(name: String, symbol: String, tint: Tint = .none) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }

    // MARK: - Lecture

    /// L'ordre d'affichage : épinglés, puis dossiers, puis onglets de passage.
    var allTabs: [Tab] { pinned + folders.flatMap(\.tabs) + loose }
    var tabCount: Int { allTabs.count }
    var isEmpty: Bool { allTabs.isEmpty }

    func tab(with id: UUID) -> Tab? { allTabs.first { $0.id == id } }
    func folder(with id: UUID) -> TabFolder? { folders.first { $0.id == id } }

    // MARK: - Écriture

    func append(_ tab: Tab) {
        loose.append(tab)
        current = tab
    }

    /// Retire l'onglet d'où qu'il vienne, et laisse le voisin le plus proche en courant.
    func remove(_ tab: Tab) {
        let order = allTabs
        let position = order.firstIndex { $0 === tab }
        detach(tab)

        guard current === tab else { return }
        let remaining = allTabs
        guard let position else { current = remaining.first; return }
        current = remaining.indices.contains(position) ? remaining[position] : remaining.last
    }

    func setPinned(_ shouldPin: Bool, tab: Tab) {
        guard tab.isPinned != shouldPin else { return }
        detach(tab)
        tab.isPinned = shouldPin
        // Désépinglé : en tête des onglets de passage, là où on vient de le manipuler.
        if shouldPin { pinned.append(tab) } else { loose.insert(tab, at: 0) }
    }

    func place(_ tab: Tab, at destination: Destination) {
        detach(tab)
        switch destination {
        case .before(let neighbour):
            insert(tab, before: neighbour, offset: 0)
        case .after(let neighbour):
            insert(tab, before: neighbour, offset: 1)
        case .into(let folder):
            tab.isPinned = false
            folder.tabs.append(tab)
            folder.isExpanded = true
        case .pinnedEnd:
            tab.isPinned = true
            pinned.append(tab)
        case .looseEnd:
            tab.isPinned = false
            loose.append(tab)
        }
    }

    @discardableResult
    func addFolder(named name: String) -> TabFolder {
        let folder = TabFolder(name: name)
        folders.append(folder)
        return folder
    }

    /// Supprimer un dossier ne ferme pas ses onglets : ils redeviennent des onglets de
    /// passage. Ranger et fermer sont deux gestes différents.
    func removeFolder(_ folder: TabFolder) {
        guard let index = folders.firstIndex(where: { $0 === folder }) else { return }
        folder.tabs.forEach { $0.isPinned = false }
        loose.insert(contentsOf: folder.tabs, at: 0)
        folders.remove(at: index)
    }

    func moveFolder(_ folder: TabFolder, before other: TabFolder) {
        guard folder !== other,
              let from = folders.firstIndex(where: { $0 === folder }) else { return }
        folders.remove(at: from)
        let to = folders.firstIndex(where: { $0 === other }) ?? folders.count
        folders.insert(folder, at: to)
    }

    static func symbol(forIndex index: Int) -> String {
        symbols[index % symbols.count]
    }

    // MARK: - Interne

    /// Retire l'onglet de toutes les collections. Sans ce passage obligé, un déplacement
    /// pourrait le laisser à deux endroits de l'ordre d'affichage.
    private func detach(_ tab: Tab) {
        pinned.removeAll { $0 === tab }
        loose.removeAll { $0 === tab }
        for folder in folders { folder.tabs.removeAll { $0 === tab } }
    }

    /// Le conteneur d'arrivée est celui du voisin : déposer sous le dernier onglet d'un
    /// dossier fait entrer dans ce dossier, déposer sous un onglet de passage en fait un.
    private func insert(_ tab: Tab, before neighbour: Tab, offset: Int) {
        if let index = pinned.firstIndex(where: { $0 === neighbour }) {
            tab.isPinned = true
            pinned.insert(tab, at: index + offset)
            return
        }
        for folder in folders {
            if let index = folder.tabs.firstIndex(where: { $0 === neighbour }) {
                tab.isPinned = false
                folder.tabs.insert(tab, at: index + offset)
                return
            }
        }
        if let index = loose.firstIndex(where: { $0 === neighbour }) {
            tab.isPinned = false
            loose.insert(tab, at: index + offset)
            return
        }
        tab.isPinned = false
        loose.append(tab)
    }
}
