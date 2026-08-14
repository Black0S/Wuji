import Foundation

/// Une liste de filtres à laquelle on est abonné.
struct FilterList: Codable, Identifiable {
    var id: UUID
    var title: String
    var source: URL
    var isEnabled: Bool
    /// Le rayon du catalogue d'uBlock Origin : « ads », « privacy », « regions »…
    var group: String = "other"
    /// Le paquet auquel la liste appartient, quand uBlock en présente plusieurs sous un
    /// même titre — « EasyList – Annoyances » et ses cinq morceaux.
    var parent: String?
    /// Dernier téléchargement réussi.
    var updated: Date?
    /// Lignes reçues, et règles réellement traduites. Les deux comptent : l'écart dit ce
    /// que WebKit ne sait pas faire, et c'est une information honnête à afficher.
    var lines: Int
    var rules: Int

    init(title: String, source: URL, isEnabled: Bool = true, group: String = "other",
         parent: String? = nil) {
        id = UUID()
        self.title = title
        self.source = source
        self.isEnabled = isEnabled
        self.group = group
        self.parent = parent
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

    /// Le catalogue vient d'uBlock Origin, pas de nous.
    ///
    /// `assets.json` est le fichier qui décrit leurs abonnements : titres, rayons, adresses,
    /// et lesquels sont actifs par défaut. Le recopier à la main aurait vieilli en trois
    /// mois — les listes se scindent, se renomment et déménagent. On lit donc la source.
    ///
    /// Tant qu'il n'a jamais été lu, on part avec les quatre listes que tout le monde
    /// connaît : un bloqueur doit protéger avant d'avoir parlé au réseau.
    /// Le fichier vit dans le dépôt de l'extension, pas dans celui des filtres — l'adresse
    /// « évidente » côté uAssets rend un 404.
    static let catalogSource =
        URL(string: "https://raw.githubusercontent.com/gorhill/uBlock/master/assets/assets.json")!

    private static let seeds: [FilterList] = [
        FilterList(title: "uBlock filters — Ads",
                   source: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!,
                   group: "default"),
        FilterList(title: "uBlock filters — Privacy",
                   source: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!,
                   group: "default"),
        FilterList(title: "EasyList",
                   source: URL(string: "https://easylist.to/easylist/easylist.txt")!,
                   group: "ads"),
        FilterList(title: "EasyPrivacy",
                   source: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
                   group: "privacy")
    ]

    /// Les rayons, dans l'ordre où uBlock les présente.
    static let groupOrder = ["default", "ads", "privacy", "malware", "multipurpose",
                             "cookies", "social", "annoyances", "regions", "other"]

    /// Les régions comptent trente-huit entrées : repliées par défaut, comme chez uBlock.
    static let collapsedGroups: Set<String> = ["regions"]

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "default":      return "uBlock filters"
        case "ads":          return "Publicités"
        case "privacy":      return "Confidentialité"
        case "malware":      return "Protection anti-malware et sécurité"
        case "multipurpose": return "Tout usage"
        case "cookies":      return "Bannières de cookie"
        case "social":       return "Widgets de réseaux sociaux"
        case "annoyances":   return "Nuisances"
        case "regions":      return "Régions, langues"
        default:             return "Ajoutées par vous"
        }
    }

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
            lists = Self.seeds
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

    /// Relit le catalogue d'uBlock et fond le résultat avec ce qu'on a.
    ///
    /// Les choix de l'utilisateur survivent : une liste déjà connue garde son état actif ou
    /// inactif, et les listes ajoutées à la main ne sont jamais touchées. Une liste qui
    /// disparaît du catalogue disparaît d'ici aussi, sauf si elle était active — auquel cas
    /// la retirer sous les pieds de quelqu'un serait pire que de la garder.
    func refreshCatalog() async {
        var request = URLRequest(url: Self.catalogSource)
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var catalog: [FilterList] = []

        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  entry["content"] as? String == "filters",
                  let title = entry["title"] as? String else { continue }

            // `contentURL` est tantôt une adresse, tantôt une liste de miroirs : on prend
            // le premier qui parle http.
            let urls: [String]
            switch entry["contentURL"] {
            case let one as String: urls = [one]
            case let many as [String]: urls = many
            default: continue
            }
            // Le miroir d'uBlock quand il existe, l'adresse de l'auteur sinon : `uAssets`
            // republie une partie des listes, jamais toutes. Préférer le miroir, c'est un
            // hôte de moins à contacter et un fichier qu'uBlock a relu.
            guard let address = urls.first(where: { $0.contains("ublockorigin.github.io/uAssets") })
                    ?? urls.first(where: { $0.hasPrefix("http") }),
                  let source = URL(string: address) else { continue }

            // `group2` est le rayon que montre uBlock quand il diffère du rangement
            // interne : les avis de cookies et les widgets sociaux sortent des nuisances.
            let group = (entry["group2"] as? String) ?? (entry["group"] as? String) ?? "other"
            // uBlock active une liste régionale quand elle correspond à la langue du
            // système. On fait pareil : proposer trente-huit régions toutes cochées serait
            // absurde, n'en proposer aucune le serait aussi.
            let languages = ((entry["lang"] as? String) ?? "").split(separator: " ").map(String.init)
            let regional = !languages.isEmpty
            let isDefault = (entry["off"] as? Bool) != true
            let enabled = regional ? languages.contains(language) : isDefault

            // Deux entrées du catalogue peuvent viser le même fichier — les avis de
            // cookies y sont référencés deux fois, par EasyList et par AdGuard.
            guard !catalog.contains(where: { $0.source == source }) else { continue }
            catalog.append(FilterList(title: title, source: source, isEnabled: enabled,
                                      group: group, parent: entry["parent"] as? String))
            _ = key
        }
        guard !catalog.isEmpty else { return }

        // Fusion. **Le catalogue fait foi sur ce qu'il décrit** — titre, rayon, paquet —
        // et l'utilisateur sur ce qui le regarde : active ou non. Le reste, ce sont les
        // chiffres du dernier téléchargement, qu'on garde avec l'identifiant : c'est lui
        // qui nomme le fichier sur le disque, et le changer ferait tout retélécharger.
        var merged: [FilterList] = []
        for var entry in catalog {
            if let known = lists.first(where: { $0.source == entry.source }) {
                entry.id = known.id
                entry.isEnabled = known.isEnabled
                entry.updated = known.updated
                entry.lines = known.lines
                entry.rules = known.rules
            }
            merged.append(entry)
        }
        // Ce que l'utilisateur a ajouté lui-même survit ; ce qui vient d'un ancien
        // catalogue disparaît, fichier compris. Le garder « parce qu'il était actif »
        // reviendrait à continuer d'interroger des hôtes qu'on a décidé de ne plus
        // contacter.
        for known in lists {
            if merged.contains(where: { $0.source == known.source }) { continue }
            if known.group == "other" {
                merged.append(known)
            } else {
                // Sortie du catalogue : son fichier n'a plus de raison de rester.
                try? FileManager.default.removeItem(at: file(for: known))
            }
        }

        lists = merged.sorted {
            let left = Self.groupOrder.firstIndex(of: $0.group) ?? Self.groupOrder.count
            let right = Self.groupOrder.firstIndex(of: $1.group) ?? Self.groupOrder.count
            return left == right ? $0.title < $1.title : left < right
        }
        save()
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
