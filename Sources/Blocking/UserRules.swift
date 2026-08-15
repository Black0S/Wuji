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

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Wuji")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
