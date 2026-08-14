import Foundation

/// Une liste de filtres à laquelle on est abonné.
struct FilterList: Codable, Identifiable {
    let id: UUID
    var title: String
    var source: URL
    var isEnabled: Bool
    /// Dernier téléchargement réussi.
    var updated: Date?
    /// Lignes reçues, et règles réellement traduites. Les deux comptent : l'écart dit ce
    /// que WebKit ne sait pas faire, et c'est une information honnête à afficher.
    var lines: Int
    var rules: Int

    init(title: String, source: URL, isEnabled: Bool = true) {
        id = UUID()
        self.title = title
        self.source = source
        self.isEnabled = isEnabled
        lines = 0
        rules = 0
    }
}

/// Les abonnements et les règles de l'utilisateur.
///
/// **Wuji n'entretient aucune liste.** Maintenir un filtre à jour est un travail à plein
/// temps que des projets font mieux depuis quinze ans ; une liste maison serait périmée le
/// mois suivant et donnerait une fausse impression de protection. Les listes viennent donc
/// d'uBlock Origin, d'EasyList et d'AdGuard, telles qu'elles sont publiées.
///
/// **Ce que Wuji tient, c'est ce que l'utilisateur écrit** : ses exceptions et ses règles.
/// Cette liste-là ne vient de nulle part ailleurs et ne part nulle part.
///
/// Le téléchargement est explicite : au premier lancement une seule fois, puis quand on le
/// demande. Pas de rafraîchissement silencieux toutes les heures — c'est du trafic que
/// personne n'a demandé, et l'argument de ce navigateur est précisément de ne pas en faire.
@MainActor
final class FilterListStore {

    private(set) var lists: [FilterList] = []

    /// Les règles écrites ici, au format Adblock. C'est ce que le sélecteur d'élément
    /// alimente, et ce qu'on peut corriger à la main.
    var userRules: [String] = [] { didSet { save() } }

    var onChange: (() -> Void)?

    private let directory: URL
    private let index: URL

    /// Les abonnements proposés au départ. Ce sont les listes de référence du domaine ;
    /// on les cite par leur nom pour qu'on sache ce qu'on télécharge.
    private static let defaults: [FilterList] = [
        FilterList(title: "uBlock Origin — filtres",
                   source: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!),
        FilterList(title: "uBlock Origin — vie privée",
                   source: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!),
        FilterList(title: "EasyList",
                   source: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(title: "EasyPrivacy",
                   source: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        FilterList(title: "Liste FR",
                   source: URL(string: "https://easylist-downloads.adblockplus.org/liste_fr.txt")!),
        FilterList(title: "AdGuard — base",
                   source: URL(string: "https://filters.adtidy.org/extension/ublock/filters/2.txt")!,
                   isEnabled: false)
    ]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Wuji/filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = directory.appendingPathComponent("lists.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: index),
           let stored = try? decoder.decode(Stored.self, from: data) {
            lists = stored.lists
            userRules = stored.userRules
        } else {
            lists = Self.defaults
        }
    }

    private struct Stored: Codable {
        var lists: [FilterList]
        var userRules: [String]
    }

    // MARK: - Lecture

    /// Le texte d'une liste, tel qu'il a été téléchargé. Nul tant qu'elle ne l'a pas été.
    func text(for list: FilterList) -> String? {
        try? String(contentsOf: file(for: list), encoding: .utf8)
    }

    var hasContent: Bool {
        lists.contains { $0.isEnabled && FileManager.default.fileExists(atPath: file(for: $0).path) }
    }

    var enabled: [FilterList] { lists.filter(\.isEnabled) }

    // MARK: - Écriture

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[index].isEnabled = isEnabled
        save()
    }

    func remove(id: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: file(for: lists[index]))
        lists.remove(at: index)
        save()
    }

    @discardableResult
    func add(title: String, source: URL) -> FilterList? {
        guard !lists.contains(where: { $0.source == source }) else { return nil }
        let list = FilterList(title: title, source: source)
        lists.append(list)
        save()
        return list
    }

    func record(lines: Int, rules: Int, for id: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[index].lines = lines
        lists[index].rules = rules
        save()
    }

    // MARK: - Téléchargement

    /// Rend le nombre de listes effectivement mises à jour.
    ///
    /// Une liste qui échoue ne fait pas échouer les autres, et surtout n'efface pas ce
    /// qu'on avait déjà : sans réseau, l'ancienne copie protège toujours.
    @discardableResult
    func update(_ list: FilterList) async -> Bool {
        var request = URLRequest(url: list.source)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return false }

        try? text.write(to: file(for: list), atomically: true, encoding: .utf8)
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index].updated = Date()
            lists[index].lines = text.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        }
        save()
        return true
    }

    @discardableResult
    func updateAll() async -> Int {
        var updated = 0
        for list in lists where list.isEnabled {
            if await update(list) { updated += 1 }
        }
        return updated
    }

    // MARK: - Interne

    private func file(for list: FilterList) -> URL {
        directory.appendingPathComponent("\(list.id.uuidString).txt")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Stored(lists: lists, userRules: userRules)) {
            try? data.write(to: index, options: .atomic)
        }
        onChange?()
    }
}
