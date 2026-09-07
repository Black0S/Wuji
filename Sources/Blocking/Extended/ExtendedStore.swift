import Foundation

/// Le magasin des règles à injection : ce qui est téléchargé, ce qui est en mémoire, et ce
/// qu'un site donné reçoit.
///
/// **Un index par domaine, pas un balayage.** Soixante-dix mille règles, dont cinquante-neuf
/// mille ne portent qu'un seul domaine : parcourir la liste entière à chaque navigation
/// coûterait cher pour ne rien trouver la plupart du temps. On range donc par domaine une
/// fois, au chargement, et l'on remonte les étiquettes de l'hôte — quatre ou cinq lectures
/// de table par page, quelle que soit la taille du catalogue.
///
/// **Le cache porte la version dans son nom.** Une annexe est liée à la version de sa liste ;
/// un fichier nommé `EasyList@2.1.74.31.json` dit tout seul s'il est à jour, sans registre
/// parallèle à tenir — et un registre qui diverge du disque est la façon habituelle de
/// servir des règles d'hier en croyant servir celles d'aujourd'hui.
@MainActor
final class ExtendedStore {

    /// Ce qu'un site reçoit. Tout est déjà résolu ici : la page n'a aucune décision à
    /// prendre, elle applique.
    struct Payload: Equatable {
        /// Ce qui tient dans une feuille de style : le gros du lot, et le moins cher.
        var css = ""
        /// Les sélecteurs que le CSS ne résout pas — action par défaut : masquer.
        var procedural: [String] = []
        /// `[sélecteur, déclarations]` quand le sélecteur est étendu : la feuille ne peut
        /// pas les porter, le moteur les applique élément par élément.
        var styled: [[String]] = []
        /// Ce qui doit quitter le DOM — `remove: true` en syntaxe AdGuard. Masquer ne
        /// suffit pas toujours : une page qui compte ses enfants voit encore l'élément.
        var removals: [String] = []
        var scriptlets: [[String]] = []

        var isEmpty: Bool {
            css.isEmpty && procedural.isEmpty && styled.isEmpty
                && removals.isEmpty && scriptlets.isEmpty
        }
        var count: Int {
            (css.isEmpty ? 0 : css.components(separatedBy: "\n").count)
                + procedural.count + styled.count + removals.count + scriptlets.count
        }
    }

    private(set) var rules = ExtendedRules()
    /// Domaine → indices dans les tableaux plats. Les règles sans domaine vont dans
    /// `generic`, qui s'ajoute à chaque page.
    private var byDomain: [String: Bucket] = [:]
    private var generic = Bucket()
    private var loaded: [String: ExtendedRules] = [:]

    private struct Bucket {
        var styles: [Int] = []
        var procedural: [Int] = []
        var scriptlets: [Int] = []
    }

    var isEmpty: Bool { rules.isEmpty }
    var count: Int { rules.count }
    var listCount: Int { loaded.count }
    var onChange: (() -> Void)?

    private let directory: URL

    init(directory: URL = Storage.directory.appendingPathComponent("extended", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Ce qui est en service

    /// Aligne le magasin sur les listes en service : télécharge ce qui manque, jette ce qui
    /// ne sert plus, et reconstruit l'index.
    ///
    /// Les téléchargements partent **ensemble** : ce sont quatre-vingt-quatre fichiers au
    /// plus, indépendants les uns des autres, et les enchaîner ne paierait que l'attente.
    /// Ce qu'on veut avoir : une liste, son annexe si elle en a une, et le nom du fichier
    /// de cache qui porte sa version.
    struct Wanted: Sendable {
        let id: String
        /// `nil` quand la liste ne publie pas d'annexe — soixante-dix-sept sur cent
        /// soixante et une. Le savoir évite d'aller le redemander à chaque lancement.
        let file: String?
        let cache: String
    }

    static func wanted(for list: RuleList) -> Wanted {
        Wanted(id: list.id, file: list.extendedFile, cache: cacheName(list))
    }

    /// Charge ce qui est déjà sur le disque, **sans toucher au réseau**.
    ///
    /// Rend `false` s'il manque quelque chose : à l'appelant d'aller chercher le catalogue.
    /// C'est ce qui permet de ne rien demander à personne au lancement quand rien n'a
    /// changé — un navigateur qui contacte un dépôt à chaque démarrage le fait savoir, ou
    /// ne le fait pas.
    @discardableResult
    func loadCached(_ voulus: [Wanted]) -> Bool {
        var chargées: [String: ExtendedRules] = [:]
        for item in voulus {
            guard item.file != nil else { continue }
            let url = directory.appendingPathComponent(item.cache)
            guard let data = try? Data(contentsOf: url),
                  let règles = ExtendedRules.decode(data) else { return false }
            chargées[item.id] = règles
        }
        loaded = chargées
        rebuild()
        onChange?()
        return true
    }

    func sync(_ lists: [RuleList]) async {
        await sync(lists.map(Self.wanted(for:)))
    }

    func sync(_ voulus: [Wanted]) async {

        // Ce qui n'est plus voulu s'en va du disque : une annexe périmée est un fichier de
        // plusieurs mégaoctets que rien ne relira jamais.
        let gardés = Set(voulus.filter { $0.file != nil }.map(\.cache))
        for fichier in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where !gardés.contains(fichier) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fichier))
        }

