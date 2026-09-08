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
/// d'origine chez leurs mainteneurs — AdGuard, EasyList, uBlock, Fanboy, HaGeZi — et les
/// convertit en bloqueur de contenu natif, celui que `WKContentRuleListStore` compile. Wuji
/// n'a donc aucun analyseur de syntaxe de filtres à maintenir, et surtout aucun moteur de
/// blocage écrit à la main : c'est WebKit qui filtre, dans son processus réseau, avant que
/// la page ne voie passer quoi que ce soit.
struct RuleList: Identifiable, Sendable, Equatable {

    /// Un morceau compilable. WebKit refuse au-delà de cent cinquante mille règles par
    /// liste : les grandes sont donc découpées à la conversion, et se recomposent ici.
    struct Part: Sendable, Equatable {
        let file: String
        let rules: Int
        let bytes: Int
    }

    /// L'identité de la liste dans le catalogue — `adguard-base`.
    ///
    /// **Une clé qui ne dit rien du chemin.** C'était le nom du fichier d'origine ; un
    /// dépôt qui range ses sources autrement changeait alors l'identité de toutes ses
    /// listes, c'est-à-dire décochait tout chez celui qui les avait cochées. Le dépôt
    /// publie maintenant un identifiant explicite, et c'est lui qu'on retient.
    let id: String
    let name: String
    /// Le fichier d'origine. Il ne sert plus d'identité, mais il reste la seule clé que
    /// partagent l'ancien catalogue et le nouveau : c'est par lui que passe la reprise.
    let source: String
    /// L'empreinte du fichier d'origine. **C'est elle qui dit si la liste a changé**, et
    /// rien d'autre : une version absente — vingt-deux listes n'en publient pas — ou une
    /// conversion améliorée qui ne touche pas à la version d'origine échappaient toutes
    /// deux à la comparaison.
    var sourceHash: String = ""
    let version: String
    /// La famille, telle que le dépôt la publie : le mainteneur de la liste — AdGuard,
    /// EasyList, uBlock Origin. Soixante et onze lignes à plat ne se parcourent pas ; c'est
    /// le groupe qui rend le catalogue lisible, et il vient du dépôt, pas d'ici.
    var group: String = RuleList.otherGroup
    var summary: String = ""
    /// Chez qui la liste est maintenue, et sous quelle licence. Affichés parce qu'une liste
    /// est le travail de quelqu'un, et qu'on l'installe plus volontiers en sachant de qui.
    var homepage: String = ""
    var license: String = ""
    /// La part des règles d'origine que la conversion a su rendre. Une liste à 100 % dit
    /// tout ce qu'elle disait ; en dessous, une partie de sa syntaxe n'a pas d'équivalent
    /// dans le format de WebKit — le cosmétique, surtout.
    let coverage: Double
    /// Les règles **distinctes** que la conversion produit.
    ///
    /// Pas la somme des fichiers : une liste découpée en tranches réplique ses exceptions
    /// dans chacune, et l'addition comptait donc plusieurs fois la même règle. Le dépôt
    /// publie les deux nombres depuis qu'il le dit ; celui-ci est l'honnête.
    var uniqueRules: Int = 0
    let parts: [Part]
    /// Le fichier des règles à injection, quand la liste en a un — celles que le format de
    /// WebKit ne sait pas porter. Cinquante listes sur soixante et onze.
    var extendedFile: String?

    /// Le groupe des listes qu'on n'a pas su ranger. Nommé plutôt que vide : une section
    /// sans titre se lit comme un défaut d'affichage.
    static let otherGroup = "Divers"

    var rules: Int { uniqueRules > 0 ? uniqueRules : parts.reduce(0) { $0 + $1.rules } }
    var bytes: Int { parts.reduce(0) { $0 + $1.bytes } }

    /// Ce qui doit changer pour qu'une liste soit dite périmée. Voir `sourceHash`.
    var build: String { sourceHash.isEmpty ? version + "|\(rules)" : sourceHash + "|\(rules)" }
}

/// D'où viennent le catalogue et les règles.
enum RuleCatalog {

    /// La branche `dist` du dépôt : elle ne porte que le produit de la conversion, sans
    /// l'outillage ni les listes brutes. On lit les fichiers directement plutôt que par
    /// l'API de GitHub — pas de jeton, pas de quota, pas de compte.
    static let base = URL(string: "https://raw.githubusercontent.com/Black0S/Wuji-Rules-List/dist/")!

