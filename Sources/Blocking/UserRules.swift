import Foundation

/// Ce que l'utilisateur écrit : ses règles, et les sites qu'il laisse tranquilles.
///
/// **Il n'y a plus de catalogue, plus d'abonnement, plus de téléchargement.** Les listes de
/// Wuji arrivent avec l'application ; cette classe ne s'occupe donc que de ce qui vient de
/// la personne devant l'écran, et cette part-là ne part nulle part.
@MainActor
final class UserRules {

    /// **Au format de WebKit, comme les règles livrées.** Il n'y a plus qu'un seul format
    /// dans toute l'application : ce que le sélecteur d'élément écrit est exactement ce que
    /// le moteur compile, et il n'existe nulle part de traduction à maintenir.
    private(set) var rules: [String] = []

    var onChange: (() -> Void)?

    private let file: URL

    init(directory: URL = Storage.directory) {
        file = directory.appendingPathComponent("rules.json")

        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            rules = stored
        }
    }

    func add(_ rule: String) {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty, !rules.contains(rule) else { return }
        rules.append(rule)
        save()
    }

    /// Remplace une règle **à sa place**.
    ///
    /// Retirer puis rajouter l'aurait renvoyée en fin de liste : on corrige une règle, on
    /// ne la réécrit pas — et une liste qui se réordonne à chaque correction ne se relit
    /// plus. Rend `false` si la règle n'existe plus, si le remplacement est vide, ou s'il
    /// ferait un doublon.
    @discardableResult
    func replace(_ rule: String, with replacement: String) -> Bool {
        let replacement = replacement.trimmingCharacters(in: .whitespaces)
        guard !replacement.isEmpty, let index = rules.firstIndex(of: rule) else { return false }
        guard replacement == rule || !rules.contains(replacement) else { return false }
        rules[index] = replacement
        save()
        return true
    }

    func remove(_ rule: String) {
        rules.removeAll { $0 == rule }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: file, options: .atomic)
        }
        onChange?()
    }
}
