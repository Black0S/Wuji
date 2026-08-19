import Foundation

/// Une page mise de côté.
struct Favorite: Codable {
    let id: UUID
    var url: URL
    var title: String
    let added: Date

    init(url: URL, title: String) {
        id = UUID()
        self.url = url
        self.title = title
        added = Date()
    }
}

/// Les favoris, sur le disque.
///
/// **JSON, comme la session, et pour la même raison** : quelques dizaines de lignes qu'on
/// réécrit en entier. Le fichier reste lisible et modifiable à la main — c'est ce que veut
/// dire « vos données vous appartiennent » quand on n'a pas de compte à proposer.
///
/// L'ordre est celui de l'ajout, le plus récent en tête. Un favori sert à retrouver ce
/// qu'on a mis de côté ; ce qu'on vient de mettre de côté est ce qu'on cherche le plus.
@MainActor
final class FavoritesStore {

    private(set) var items: [Favorite] = []
    private let url: URL

    var onChange: (() -> Void)?

    init(directory: URL = Storage.directory) {
        url = directory.appendingPathComponent("favorites.json")

        let decoder = JSONDecoder()
        // Même stratégie qu'à l'écriture, sinon le fichier qu'on vient d'écrire ne se
        // relit pas. Et une date en ISO reste lisible pour qui ouvre le fichier.
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let stored = try? decoder.decode([Favorite].self, from: data) {
            items = stored
        }
    }

    var fileURL: URL { url }

    func contains(_ page: URL) -> Bool {
        items.contains { $0.url == page }
    }

    func item(id: String?) -> Favorite? {
        items.first { $0.id.uuidString == id }
    }

    /// Ajoute, ou retire si la page y est déjà. Un même raccourci pour les deux sens :
    /// `⌘D` sur une page déjà en favori ne peut vouloir dire que « finalement, non ».
    /// Rend `true` si la page vient d'être ajoutée.
    @discardableResult
    func toggle(url page: URL, title: String) -> Bool {
        if let index = items.firstIndex(where: { $0.url == page }) {
            items.remove(at: index)
            save()
            return false
        }
        items.insert(Favorite(url: page, title: title), at: 0)
        save()
        return true
    }

    func remove(id: String?) {
        guard let id else { return }
        items.removeAll { $0.id.uuidString == id }
        save()
    }

    func rename(id: String, to title: String) {
        guard let index = items.firstIndex(where: { $0.id.uuidString == id }) else { return }
        items[index].title = title
        save()
    }

    /// Écriture atomique : une liste à moitié écrite au moment d'un plantage serait pire
    /// que pas de liste du tout.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: url, options: .atomic)
        }
        onChange?()
    }
}
