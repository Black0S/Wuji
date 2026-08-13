import AppKit

/// Un espace : un groupe d'onglets avec son propre onglet actif.
///
/// **Sur la couleur.** La spec §4.3 la réserve à la sécurité, au motif qu'un rouge qui peut
/// signifier « connexion non chiffrée » *ou* « espace Perso » ne signifie plus rien. La
/// décision de produit est allée dans l'autre sens, alors la règle de cohabitation est
/// écrite ici : **la couleur d'un espace ne teinte qu'une pastille**, jamais un liseré ni
/// une grande surface. Le signal de sécurité garde pour lui une forme et une position que
/// rien d'autre n'occupe — un trait sur tout le pourtour du contenu.
///
/// Le **symbole** reste porteur de sens à égalité avec la couleur, et non en décoration :
/// c'est ce qui laisse les espaces distinguables sous « Différencier sans couleur » de
/// macOS, et pour les 8 % d'hommes qui confondent le rouge et le vert.
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

    let id = UUID()
    var name: String
    var symbol: String
    var tint: Tint = .none
    var tabs: [Tab] = []
    var currentIndex = 0

    init(name: String, symbol: String, tint: Tint = .none) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }

    var currentTab: Tab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    /// Invariant tenu par cette classe : **les onglets épinglés occupent toujours le
    /// début du tableau**. Deux listes séparées obligeraient à traduire les index dans
    /// les deux sens à chaque action ; une seule liste ordonnée évite toute cette
    /// arithmétique, au prix d'un déplacement à l'épinglage.
    var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    func setPinned(_ pinned: Bool, at index: Int) {
        guard tabs.indices.contains(index), tabs[index].isPinned != pinned else { return }
        let tab = tabs[index]
        let staying = currentTab

        tab.isPinned = pinned
        tab.pinnedURL = pinned ? tab.url : nil

        tabs.remove(at: index)
        // Épinglé : à la fin du bloc épinglé. Désépinglé : juste après ce bloc, donc en
        // tête des onglets ordinaires — il reste sous les yeux, là où on l'a laissé.
        tabs.insert(tab, at: pinnedCount)

        if let staying, let position = tabs.firstIndex(where: { $0 === staying }) {
            currentIndex = position
        }
    }

    static func symbol(forIndex index: Int) -> String {
        symbols[index % symbols.count]
    }
}
