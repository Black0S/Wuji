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

    /// Le symbole des espaces privés, et **le leur seulement**.
    ///
    /// Il n'est ni dans la palette de choix ni modifiable : un espace privé doit se
    /// reconnaître du premier coup d'œil, et se reconnaître *toujours* de la même façon.
    /// Un symbole qu'on pourrait changer ferait de cette reconnaissance une convention
    /// personnelle — donc quelque chose qu'on oublie au mauvais moment.
    static let privateSymbol = "eye.slash"

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
    var symbol: String {
        didSet {
            // Un espace privé porte son symbole quoi qu'on lui demande. La règle est ici
            // et pas seulement dans le menu qui la faisait respecter : une reconnaissance
            // visuelle ne doit pas dépendre de l'endroit d'où vient la modification.
            if isPrivate, symbol != Self.privateSymbol { symbol = Self.privateSymbol }
        }
    }

    /// **Un espace privé ne laisse rien, et ne cesse jamais de l'être.**
    ///
    /// Ni historique, ni session sur le disque, ni cookies qui survivent : ses vues web
    /// travaillent sur un magasin de données éphémère, que WebKit efface avec lui. C'est
    /// une propriété de l'espace et non d'une fenêtre — on garde ses onglets rangés comme
    /// les autres, et on bascule d'un monde à l'autre par le sélecteur d'espaces.
    ///
    /// **C'est une constante, et ce n'était qu'un interrupteur.** On pouvait rendre privé
    /// un espace existant, et rendre normal un espace privé — deux promesses que le code
    /// ne pouvait pas tenir. Le magasin de données est choisi à la naissance de chaque vue
    /// web : basculer un espace ne changeait rien pour les onglets déjà ouverts, qui
    /// continuaient d'écrire sur le disque sous un symbole disant le contraire. Dans
    /// l'autre sens, c'était pire : ce qu'un espace privé avait promis de ne pas garder se
    /// serait retrouvé dans une session enregistrée.
    ///
    /// Un espace privé naît privé — `⇧⌥N`, et rien d'autre — et le reste jusqu'à sa
    /// fermeture, qui l'efface.
    let isPrivate: Bool

    private(set) var folders: [TabFolder] = []
    private(set) var loose: [Tab] = []
    var current: Tab?

    private init(name: String, symbol: String, isPrivate: Bool) {
        self.name = name
        self.symbol = symbol
        self.isPrivate = isPrivate
    }

    convenience init(name: String, symbol: String) {
        self.init(name: name, symbol: symbol, isPrivate: false)
    }

    /// Le seul chemin vers un espace privé. Il n'y en a pas d'autre, et c'est le sujet :
    /// la confidentialité se décide à la création parce qu'elle ne peut pas se décider
    /// après coup sans mentir sur ce qui a déjà été écrit.
    static func makePrivate(named name: String = "Privé") -> Space {
        Space(name: name, symbol: privateSymbol, isPrivate: true)
    }

    // MARK: - Lecture

    /// L'ordre d'affichage : dossiers, puis onglets de passage.
    var allTabs: [Tab] { folders.flatMap(\.tabs) + loose }

    /// Parcourt les onglets **sans construire la liste**.
    ///
    /// `allTabs` alloue deux tableaux à chaque appel — un pour les dossiers aplatis, un
    /// pour la concaténation. C'est invisible quand on l'affiche, et c'est le seul de nos
    /// symboles qui soit ressorti d'un profil pris pendant le chargement d'une page lourde :
    /// il est appelé sur le chemin critique de chaque navigation, pour retrouver l'onglet
    /// qui porte une vue web. Chercher sans allouer coûte une boucle et rien d'autre.
    func firstTab(where matches: (Tab) -> Bool) -> Tab? {
        for folder in folders {
            for tab in folder.tabs where matches(tab) { return tab }
        }
        for tab in loose where matches(tab) { return tab }
        return nil
    }

    var tabCount: Int { folders.reduce(loose.count) { $0 + $1.tabs.count } }
    var isEmpty: Bool { tabCount == 0 }

    func tab(with id: UUID) -> Tab? { firstTab { $0.id == id } }
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

    /// Réinsère un onglet à une place connue — la reprise d'un onglet fermé.
    ///
    /// `place(_:at:)` ne sait viser qu'un voisin, et un voisin peut avoir disparu entre
    /// la fermeture et la reprise. Ici la place est un rang dans un conteneur nommé, borné
    /// à ce qui existe encore : l'onglet revient où il était, ou au plus près.
    func restore(_ tab: Tab, folder folderID: UUID?, index: Int) {
        detach(tab)
        if let folder = folderID.flatMap(folder(with:)) {
            folder.tabs.insert(tab, at: min(max(0, index), folder.tabs.count))
            folder.isExpanded = true
        } else {
            loose.insert(tab, at: min(max(0, index), loose.count))
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
