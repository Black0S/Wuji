import CryptoKit
import WebKit

/// Le bloqueur de contenu.
///
/// Il compile les listes une fois, et WebKit les applique ensuite **dans le moteur**, avant
/// qu'une requête parte. Rien ne remonte jusqu'à l'application : c'est ce qui rend le
/// filtrage gratuit à l'usage, et c'est aussi pourquoi Wuji ne peut pas afficher de compteur
/// de « publicités bloquées ». On préfère ne rien annoncer que d'annoncer un chiffre inventé.
///
/// **La compilation est gardée en cache.** Cent mille règles prennent plusieurs secondes à
/// compiler ; les refaire à chaque lancement pour un contenu identique serait une taxe sur
/// le démarrage. WebKit garde la liste compilée sous son identifiant, on garde l'empreinte
/// de ce qui l'a produite, et on ne recompile que si les deux divergent.
@MainActor
final class ContentBlocker {

    enum State {
        case off
        case empty
        case updating
        case compiling
        case active(rules: Int, skipped: Int, dropped: Int)
        case failed(String)

        var summary: String {
            switch self {
            case .off:       return "Désactivé"
            case .empty:     return "Aucune liste téléchargée"
            case .updating:  return "Téléchargement…"
            case .compiling: return "Compilation…"
            case .active(let rules, let skipped, let dropped):
                var text = "\(format(rules)) règles actives"
                if skipped > 0 { text += " · \(format(skipped)) sans équivalent" }
                if dropped > 0 { text += " · \(format(dropped)) refusées par le moteur" }
                return text
            case .failed(let reason): return "Échec · \(reason)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .updating, .compiling: return true
            default: return false
            }
        }

        private func format(_ value: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = " "
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
    }

    private(set) var state: State = .off
    var onChange: (() -> Void)?
    /// Appelé quand une nouvelle liste vient d'être installée. Une règle ajoutée ne change
    /// rien à la page tant que la compilation n'a pas fini — recharger avant, c'est
    /// recharger pour rien et croire que le réglage n'a pas marché.
    var onApplied: (() -> Void)?

    /// Une liste compilée par tranche. C'est **la** façon de dépasser le plafond de
    /// WebKit : la limite est par liste, pas par navigateur, et `WKUserContentController`
    /// en accepte autant qu'on veut.
    private static func identifier(_ index: Int) -> String { "wuji.filters.\(index)" }
    private static let signatureKey = "blockingSignature"
    private static let chunkKey = "blockingChunks"

    /// Taille d'une tranche. Cent mille règles compilent en quelques secondes et passent
    /// sans discussion ; au-delà on s'approche de la limite pour rien, puisqu'il suffit
    /// d'ajouter une tranche.
    nonisolated static let chunkSize = 100_000

    private unowned let settings: Settings
    let lists: FilterListStore

    private var controllers: [WKUserContentController] = []
    private var compiled: [WKContentRuleList] = []

    init(settings: Settings, lists: FilterListStore) {
        self.settings = settings
        self.lists = lists
    }

    /// Les vues web partagent une configuration, donc un seul contrôleur — mais on garde
    /// une liste : une fenêtre privée en aura le sien.
    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        compiled.forEach { controller.add($0) }
    }

    /// Au démarrage : reprendre la liste déjà compilée si rien n'a changé, télécharger si
    /// l'on n'a jamais rien reçu.
    func start() {
        guard settings.blockingEnabled else { return apply([], state: .off) }
        guard lists.hasContent else {
            // Premier lancement : on va chercher les listes une fois, parce qu'un
            // bloqueur sans liste ne bloque rien et que personne n'a envie de cliquer
            // pour obtenir ce qu'il vient d'activer.
            Task { await updateAndCompile() }
            return
        }
        compile()
    }

