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
    /// Fournie avec Wuji, et maintenue dans son dépôt. Elle ne se télécharge pas : elle
    /// arrive avec l'application et change quand l'application change.
    var isBuiltIn: Bool = false
    /// Ce que le serveur a répondu la dernière fois. Renvoyé tel quel à la requête
    /// suivante : s'il n'a rien de neuf, il répond « 304 » et rien ne transite.
    var etag: String?
    var lastModified: String?

    /// **Décodage tolérant, et il l'est pour une raison vécue.** Swift n'applique pas les
    /// valeurs par défaut dans un décodeur synthétisé : ajouter un seul champ à cette
    /// structure a suffi à rendre illisible le catalogue déjà enregistré, qui est reparti
    /// de zéro — soixante-dix listes et leurs téléchargements perdus d'un coup. Un fichier
    /// écrit par une version précédente doit toujours pouvoir être relu par la suivante.
    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        title = try box.decode(String.self, forKey: .title)
        source = try box.decode(URL.self, forKey: .source)
        isEnabled = try box.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        group = try box.decodeIfPresent(String.self, forKey: .group) ?? "other"
        parent = try box.decodeIfPresent(String.self, forKey: .parent)
        isBuiltIn = try box.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        updated = try box.decodeIfPresent(Date.self, forKey: .updated)
        lines = try box.decodeIfPresent(Int.self, forKey: .lines) ?? 0
        rules = try box.decodeIfPresent(Int.self, forKey: .rules) ?? 0
        etag = try box.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try box.decodeIfPresent(String.self, forKey: .lastModified)
    }

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
/// **Wuji entretient deux listes, et deux seulement.** Elles ne visent que des domaines —
/// des régies et des mouchards qui portent le même nom depuis dix ans. C'est la part du
/// filtrage qui se maintient à la main, à la vitesse d'un dépôt ouvert où une contribution
/// est une ligne dans un diff.
///
/// **Tout ce qui bouge vite reste chez ceux dont c'est le métier.** Les scriptlets, les
/// murs anti-adblock, les publicités servies depuis le domaine du site lui-même : c'est
/// une course quotidienne, et prétendre la suivre avec deux fichiers texte donnerait une
/// fausse impression de protection. Ces listes-là viennent d'uBlock Origin, d'EasyList et
/// d'AdGuard, telles qu'elles sont publiées.
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

    /// Les listes de Wuji, livrées avec l'application.
    ///
    /// Elles vivent dans `Filters/` à la racine du dépôt, en texte, commentées : c'est ce
    /// qui rend une contribution possible sans rien savoir de Swift.
    nonisolated static let builtIn: [(file: String, title: String)] = [
        ("wuji-ads", "Wuji — Publicités"),
        ("wuji-trackers", "Wuji — Traqueurs")
    ]

    static func builtInSource(_ file: String) -> URL {
        URL(string: "wuji://filters/\(file).txt")!
    }

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
    static let groupOrder = ["wuji", "default", "ads", "privacy", "malware", "multipurpose",
                             "cookies", "social", "annoyances", "regions", "other"]

    /// Les régions comptent trente-huit entrées : repliées par défaut, comme chez uBlock.
    static let collapsedGroups: Set<String> = ["regions"]

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "wuji":         return "Listes de Wuji"
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
        adoptBuiltIn()
        applySocleOnce()
        sweep()
    }

    /// Efface les fichiers de listes que plus aucune entrée ne réclame.
    ///
    /// Un identifiant nomme un fichier ; une liste qui disparaît de l'index laisse donc
    /// derrière elle des mégaoctets que rien ne relira jamais.
    private func sweep() {
        let known = Set(lists.map { file(for: $0).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for candidate in files where candidate.pathExtension == "txt" {
            guard !known.contains(candidate.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    /// Ramène une fois pour toutes le catalogue à son socle.
    ///
    /// Vingt-deux listes actives faisaient 303 876 règles, donc vingt-deux tranches
    /// compilées — et `ignore-previous-rules` n'annulant que dans sa propre tranche, les
    /// exceptions de l'utilisateur étaient recopiées vingt-deux fois. Le socle tient sous
    /// les 150 000 règles : **une seule tranche**, et le découpage disparaît avec ses
    /// contreparties.
    ///
    /// Ce qui reste coché : les listes de Wuji, et les cinq d'uBlock Origin — ces
    /// dernières parce qu'elles portent les scriptlets, la seule couche qui atteigne les
    /// publicités servies depuis le domaine du site. Tout le reste est décoché, pas
    /// supprimé : un clic le ramène.
    private func applySocleOnce() {
        let key = "socleApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for index in lists.indices {
            lists[index].isEnabled = lists[index].isBuiltIn || lists[index].group == "default"
        }
        save()
    }

    /// Installe les listes de Wuji et **recopie leur texte à chaque lancement**.
    ///
    /// Le paquet fait foi : une liste corrigée dans le dépôt doit s'appliquer dès la
    /// version suivante, sans que personne ait à cliquer sur « mettre à jour ». C'est la
    /// contrepartie de les livrer avec l'application plutôt que de les télécharger.
    private func adoptBuiltIn() {
        for entry in Self.builtIn {
            let source = Self.builtInSource(entry.file)
            var list = lists.first { $0.source == source }
                ?? FilterList(title: entry.title, source: source, group: "wuji")
            list.title = entry.title
            list.group = "wuji"
            list.isBuiltIn = true

            guard let bundled = Bundle.main.url(forResource: entry.file, withExtension: "txt"),
                  let text = try? String(contentsOf: bundled, encoding: .utf8) else { continue }
            try? text.write(to: file(for: list), atomically: true, encoding: .utf8)
            list.updated = Date()
            list.lines = text.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }

            if let index = lists.firstIndex(where: { $0.source == source }) {
                lists[index] = list
            } else {
                lists.insert(list, at: 0)
            }
        }
        save()
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
    /// Relit le catalogue d'uBlock et fond le résultat avec ce qu'on a.
    ///
    /// Les choix de l'utilisateur survivent : une liste déjà connue garde son état actif ou
    /// inactif. Ce qu'il a ajouté lui-même n'est jamais touché ; ce qui sort du catalogue
    /// s'en va avec son fichier.
    func refreshCatalog() async {
        var request = URLRequest(url: Self.catalogSource)
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var catalog: [FilterList] = []

        for (_, value) in root {
            guard let entry = value as? [String: Any],
                  entry["content"] as? String == "filters",
                  let title = entry["title"] as? String else { continue }

            // `contentURL` est tantôt une adresse, tantôt une liste de miroirs.
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
            // **Une liste découverte arrive décochée**, sauf le socle d'uBlock Origin.
            //
            // Reprendre les défauts d'uBlock à chaque rafraîchissement ferait rallumer des
            // listes que l'on vient d'éteindre, sans que personne l'ait demandé, et le
            // socle ne tiendrait pas une semaine. Le catalogue dit ce qui existe ;
            // l'utilisateur dit ce qui s'applique.
            //
            // L'exception tient à ce que ces cinq listes portent : les scriptlets, seule
            // couche qui atteigne les publicités servies depuis le domaine du site. Sans
            // elles, Wuji perdrait YouTube sans que rien ne l'annonce.
            let enabled = group == "default"

            // Deux entrées du catalogue peuvent viser le même fichier — les avis de
            // cookies y sont référencés deux fois, par EasyList et par AdGuard.
            guard !catalog.contains(where: { $0.source == source }) else { continue }
            catalog.append(FilterList(title: title, source: source, isEnabled: enabled,
                                      group: group, parent: entry["parent"] as? String))
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
                entry.etag = known.etag
                entry.lastModified = known.lastModified
            }
            merged.append(entry)
        }
        for known in lists {
            if merged.contains(where: { $0.source == known.source }) { continue }
            if known.isBuiltIn || known.group == "other" {
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
    func update(_ list: FilterList) async -> Bool {
        // Une liste livrée avec l'application n'a nulle part où aller chercher mieux.
        guard !list.isBuiltIn else { return true }
        var request = URLRequest(url: list.source)
        request.timeoutInterval = 30
        // **Requête conditionnelle.** Une liste change une fois par jour au mieux ;
        // retélécharger trente mégaoctets pour retrouver les mêmes octets est une dépense
        // pour le réseau, pour les serveurs qui offrent ces listes, et pour l'attente.
        if let etag = list.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = list.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        // Sans ça, `URLSession` peut répondre depuis son propre cache et masquer le 304.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let index = lists.firstIndex(where: { $0.id == list.id }) else { return false }

        // Rien de neuf : le fichier qu'on a est le bon, on note juste qu'on a vérifié.
        if http.statusCode == 304, FileManager.default.fileExists(atPath: file(for: list).path) {
            lists[index].updated = Date()
            save()
            return true
        }
        guard http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else { return false }

        try? text.write(to: file(for: list), atomically: true, encoding: .utf8)
        lists[index].updated = Date()
        lists[index].etag = http.value(forHTTPHeaderField: "ETag")
        lists[index].lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        lists[index].lines = text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        save()
        return true
    }

    /// Télécharge les listes actives **de front**, six à la fois.
    ///
    /// Une à une, trente-trois listes font trente-trois allers-retours mis bout à bout :
    /// l'attente est celle de la latence, pas celle du débit. Six en parallèle suffisent à
    /// saturer une connexion ordinaire sans se faire prendre pour une attaque par des
    /// serveurs qui hébergent gratuitement ces fichiers.
    @discardableResult
    func updateAll(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> Int {
        let targets = lists.filter(\.isEnabled)
        guard !targets.isEmpty else { return 0 }

        var done = 0
        var updated = 0
        await withTaskGroup(of: Bool.self) { group in
            var pending = targets.makeIterator()
            for _ in 0..<min(6, targets.count) {
                guard let list = pending.next() else { break }
                group.addTask { await self.update(list) }
            }
            while let success = await group.next() {
                done += 1
                if success { updated += 1 }
                progress(done, targets.count)
                // Une requête part dès qu'une autre revient : la file reste pleine sans
                // jamais dépasser six.
                if let list = pending.next() {
                    group.addTask { await self.update(list) }
                }
            }
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