    static var index: URL { base.appending(path: "index.json") }
    static func file(_ name: String) -> URL { base.appending(path: name) }

    /// Où vivent les règles à injection.
    ///
    /// Le dépôt les nommait sans leur dossier, ce qui donnait un 404 en suivant l'index à
    /// la lettre ; il les nomme correctement depuis. On accepte encore les deux écritures :
    /// un consommateur qui casse au premier changement de chemin n'est pas robuste, et
    /// celui-ci n'a rien à y perdre.
    static func extended(_ name: String) -> URL {
        base.appending(path: name.contains("/") ? name : "extended/" + name)
    }

    /// Ce que le catalogue publie, décodé.
    ///
    /// **Tout est facultatif sauf le nom et les fichiers.** Le dépôt a changé de schéma une
    /// fois ; il le refera. Un décodeur qui exige un champ tombe alors en entier — et l'on
    /// se retrouve avec un catalogue vide qu'on lit comme « il n'y a rien à activer ».
    private struct Index: Decodable {
        struct Entry: Decodable {
            struct File: Decodable {
                let file: String
                let rules: Int
                let bytes: Int
            }
            let id: String?
            let name: String
            let source: String?
            let source_sha256: String?
            let version: String?
            let group: String?
            let homepage: String?
            let license: String?
            let coverage_pct: Double?
            let rules_unique: Int?
            let files: [File]
            let extended_file: String?
        }
        let lists: [Entry]
    }

    /// L'ordre des familles.
    ///
    /// **Il est d'ici, à la différence des familles elles-mêmes.** Le dépôt range par
    /// mainteneur ; ce qu'il ne peut pas savoir, c'est ce qu'on vient chercher en premier.
    /// Les listes générales d'abord, les listes par langue et par région ensuite — on ne
    /// parcourt les dix-sept listes régionales d'EasyList que si l'on parle la langue.
    /// Une famille inconnue passe après, par ordre alphabétique : un dépôt qui ajoute un
    /// mainteneur ne doit pas voir ses listes disparaître d'un classement écrit ici.
    static let order = ["AdGuard", "AdGuard DNS", "EasyList", "uBlock Origin", "Fanboy",
                        "HaGeZi", "Dandelion Sprout", "Phishing Army", "Stevo's AI Blocklist",
                        "AdGuard (langues)", "EasyList (regions)"]

    static func rank(of group: String) -> Int {
        order.firstIndex(of: group) ?? order.count
    }

    /// Lit le catalogue. **Rien n'est mis en cache sur le disque** : deux cents kilo-octets
    /// relus quand on ouvre la page, et les garder ferait afficher un catalogue d'hier sans
    /// qu'on sache lequel on regarde.
    ///
    /// **Une seule requête.** Il y en avait deux : le dépôt publiait la métadonnée — famille,
    /// description — dans un second index, sur l'autre branche. Elle a rejoint le catalogue,
    /// et le second index ne porte plus qu'une description vide pour soixante-dix listes sur
    /// soixante et onze. Une requête qui ne rapporte rien est une requête à supprimer.
    static func fetch() async throws -> [RuleList] {
        let decoded = try JSONDecoder().decode(Index.self, from: try await data(from: index))

        return decoded.lists
            .map { entry in
                RuleList(
                    // Le dépôt d'avant n'avait pas d'identifiant : le nom du fichier en
                    // tenait lieu, et il faut pouvoir lire les deux le temps d'une reprise.
                    id: entry.id ?? entry.source ?? entry.name,
                    name: entry.name,
                    source: entry.source ?? entry.id ?? entry.name,
                    sourceHash: entry.source_sha256 ?? "",
                    version: entry.version ?? "",
                    group: entry.group ?? RuleList.otherGroup,
                    homepage: entry.homepage ?? "",
                    license: entry.license ?? "",
                    coverage: entry.coverage_pct ?? 0,
                    uniqueRules: entry.rules_unique ?? 0,
                    parts: entry.files.map { .init(file: $0.file, rules: $0.rules,
                                                   bytes: $0.bytes) },
                    extendedFile: entry.extended_file)
            }
            .sorted {
                let (a, b) = (rank(of: $0.group), rank(of: $1.group))
                if a != b { return a < b }
                if $0.group != $1.group { return $0.group < $1.group }
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