    /// Recompile à partir de ce qu'on a sur le disque.
    ///
    /// **Une tranche compilée par liste**, et plusieurs si une liste est grosse. WebKit
    /// plafonne une liste compilée, pas le nombre de listes installées : c'est par là qu'on
    /// passe, et c'est ce qui permet d'en charger trois cent mille au lieu de cent
    /// cinquante mille.
    ///
    /// Le prix à payer est réel et vaut d'être dit : `ignore-previous-rules` n'annule que
    /// ce qui le précède **dans la même tranche**. Les exceptions d'une liste sont donc
    /// recopiées dans chacune de ses tranches, et celles de l'utilisateur — sites sans
    /// protection compris — dans toutes. Quelques milliers de règles dupliquées contre des
    /// exceptions qui marchent : le calcul est vite fait.
    func compile() {
        guard settings.blockingEnabled else { return apply([], state: .off) }

        let sources = lists.enabled.compactMap { list -> (FilterList, String)? in
            lists.text(for: list).map { (list, $0) }
        }
        guard !sources.isEmpty else { return apply([], state: .empty) }

        state = .compiling
        onChange?()

        // La conversion coûte plusieurs secondes sur trois cent mille lignes : hors du fil
        // principal, sinon l'interface se fige au démarrage.
        let userRules = lists.userRules.joined(separator: "\n")
        let hosts = settings.blockingExceptions
        Task.detached(priority: .userInitiated) {
            var mine = FilterConverter.rules(from: userRules)
            for host in hosts {
                mine.exceptions.append([
                    "trigger": ["url-filter": ".*", "if-domain": ["*\(host)"]],
                    "action": ["type": "ignore-previous-rules"]
                ])
            }
            // Ce que l'utilisateur a écrit doit valoir partout, donc être répété partout.
            let universal = mine.exceptions

            var chunks: [[[String: Any]]] = []
            var accepted = universal.count
            var rejected = 0
            var perList: [(UUID, Int, Int)] = []

            func serialize(_ rules: [[String: Any]]) {
                guard !rules.isEmpty else { return }
                chunks.append(rules)
            }

            for (list, text) in sources {
                let output = FilterConverter.rules(from: text)
                perList.append((list.id, output.accepted + output.rejected, output.accepted))
                rejected += output.rejected
                accepted += output.accepted

                // Le masquage après le blocage, les exceptions en dernier : c'est l'ordre
                // qu'exige `ignore-previous-rules`.
                let body = output.blocking + output.cosmetic
                let tail = output.exceptions + universal
                let room = max(1, Self.chunkSize - tail.count)
                for start in stride(from: 0, to: max(body.count, 1), by: room) {
                    let slice = Array(body[start..<min(start + room, body.count)])
                    serialize(slice + tail)
                }
            }
            serialize(mine.blocking + mine.cosmetic + universal)

            let counts = (accepted: accepted, rejected: rejected, chunks: chunks.count)
            let sealed = chunks
            await MainActor.run { [weak self] in
                perList.forEach { self?.lists.record(lines: $0.1, rules: $0.2, for: $0.0) }
                self?.install(chunks: sealed, counts: counts)
            }
        }
    }

    /// Télécharge puis recompile.
    func update() {
        Task { await updateAndCompile() }
    }

    private func updateAndCompile() async {
        state = .updating
        onChange?()
        // Le catalogue d'abord : c'est lui qui dit quelles listes existent, et il change
        // plus souvent qu'on ne croit — les listes se scindent et se renomment.
        await lists.refreshCatalog()
        await lists.updateAll()
        compile()
    }

    // MARK: - Installation

    private func install(chunks: [[[String: Any]]], counts: (accepted: Int, rejected: Int, chunks: Int)) {
        guard !chunks.isEmpty else { return apply([], state: .empty) }

        var hasher = SHA256()
        for chunk in chunks {
            hasher.update(data: Data("\(chunk.count)".utf8))
            if let first = chunk.first, let data = try? JSONSerialization.data(withJSONObject: first) {
                hasher.update(data: data)
            }
            if let last = chunk.last, let data = try? JSONSerialization.data(withJSONObject: last) {
                hasher.update(data: data)
            }
        }
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let store = WKContentRuleListStore.default()

        let done: ([WKContentRuleList]) -> Void = { [weak self] lists in
            UserDefaults.standard.set(signature, forKey: Self.signatureKey)
            UserDefaults.standard.set(chunks.count, forKey: Self.chunkKey)
            self?.apply(lists, state: .active(rules: counts.accepted, skipped: counts.rejected,
                                              dropped: 0))
        }

        // Même contenu qu'au dernier lancement : les tranches compilées sont encore là, on
        // les reprend. C'est la différence entre un démarrage instantané et une demi-minute
        // de moulinette pour le même résultat.
        if signature == UserDefaults.standard.string(forKey: Self.signatureKey),
           UserDefaults.standard.integer(forKey: Self.chunkKey) == chunks.count {
            Task {
                var found: [WKContentRuleList] = []
                for index in chunks.indices {
                    guard let list = try? await store?.contentRuleList(forIdentifier: Self.identifier(index))
                    else { break }
                    found.append(list)
                }
                if found.count == chunks.count { done(found) } else { build(chunks, signature, counts) }
            }
            return
        }
        build(chunks, signature, counts)
    }

