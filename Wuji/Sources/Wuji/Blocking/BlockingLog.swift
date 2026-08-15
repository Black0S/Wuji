import Foundation

/// Le journal de ce que le blocage a fait.
///
/// **Ce n'est pas un compteur, et surtout pas un compteur de requêtes bloquées.** Les
/// règles de contenu s'exécutent dans WebKit, qui ne remonte rien : personne ne peut dire
/// combien de requêtes il a arrêtées. Ce journal ne prétend donc pas à l'exhaustivité — il
/// note ce que Wuji a **vraiment** observé, et rien d'autre :
///
/// - une adresse principale refusée, parce que l'échec nous revient ;
/// - une ressource qui n'est jamais arrivée, parce que la page nous le signale.
///
/// Un journal partiel et honnête vaut mieux qu'un total inventé : on sait ce qu'on lit.
@MainActor
final class BlockingLog {

    enum Kind: String, Codable {
        case blocked, refused

        var label: String {
            switch self {
            case .blocked: return "page bloquée"
            case .refused: return "non chargé"
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let kind: Kind
        let host: String
        let detail: String
    }

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    /// Borné, et en mémoire seulement. Un journal de blocage écrit sur le disque serait un
    /// second historique — celui des sites visités, sous un autre nom.
    private static let limit = 500

    func record(_ kind: Kind, host: String, detail: String) {
        entries.insert(Entry(date: Date(), kind: kind, host: host, detail: detail), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        onChange?()
    }

    func clear() {
        entries = []
        onChange?()
    }
}
