import Foundation

/// Le journal du blocage : ce que Wuji a **fait**, et rien qu'il n'ait fait.
///
/// **Ce journal ne compte pas les requêtes bloquées, et c'est une limite, pas un oubli.**
/// Les règles sont appliquées par WebKit dans son processus réseau, et il n'en rend aucun
/// compte : mesuré, aucun rappel de blocage n'existe pour une application tierce — ni dans
/// `WKNavigationDelegate`, ni ailleurs. Un compteur « 247 éléments bloqués sur cette page »
/// serait un nombre inventé, et c'est exactement ce qu'un journal ne doit pas contenir.
///
/// Ce qu'il contient est vrai et vérifiable : chaque liste installée avec son nombre de
/// règles et le temps qu'elle a coûté, chaque échec avec sa raison, chaque règle posée à la
/// main avec son site et son sélecteur. C'est un journal d'actions, pas un compteur de
/// trophées — et c'est ce qu'on consulte quand on se demande pourquoi une page se comporte
/// autrement qu'hier.
///
/// **Il ne quitte pas la machine.** Il porte les sites où l'on a posé des règles : c'est une
/// information sur soi.
@MainActor
final class BlockingLog {

    enum Kind: String, Codable {
        case installed, removed, updated, failed, hidden, unhidden, catalog, swept, paused, resumed
    }

    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let kind: Kind
        /// De quoi il s'agit : le nom d'une liste, un site, le catalogue.
        let subject: String
        /// Ce qu'il faut savoir de plus — un compte de règles, un sélecteur, une raison.
        let detail: String

        init(_ kind: Kind, _ subject: String, _ detail: String = "") {
            id = UUID()
            date = Date()
            self.kind = kind
            self.subject = subject
            self.detail = detail
        }

        var label: String {
            switch kind {
            case .installed: return "Liste installée"
            case .removed:   return "Liste retirée"
            case .updated:   return "Liste mise à jour"
            case .failed:    return "Échec"
            case .hidden:    return "Élément masqué"
            case .unhidden:  return "Règles retirées"
            case .catalog:   return "Catalogue"
            case .swept:     return "Magasin nettoyé"
            case .paused:    return "Blocage suspendu"
            case .resumed:   return "Blocage repris"
            }
        }

        var isFailure: Bool { kind == .failed }
    }

    /// **Borné, et volontairement court.** Un journal qui grossit sans fin finit par être
    /// le plus gros fichier de l'application, et personne ne remonte au-delà de quelques
    /// centaines de lignes. Les plus récentes d'abord : c'est celles qu'on vient lire.
    private static let capacity = 400
    private static let file = "journal-blocage.json"

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    init() {
        entries = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private var url: URL { Storage.directory.appending(path: Self.file) }

    func record(_ kind: Kind, _ subject: String, _ detail: String = "") {
        entries.insert(Entry(kind, subject, detail), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        persist()
        onChange?()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: url)
        onChange?()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