    private func build(_ chunks: [[[String: Any]]], _ signature: String,
                       _ counts: (accepted: Int, rejected: Int, chunks: Int)) {
        Task {
            var built: [WKContentRuleList] = []
            var lost = 0
            var index = 0
            for chunk in chunks {
                let (lists, dropped) = await compile(chunk, index: &index)
                built += lists
                lost += dropped
            }
            guard !built.isEmpty else {
                UserDefaults.standard.removeObject(forKey: Self.signatureKey)
                apply([], state: .failed("aucune tranche n'a compilé"))
                return
            }
            UserDefaults.standard.set(signature, forKey: Self.signatureKey)
            UserDefaults.standard.set(built.count, forKey: Self.chunkKey)
            apply(built, state: .active(rules: counts.accepted - lost,
                                        skipped: counts.rejected, dropped: lost))
        }
    }

    /// Compile une tranche, et **la coupe en deux si elle est refusée**.
    ///
    /// Les listes viennent de projets tiers qui les changent chaque semaine. Il suffit
    /// d'une règle qu'on a mal traduite, ou d'une syntaxe que WebKit n'accepte pas encore,
    /// pour qu'une compilation entière échoue — et « échoue » veut dire zéro protection.
    /// En coupant, on isole la zone fautive : on perd quelques centaines de règles au lieu
    /// de cent mille, et le navigateur reste protégé.
    ///
    /// La dichotomie sépare aussi les exceptions de la tranche des règles qu'elles
    /// annulaient. C'est un vrai coût, assumé : il ne se paie que dans le cas d'échec.
    private func compile(_ rules: [[String: Any]],
                         index: inout Int) async -> ([WKContentRuleList], Int) {
        guard !rules.isEmpty else { return ([], 0) }

        if let json = (try? JSONSerialization.data(withJSONObject: rules))
            .flatMap({ String(data: $0, encoding: .utf8) }),
           let list = try? await WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: Self.identifier(index),
                                    encodedContentRuleList: json) {
            index += 1
            return ([list], 0)
        }

        // Trop petite pour être coupée encore : on abandonne ces règles-là, pas les autres.
        guard rules.count > 500 else { return ([], rules.count) }

        let middle = rules.count / 2
        var (lists, lost) = await compile(Array(rules[..<middle]), index: &index)
        let (more, alsoLost) = await compile(Array(rules[middle...]), index: &index)
        lists += more
        lost += alsoLost
        return (lists, lost)
    }

    private func apply(_ lists: [WKContentRuleList], state: State) {
        compiled = lists
        for controller in controllers {
            controller.removeAllContentRuleLists()
            lists.forEach { controller.add($0) }
        }
        self.state = state
        onChange?()
        onApplied?()
    }

    // MARK: - Exceptions par site

    func isExcepted(_ url: URL?) -> Bool {
        guard let host = url?.host() else { return false }
        return settings.blockingExceptions.contains(host)
    }

    /// Le bloqueur casse parfois une page — un lecteur vidéo, une banque, un mur de
    /// paiement. Pouvoir l'éteindre **sur ce site seulement** évite d'avoir à choisir
    /// entre la page et la protection partout ailleurs.
    func toggleException(for url: URL?) {
        guard let host = url?.host() else { return }
        if let index = settings.blockingExceptions.firstIndex(of: host) {
            settings.blockingExceptions.remove(at: index)
        } else {
            settings.blockingExceptions.append(host)
        }
        compile()
    }

    /// Une règle écrite par l'utilisateur — le sélecteur d'élément passe par là.
    func addUserRule(_ rule: String) {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty, !lists.userRules.contains(rule) else { return }
        lists.userRules.append(rule)
        compile()
    }
}
