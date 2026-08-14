import ContentBlockerConverter
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
        case updating(done: Int, total: Int)
        case compiling
        case active(rules: Int, skipped: Int, dropped: Int)
        case failed(String)

        var summary: String {
            switch self {
            case .off:       return "Désactivé"
            case .empty:     return "Aucune liste téléchargée"
            case .updating(let done, let total):
                return total > 0 ? "Téléchargement… \(done)/\(total)" : "Téléchargement…"
            case .compiling: return "Compilation…"
            case .active(let rules, let skipped, let dropped):
                var text = "\(format(rules)) règles actives"
                if skipped > 0 { text += " · \(format(skipped)) hors syntaxe Safari" }
                if dropped > 0 { text += " · \(dropped) liste\(dropped > 1 ? "s" : "") refusée\(dropped > 1 ? "s" : "")" }
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

        // La conversion tourne hors du fil principal, une liste par tâche : elles ne se
        // regardent pas. **Une liste convertie donne une tranche compilée** — le
        // convertisseur d'AdGuard s'arrête de lui-même au plafond de Safari, donc le
        // découper par liste est aussi ce qui évite qu'il écarte le surplus.
        let userRules = lists.userRules
        let hosts = settings.blockingExceptions
        Task.detached(priority: .userInitiated) {
            // Les règles de l'utilisateur valent partout, donc sont recopiées dans chaque
            // tranche : `ignore-previous-rules` n'annule que ce qui le précède dans la
            // même liste compilée.
            let universal = (hosts.map { "@@||\($0)^$document" } + userRules)
            let mine = ContentBlockerConverter().convertArray(
                rules: universal, safariVersion: SafariVersion.autodetect(),
                advancedBlocking: true, maxJsonSizeBytes: nil, progress: nil)

            let converted = await withTaskGroup(of: (Int, Converted).self) { group in
                for (position, source) in sources.enumerated() {
                    group.addTask {
                        let result = ContentBlockerConverter().convertArray(
                            rules: source.1.components(separatedBy: "\n"),
                            safariVersion: SafariVersion.autodetect(),
                            advancedBlocking: true, maxJsonSizeBytes: nil, progress: nil)
                        return (position, Converted(result: result))
                    }
                }
                var result = [Converted?](repeating: nil, count: sources.count)
                for await (position, item) in group { result[position] = item }
                return result.compactMap { $0 }
            }

            var chunks: [String] = []
            var advanced: [String] = []
            var accepted = 0, rejected = 0
            var perList: [(UUID, Int, Int)] = []

            for (source, item) in zip(sources, converted) {
                let result = item.result
                perList.append((source.0.id, result.sourceRulesCount, result.safariRulesCount))
                accepted += result.safariRulesCount
                rejected += result.sourceRulesCount - result.sourceSafariCompatibleRulesCount
                if let json = Self.splice(result.safariRulesJSON, adding: mine.safariRulesJSON) {
                    chunks.append(json)
                }
                if let text = result.advancedRulesText { advanced.append(text) }
            }
            if let text = mine.advancedRulesText { advanced.append(text) }

            let counts = (accepted: accepted + mine.safariRulesCount * chunks.count,
                          rejected: rejected,
                          advanced: advanced.reduce(0) { $0 + $1.split(separator: "\n").count })
            let sealedChunks = chunks
            let sealedAdvanced = advanced.joined(separator: "\n")
            await MainActor.run { [weak self] in
                perList.forEach { self?.lists.record(lines: $0.1, rules: $0.2, for: $0.0) }
                self?.advanced.load(sealedAdvanced)
                self?.install(chunks: sealedChunks, counts: counts)
            }
        }
    }

    /// Les règles que WebKit ne sait pas exécuter — scriptlets, sélecteurs étendus.
    ///
    /// Gardées telles quelles, au format Adblock : c'est ce que la couche JavaScript
    /// consommera. Aujourd'hui elles ne servent à rien d'autre qu'à être comptées, et
    /// c'est déjà mieux que de les jeter comme avant.
    let advanced = AdvancedRules()

    /// Recolle deux tableaux JSON sans les relire.
    ///
    /// Le convertisseur rend une chaîne, et ces chaînes pèsent des mégaoctets : les
    /// désérialiser pour ajouter trois exceptions coûterait plus cher que toute la
    /// conversion. On coupe le crochet fermant et on aboute.
    nonisolated private static func splice(_ json: String, adding extra: String) -> String? {
        guard json.hasPrefix("["), json.hasSuffix("]") else { return nil }
        let body = extra.dropFirst().dropLast()   // le contenu du second tableau
        guard !body.isEmpty else { return json }
        guard json.count > 2 else { return "[" + body + "]" }
        return String(json.dropLast()) + "," + body + "]"
    }

    /// Le résultat d'une conversion, transporté d'une tâche à l'autre.
    /// Le résultat d'une conversion, transporté d'une tâche à l'autre.
    ///
    /// `ConversionResult` n'est pas déclaré `Sendable` par la bibliothèque. Il est
    /// construit par une tâche, remis à une autre, et plus personne n'y touche — un
    /// transfert sûr que le compilateur ne peut pas prouver seul.
    private struct Converted: @unchecked Sendable {
        let result: ConversionResult
    }

    /// Télécharge puis recompile.
    func update() {
        Task { await updateAndCompile() }
    }

    private func updateAndCompile() async {
        state = .updating(done: 0, total: 0)
        onChange?()
        // Le catalogue d'abord : c'est lui qui dit quelles listes existent, et il change
        // plus souvent qu'on ne croit — les listes se scindent et se renomment.
        await lists.refreshCatalog()
        await lists.updateAll { [weak self] done, total in
            self?.state = .updating(done: done, total: total)
            self?.onChange?()
        }
        compile()
    }

    // MARK: - Installation

    private func install(chunks: [String], counts: (accepted: Int, rejected: Int, advanced: Int)) {
        guard !chunks.isEmpty else { return apply([], state: .empty) }

        var hasher = SHA256()
        chunks.forEach { hasher.update(data: Data($0.utf8)) }
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()

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
                    guard let list = try? await WKContentRuleListStore.default()?
                        .contentRuleList(forIdentifier: Self.identifier(index)) else { break }
                    found.append(list)
                }
                if found.count == chunks.count { done(found) } else { build(chunks, signature, counts) }
            }
            return
        }
        build(chunks, signature, counts)
    }

    private func build(_ chunks: [String], _ signature: String,
                       _ counts: (accepted: Int, rejected: Int, advanced: Int)) {
        Task {
            var built: [WKContentRuleList] = []
            var lost = 0
            for (index, json) in chunks.enumerated() {
                do {
                    if let list = try await WKContentRuleListStore.default()?
                        .compileContentRuleList(forIdentifier: Self.identifier(index),
                                                encodedContentRuleList: json) {
                        built.append(list)
                    }
                } catch {
                    // Une liste refusée ne coûte plus que la sienne : les autres restent en
                    // place. Un bloqueur amputé vaut mieux qu'un bloqueur éteint.
                    lost += 1
                }
            }
            guard !built.isEmpty else {
                UserDefaults.standard.removeObject(forKey: Self.signatureKey)
                apply([], state: .failed("aucune tranche n'a compilé"))
                return
            }
            UserDefaults.standard.set(signature, forKey: Self.signatureKey)
            UserDefaults.standard.set(chunks.count, forKey: Self.chunkKey)
            apply(built, state: .active(rules: counts.accepted, skipped: counts.rejected,
                                        dropped: lost))
        }
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