        let manquants = voulus.filter {
            $0.file != nil
                && !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0.cache).path)
        }
        if !manquants.isEmpty {
            let dossier = directory
            await withTaskGroup(of: (String, Data?).self) { groupe in
                for item in manquants {
                    guard let fichier = item.file else { continue }
                    groupe.addTask { (item.cache, await Self.download(fichier)) }
                }
                for await (nom, data) in groupe {
                    guard let data, ExtendedRules.decode(data) != nil else { continue }
                    try? data.write(to: dossier.appendingPathComponent(nom))
                }
            }
        }

        loaded = [:]
        for item in voulus where item.file != nil {
            let url = directory.appendingPathComponent(item.cache)
            guard let data = try? Data(contentsOf: url),
                  let règles = ExtendedRules.decode(data) else { continue }
            loaded[item.id] = règles
        }
        rebuild()
        onChange?()
    }

    /// Charge des règles sans passer par le réseau — pour les essais, et pour rien d'autre.
    func load(_ règles: ExtendedRules, as id: String = "essai") {
        loaded[id] = règles
        rebuild()
    }

    /// Tout jeter — l'interrupteur des règles à injection est retombé.
    func clear() {
        loaded = [:]
        rebuild()
        onChange?()
    }

    /// Efface aussi le cache sur le disque.
    func purge() {
        for fichier in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fichier))
        }
        clear()
    }

    static func cacheName(_ liste: RuleList) -> String { cacheName(liste.id, liste.version) }

    static func cacheName(_ id: String, _ version: String) -> String {
        let base = (id + "@" + version)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return base + ".json"
    }

    /// `remove: true` — la déclaration d'AdGuard qui dit « retire l'élément ».
    private static func removesElement(_ declarations: String) -> Bool {
        declarations.range(of: #"(^|;)\s*remove\s*:\s*true"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated private static func download(_ fichier: String) async -> Data? {
        guard let (data, réponse) = try? await URLSession.shared.data(
                from: RuleCatalog.extended(fichier)),
              (réponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - L'index

    private func rebuild() {
        rules = ExtendedRules.merged(Array(loaded.values))
        byDomain = [:]
        generic = Bucket()
        for (i, règle) in rules.styles.enumerated() { ranger(règle.domains, i, \Bucket.styles) }
        for (i, règle) in rules.procedural.enumerated() { ranger(règle.domains, i, \Bucket.procedural) }
        for (i, règle) in rules.scriptlets.enumerated() { ranger(règle.domains, i, \Bucket.scriptlets) }
    }

    private func ranger(_ domaines: [String], _ index: Int,
                        _ champ: WritableKeyPath<Bucket, [Int]>) {
        guard !domaines.isEmpty else { return generic[keyPath: champ].append(index) }
        for domaine in domaines {
            byDomain[domaine, default: Bucket()][keyPath: champ].append(index)
        }
    }

    // MARK: - Ce qu'un site reçoit

    /// Ce qu'il faut injecter sur cet hôte, exceptions déjà appliquées.
    func payload(for host: String) -> Payload {
        guard !rules.isEmpty, !host.isEmpty else { return Payload() }
        let candidats = Set(DomainScope.candidates(of: host))

        var seaux = [generic]
        for candidat in candidats { if let seau = byDomain[candidat] { seaux.append(seau) } }
        guard seaux.contains(where: { !$0.styles.isEmpty || !$0.procedural.isEmpty
                                       || !$0.scriptlets.isEmpty }) else { return Payload() }

        var styles: [Int] = [], procédurales: [Int] = [], scriptlets: [Int] = []
        for seau in seaux {
            styles += seau.styles; procédurales += seau.procedural; scriptlets += seau.scriptlets
        }

        // **Les exceptions d'abord.** Une règle et son exception peuvent venir de deux
        // listes différentes ; les appliquer dans l'ordre de lecture ferait dépendre le
        // résultat de l'ordre des téléchargements, ce que personne ne peut prévoir.
        var sansStyle = Set<String>(), sansProcédural = Set<String>(), sansScriptlet = Set<String>()
        var toutScriptlet = false

        for i in Set(styles) where rules.styles[i].exception {
            let r = rules.styles[i]
            if DomainScope.matches(domains: r.domains, excluded: r.excluded,
                                   host: host, candidates: candidats) {
                sansStyle.insert(r.selector)
            }
        }
        for i in Set(procédurales) where rules.procedural[i].exception {
            let r = rules.procedural[i]
            if DomainScope.matches(domains: r.domains, excluded: r.excluded,
                                   host: host, candidates: candidats) {
                sansProcédural.insert(r.selector)
            }
        }
        for i in Set(scriptlets) where rules.scriptlets[i].exception {
            let r = rules.scriptlets[i]
            guard DomainScope.matches(domains: r.domains, excluded: r.excluded,
                                      host: host, candidates: candidats) else { continue }
            // Un nom vide annule tous les scriptlets du site — c'est ce que veut dire
            // `#@%#` sans argument.
            if r.name.isEmpty { toutScriptlet = true } else {
                sansScriptlet.insert(Scriptlets.canonical(r.name))
            }
        }

        var payload = Payload()
        var lignes: [String] = []
        var vues = Set<String>()

        for i in Set(styles).sorted() {
            let r = rules.styles[i]
            guard !r.exception, !sansStyle.contains(r.selector),
                  DomainScope.matches(domains: r.domains, excluded: r.excluded,
                                      host: host, candidates: candidats) else { continue }
            // **Trois destins, et le moins cher d'abord.** « remove: true » ne se dit pas
            // en CSS — c'est un geste sur le DOM. Un sélecteur étendu ne se dit pas non
            // plus : la feuille l'ignorerait en silence. Tout le reste, c'est-à-dire la
            // quasi-totalité, tient dans une ligne de feuille de style qui ne coûte rien.
            if Self.removesElement(r.declarations) {
                if vues.insert("r:" + r.selector).inserted { payload.removals.append(r.selector) }
            } else if r.extended || !ExtendedRules.isNativeSelector(r.selector) {
                if vues.insert("s:" + r.selector).inserted {
                    payload.styled.append([r.selector, r.declarations])
                }
            } else {
                let ligne = r.selector + " { " + r.declarations + " }"
                if vues.insert(ligne).inserted { lignes.append(ligne) }
            }
        }

        // **Ce que WebKit sait résoudre repart en feuille de style.** Un tiers des
        // sélecteurs dits « procéduraux » n'emploie aucune pseudo-classe étendue — la
        // conversion les a écartés pour le marqueur de la règle, pas pour leur contenu. Les
        // envoyer au moteur ferait tourner un observateur de mutations sur des pages où une
        // ligne de CSS suffit, et sur *toutes* les pages pour les quelques règles sans
        // domaine. C'est la différence entre une feuille qui ne coûte rien après
        // l'insertion et du code qui s'exécute à chaque changement du document.
        var sélecteurs: [String] = []
        vues.removeAll()
        for i in Set(procédurales).sorted() {
            let r = rules.procedural[i]
            guard !r.exception, !sansProcédural.contains(r.selector),
                  DomainScope.matches(domains: r.domains, excluded: r.excluded,
                                      host: host, candidates: candidats) else { continue }
            guard vues.insert(r.selector).inserted else { continue }
            if ExtendedRules.isNativeSelector(r.selector) {
                lignes.append(r.selector + " { display: none !important }")
            } else {
                sélecteurs.append(r.selector)
            }
        }
        payload.procedural = sélecteurs
        payload.css = lignes.joined(separator: "\n")

        if !toutScriptlet {
            var appels: [[String]] = []
            vues.removeAll()
            for i in Set(scriptlets).sorted() {
                let r = rules.scriptlets[i]
                let nom = Scriptlets.canonical(r.name)
                guard !r.exception, !sansScriptlet.contains(nom),
                      Scriptlets.isSupported(nom),
                      DomainScope.matches(domains: r.domains, excluded: r.excluded,
                                          host: host, candidates: candidats) else { continue }
                let clé = ([nom] + r.args).joined(separator: "\u{1F}")
                if vues.insert(clé).inserted { appels.append([nom] + r.args) }
            }
            payload.scriptlets = appels
        }
        return payload
    }
}
