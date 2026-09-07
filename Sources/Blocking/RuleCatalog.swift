import Foundation

/// Le catalogue des listes de blocage — **et rien d'autre n'est embarqué**.
///
/// Wuji ne livre aucune liste. Ni dans son paquet, ni au premier lancement, ni en tâche de
/// fond : tant qu'on n'a rien demandé, il ne bloque rien et n'a rien téléchargé. C'est la
/// différence entre un navigateur qui vous laisse choisir et un navigateur qui a choisi
/// pour vous — et la seule qui rende le choix vérifiable, puisqu'une liste absente ne peut
/// pas se tromper en votre nom.
///
/// **Les règles viennent déjà au format de WebKit.** Le dépôt
/// [Wuji-Rules-List](https://github.com/Black0S/Wuji-Rules-List) récupère les listes
/// d'origine — AdGuard, EasyList, uBlock, les listes par langue — et les convertit en
/// bloqueur de contenu natif, celui que `WKContentRuleListStore` compile. Wuji n'a donc
/// aucun analyseur de syntaxe de filtres à maintenir, et surtout aucun moteur de blocage
/// écrit à la main : c'est WebKit qui filtre, dans son processus réseau, avant que la page
/// ne voie passer quoi que ce soit.
struct RuleList: Identifiable, Sendable, Equatable {

    /// Un morceau compilable. WebKit refuse au-delà de cent cinquante mille règles par
    /// liste : les grandes sont donc découpées à la conversion, et se recomposent ici.
    struct Part: Sendable, Equatable {
        let file: String
        let rules: Int
        let bytes: Int
    }

    let name: String
    /// Le nom du fichier d'origine — `AdGuard-Base-filter.txt`. Il sert d'identité : il ne
    /// change pas quand la liste est mise à jour, à la différence de la version.
    let source: String
    let version: String
    /// La famille à laquelle la liste appartient — « Publicité », « Sécurité », « Par
    /// langue »… Cent soixante et une lignes à plat ne se parcourent pas : c'est le groupe
    /// qui rend le catalogue lisible, et il vient du dépôt, pas d'un classement inventé ici.
    var group: String = RuleList.otherGroup
    var summary: String = ""
    /// La part des règles d'origine que la conversion a su rendre. Une liste à 100 % dit
    /// tout ce qu'elle disait ; en dessous, une partie de sa syntaxe n'a pas d'équivalent
    /// dans le format de WebKit — le cosmétique, surtout.
    let coverage: Double
    let parts: [Part]

    /// Le groupe des listes qu'on n'a pas su ranger. Nommé plutôt que vide : une section
    /// sans titre se lit comme un défaut d'affichage.
    static let otherGroup = "Divers"

    var id: String { source }
    var rules: Int { parts.reduce(0) { $0 + $1.rules } }
    var bytes: Int { parts.reduce(0) { $0 + $1.bytes } }
}

/// D'où viennent le catalogue et les règles.
enum RuleCatalog {

    /// La branche `dist` du dépôt : elle ne porte que le produit de la conversion, sans
    /// l'outillage ni les listes brutes. On lit les fichiers directement plutôt que par
    /// l'API de GitHub — pas de jeton, pas de quota, pas de compte.
    static let base = URL(string: "https://raw.githubusercontent.com/Black0S/Wuji-Rules-List/dist/")!

    static var index: URL { base.appending(path: "index.json") }
    static func file(_ name: String) -> URL { base.appending(path: name) }

    /// Ce que le catalogue publie, décodé.
    private struct Index: Decodable {
        struct Entry: Decodable {
            struct File: Decodable {
                let file: String
                let rules: Int
                let bytes: Int
            }
            let name: String
            let source: String
            let version: String
            let coverage_pct: Double
            let files: [File]
        }
        let generated_at: String
        let lists: [Entry]
    }

    /// Ce que la branche `main` sait de chaque liste : sa famille, ce qu'elle fait, sa
    /// langue. Le produit de la conversion ne le porte pas — c'est de la métadonnée de
    /// catalogue, pas des règles.
    static let metadata = URL(
        string: "https://raw.githubusercontent.com/Black0S/Wuji-Rules-List/main/filters/index.json")!

    private struct Metadata: Decodable {
        struct Entry: Decodable {
            let description: String?
            let group: String?
            let languages: [String]?
            let file: String?
        }
        let lists: [String: Entry]
    }

    /// Les familles du dépôt, en français. Traduites parce qu'elles s'affichent, et rangées
    /// dans l'ordre où l'on décide : ce qu'on vient chercher d'abord — la publicité, le
    /// pistage —, puis le reste, puis les cinquante-sept listes par langue qui n'intéressent
    /// que celui qui parle la langue.
    static let groups: [String: (label: String, rank: Int)] = [
        "Ad blocking":       ("Publicité", 0),
        "General":           ("Généralistes", 1),
        "Privacy":           ("Pistage et vie privée", 2),
        "Security":          ("Sécurité", 3),
        "Annoyances":        ("Gêneurs", 4),
        "Social widgets":    ("Boutons sociaux", 5),
        "Regional":          ("Régionales", 6),
        "Language-specific": ("Par langue", 7),
        "Other":             ("Divers", 8)
    ]

    static func rank(of group: String) -> Int {
        groups.values.first { $0.label == group }?.rank ?? 9
    }

    /// Lit le catalogue. **Rien n'est mis en cache sur le disque** : deux fichiers de deux
    /// cents kilo-octets relus quand on ouvre la page, et les garder ferait afficher un
    /// catalogue d'hier sans qu'on sache lequel on regarde.
    ///
    /// Les deux index sont lus **en parallèle** : ils viennent de deux branches, ne
    /// dépendent pas l'un de l'autre, et les enchaîner doublerait l'attente pour rien. La
    /// métadonnée est facultative — sans elle, tout atterrit dans « Divers » et le
    /// catalogue reste utilisable.
    static func fetch() async throws -> [RuleList] {
        async let rules = data(from: index)
        async let meta = try? data(from: metadata)

        let decoded = try JSONDecoder().decode(Index.self, from: try await rules)
        let info = (try? await meta).flatMap {
            try? JSONDecoder().decode(Metadata.self, from: $0)
        }
        // Rangé par nom de fichier : c'est la seule clé que les deux index partagent.
        var byFile: [String: Metadata.Entry] = [:]
        for entry in info?.lists.values ?? [:].values {
            if let file = entry.file { byFile[file] = entry }
        }

        return decoded.lists
            .map { entry in
                let extra = byFile[entry.source]
                let group = extra?.group.flatMap { groups[$0]?.label } ?? RuleList.otherGroup
                return RuleList(
                    name: entry.name, source: entry.source, version: entry.version,
                    group: group, summary: extra?.description ?? "",
                    coverage: entry.coverage_pct,
                    parts: entry.files.map { .init(file: $0.file, rules: $0.rules,
                                                   bytes: $0.bytes) })
            }
            .sorted {
                let (a, b) = (rank(of: $0.group), rank(of: $1.group))
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
