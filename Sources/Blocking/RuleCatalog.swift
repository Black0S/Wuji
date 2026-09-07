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
    /// La part des règles d'origine que la conversion a su rendre. Une liste à 100 % dit
    /// tout ce qu'elle disait ; en dessous, une partie de sa syntaxe n'a pas d'équivalent
    /// dans le format de WebKit — le cosmétique, surtout.
    let coverage: Double
    let parts: [Part]

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

    /// Lit le catalogue. **Rien n'est mis en cache sur le disque** : c'est un fichier de
    /// deux cents kilo-octets qu'on relit quand on ouvre la page, et le garder ferait
    /// afficher un catalogue d'hier sans qu'on sache lequel on regarde.
    static func fetch() async throws -> [RuleList] {
        let (data, response) = try await URLSession.shared.data(from: index)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Index.self, from: data)
        return decoded.lists
            .map { entry in
                RuleList(name: entry.name, source: entry.source, version: entry.version,
                         coverage: entry.coverage_pct,
                         parts: entry.files.map { .init(file: $0.file, rules: $0.rules,
                                                        bytes: $0.bytes) })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
