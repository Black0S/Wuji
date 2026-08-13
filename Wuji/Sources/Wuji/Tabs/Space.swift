import AppKit

/// Un espace : un groupe d'onglets avec son propre onglet actif.
///
/// **Pas de couleur d'espace.** La spec (§4.3) réserve la couleur à la sécurité et lui
/// interdit tout autre emploi : si le rouge peut vouloir dire « connexion non chiffrée »
/// *ou* « espace Perso », il ne veut plus rien dire. Les espaces se distinguent donc par
/// un **symbole**, c'est-à-dire par la forme — ce qui reste lisible sous « Différencier
/// sans couleur » de macOS, contrairement à une pastille teintée.
@MainActor
final class Space {

    /// Le vocabulaire disponible. Des formes franchement différentes les unes des autres,
    /// pas des variantes du même dessin : à 14 pt, deux symboles voisins se confondent.
    static let symbols = ["square.stack", "briefcase", "book", "leaf", "bolt", "flask"]

    let id = UUID()
    var name: String
    var symbol: String
    var tabs: [Tab] = []
    var currentIndex = 0

    init(name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    var currentTab: Tab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    static func symbol(forIndex index: Int) -> String {
        symbols[index % symbols.count]
    }
}
