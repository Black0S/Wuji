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
                if dropped > 0 { text += " · \(format(dropped)) au-delà de la limite" }
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

    private static let identifier = "wuji.filters"
    private static let signatureKey = "blockingSignature"

    private unowned let settings: Settings
    let lists: FilterListStore

    private var controllers: [WKUserContentController] = []
    private var compiled: WKContentRuleList?

    init(settings: Settings, lists: FilterListStore) {
        self.settings = settings
        self.lists = lists
    }

    /// Les vues web partagent une configuration, donc un seul contrôleur — mais on garde
    /// une liste : une fenêtre privée en aura le sien.
    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        if let compiled { controller.add(compiled) }
    }

    /// Au démarrage : reprendre la liste déjà compilée si rien n'a changé, télécharger si
    /// l'on n'a jamais rien reçu.
    func start() {
        guard settings.blockingEnabled else { return apply(nil, state: .off) }
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
    func compile() {
        guard settings.blockingEnabled else { return apply(nil, state: .off) }

        let sources = lists.enabled.compactMap { list -> (FilterList, String)? in
            lists.text(for: list).map { (list, $0) }
        }
        guard !sources.isEmpty else { return apply(nil, state: .empty) }

        state = .compiling
        onChange?()

        // La conversion des grosses listes coûte quelques secondes : hors du fil principal,
        // sinon l'interface se fige au démarrage.
        let userRules = lists.userRules.joined(separator: "\n")
        let exceptions = settings.blockingExceptions
        Task.detached(priority: .userInitiated) {
            var outputs: [FilterConverter.Output] = []
            var rejected = 0
            var perList: [(UUID, Int, Int)] = []

            for (list, text) in sources {
                let output = FilterConverter.rules(from: text)
                perList.append((list.id, output.accepted + output.rejected, output.accepted))
                outputs.append(output)
                rejected += output.rejected
            }

            // Les règles de l'utilisateur passent après celles des listes : les siennes
            // doivent pouvoir annuler les leurs, jamais l'inverse.
            var mine = FilterConverter.rules(from: userRules)
            // Et les sites exclus en tout dernier : ils annulent tout ce qui précède.
            for host in exceptions {
                mine.exceptions.append([
                    "trigger": ["url-filter": ".*", "if-domain": ["*\(host)"]],
                    "action": ["type": "ignore-previous-rules"]
                ])
            }
            outputs.append(mine)

            let (rules, dropped) = FilterConverter.assemble(outputs)
            let accepted = rules.count

            let json = (try? JSONSerialization.data(withJSONObject: rules))
                .flatMap { String(data: $0, encoding: .utf8) }
            let counts = (accepted: accepted, rejected: rejected, dropped: dropped)
            await MainActor.run { [weak self] in
                perList.forEach { self?.lists.record(lines: $0.1, rules: $0.2, for: $0.0) }
                self?.install(json: json, counts: counts)
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
        await lists.updateAll()
        compile()
    }

    // MARK: - Installation

    private func install(json: String?, counts: (accepted: Int, rejected: Int, dropped: Int)) {
        guard let json else { return apply(nil, state: .failed("règles illisibles")) }

        let signature = SHA256.hash(data: Data(json.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let store = WKContentRuleListStore.default()

        // Même contenu qu'au dernier lancement : la liste compilée est encore là, on la
        // reprend. C'est la différence entre un démarrage instantané et cinq secondes de
        // moulinette pour le même résultat.
        if signature == UserDefaults.standard.string(forKey: Self.signatureKey) {
            store?.lookUpContentRuleList(forIdentifier: Self.identifier) { [weak self] list, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let list {
                        self.apply(list, state: .active(rules: counts.accepted,
                                                        skipped: counts.rejected,
                                                        dropped: counts.dropped))
                    } else {
                        self.build(json: json, signature: signature, counts: counts)
                    }
                }
            }
            return
        }
        build(json: json, signature: signature, counts: counts)
    }

    private func build(json: String, signature: String,
                       counts: (accepted: Int, rejected: Int, dropped: Int)) {
        WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: json) {
                [weak self] list, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        // On le dit plutôt que de laisser croire à une protection : un
                        // bloqueur qui échoue en silence est pire que pas de bloqueur.
                        UserDefaults.standard.removeObject(forKey: Self.signatureKey)
                        self.apply(nil, state: .failed(error.localizedDescription))
                        return
                    }
                    guard let list else { return }
                    UserDefaults.standard.set(signature, forKey: Self.signatureKey)
                    self.apply(list, state: .active(rules: counts.accepted,
                                                    skipped: counts.rejected,
                                                    dropped: counts.dropped))
                }
            }
    }

    private func apply(_ list: WKContentRuleList?, state: State) {
        compiled = list
        for controller in controllers {
            controller.removeAllContentRuleLists()
            if let list { controller.add(list) }
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
