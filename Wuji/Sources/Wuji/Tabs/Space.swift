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

/// Un espace : des dossiers, et des onglets de passage.
///
/// **Deux collections plutôt qu'une seule avec des invariants.** Un tableau unique aurait
/// demandé de recalculer des plages d'index à chaque action dès l'apparition des dossiers.
/// Deux listes nommées disent ce qu'elles contiennent et ne peuvent pas se désynchroniser.
///
/// **L'onglet courant est une référence, pas un index.** Un index désigne une position, et
/// une position change dès qu'on déplace ou ferme quelque chose ailleurs. C'est la
/// source de bugs classique de ce genre d'interface : on croit désigner un onglet, on
/// désigne un rang.
///
/// **Pas de couleur d'espace.** Elle a existé puis a été retirée : la spec §4.3 réserve la
/// couleur à la sécurité, et un rouge qui peut signifier « connexion non chiffrée » *ou*
/// « espace Perso » ne signifie plus rien. Les espaces se distinguent par leur **symbole**,
/// donc par la forme — ce qui reste lisible sous « Différencier sans couleur » de macOS,
/// contrairement à une pastille teintée.
@MainActor
final class Space {

    /// Des formes franchement différentes les unes des autres, pas des variantes du même
    /// dessin : à 14 pt, deux symboles voisins se confondent.
    static let symbols = ["square.stack", "briefcase", "book", "leaf", "bolt", "flask"]

    /// Où déposer un onglet. Le conteneur d'arrivée se déduit du voisin quand on dépose
    /// entre deux lignes — c'est ce qui permet de sortir d'un dossier en glissant sous lui.
    enum Destination {
        case before(Tab)
        case after(Tab)
        case into(TabFolder)
        case looseEnd
    }

    let id = UUID()
    var name: String
    var symbol: String

    private(set) var folders: [TabFolder] = []
    private(set) var loose: [Tab] = []
    var current: Tab?

    init(name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    // MARK: - Lecture

    /// L'ordre d'affichage : dossiers, puis onglets de passage.
    var allTabs: [Tab] { folders.flatMap(\.tabs) + loose }
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

    func place(_ tab: Tab, at destination: Destination) {
        detach(tab)
        switch destination {
        case .before(let neighbour):
            insert(tab, before: neighbour, offset: 0)
        case .after(let neighbour):
            insert(tab, before: neighbour, offset: 1)
        case .into(let folder):
            folder.tabs.append(tab)
            folder.isExpanded = true
        case .looseEnd:
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

    func moveFolderToEnd(_ folder: TabFolder) {
        guard let from = folders.firstIndex(where: { $0 === folder }) else { return }
        folders.remove(at: from)
        folders.append(folder)
    }

    static func symbol(forIndex index: Int) -> String {
        symbols[index % symbols.count]
    }

    // MARK: - Interne

    /// Retire l'onglet de toutes les collections. Sans ce passage obligé, un déplacement
    /// pourrait le laisser à deux endroits de l'ordre d'affichage.
    private func detach(_ tab: Tab) {
        loose.removeAll { $0 === tab }
        for folder in folders { folder.tabs.removeAll { $0 === tab } }
    }

    /// Le conteneur d'arrivée est celui du voisin : déposer sous le dernier onglet d'un
    /// dossier fait entrer dans ce dossier, déposer sous un onglet de passage en fait un.
    private func insert(_ tab: Tab, before neighbour: Tab, offset: Int) {
        for folder in folders {
            if let index = folder.tabs.firstIndex(where: { $0 === neighbour }) {
                folder.tabs.insert(tab, at: index + offset)
                return
            }
        }
        if let index = loose.firstIndex(where: { $0 === neighbour }) {
            loose.insert(tab, at: index + offset)
            return
        }
        loose.append(tab)
    }
}
