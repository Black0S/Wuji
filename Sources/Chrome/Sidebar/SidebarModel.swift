import AppKit

/// L'espace courant, tel que la sidebar a besoin de le connaître : un nom et une forme.
struct SpaceSnapshot {
    let name: String
    let symbol: String
}

/// Une ligne de la sidebar. Volontairement pauvre : ni `Tab`, ni `TabFolder`, ni index —
/// une **identité** et de quoi dessiner. C'est la frontière entre le modèle et son rendu.
enum SidebarItem {
    case tab(id: UUID, title: String, host: String, isLoading: Bool, favicon: NSImage?,
             depth: Int, isPlaying: Bool)
    case folder(id: UUID, name: String, isExpanded: Bool, count: Int)

    var id: UUID? {
        switch self {
        case .tab(let id, _, _, _, _, _, _): return id
        case .folder(let id, _, _, _):    return id
        }
    }

    /// **Ce qui oblige à refaire les lignes, par opposition à ce qui se met à jour.**
    ///
    /// L'identité, la nature et la profondeur décident de la structure ; le titre, l'hôte,
    /// la favicon, le chargement et le son n'en font pas partie — ils changent
    /// constamment pendant qu'une page arrive, et refaire la colonne à chacun d'eux
    /// coûtait la reconstruction de toutes les vues plusieurs fois par seconde.
    var shape: String {
        switch self {
        case .tab(let id, _, _, _, _, let depth, _): return "t:\(id):\(depth)"
        case .folder(let id, _, _, _):               return "f:\(id)"
        }
    }
}

/// Où l'on dépose un onglet en fin de glissement.
enum SidebarDrop {
    case before(UUID)
    case into(UUID)
    case end
    /// Les dossiers se réordonnent entre eux : ils ne peuvent ni entrer dans un autre
    /// dossier ni se glisser parmi les onglets, qui vivent dans une autre collection.
    case folderBefore(UUID)
    case folderEnd
}

/// La sidebar **ancrée**. Le contenu commence après elle, il ne passe pas dessous —
/// la page n'est jamais partiellement masquée.
