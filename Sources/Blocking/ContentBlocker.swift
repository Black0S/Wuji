import CryptoKit
import WebKit

/// Le blocage.
///
/// **Les règles arrivent déjà traduites.** Les assets de `Blocking/Assets` sont écrits dans
/// le format de `WKContentRuleList` — celui que WebKit compile directement. Il n'y a pas de
/// convertisseur au démarrage, pas de listes à télécharger, pas d'index à reconstruire :
/// le navigateur lit des fichiers de quelques kilo-octets et les donne au moteur.
///
/// **Une liste compilée par famille de règles**, et non un seul bloc : c'est ce qui permet
/// d'éteindre les mouchards sans éteindre la publicité, ou la télémétrie d'appareils qu'on
/// ne possède pas. Voir `RuleList`.
///
/// Avec une conséquence qu'il faut connaître avant de toucher à ce fichier : **les
/// exceptions sont recopiées à la fin de chaque liste.** `ignore-previous-rules` n'annule
/// que ce qui le précède *dans sa propre liste* — mesuré, une exception compilée à part ne
/// lève rien ailleurs. Une exception de site posée dans une seule liste laisserait donc les
/// autres bloquer, et « désactiver la protection sur ce site » ne tiendrait pas parole.
///
/// C'est ce qui a changé, et le prix est assumé. Wuji ne fait plus tourner de scriptlets,
/// donc il ne retire plus les publicités servies depuis le domaine du site lui-même —
/// YouTube au premier chef. Ce filtrage-là demande une course quotidienne que deux fichiers
/// texte ne peuvent pas suivre, et prétendre le contraire donnerait une fausse impression
/// de protection.
///
/// Ce qui reste est vrai partout ailleurs : les régies et les mouchards s'appellent par
/// leur domaine, et un domaine se bloque.
@MainActor
final class ContentBlocker {

    enum State {
        case off
        case compiling
        case active(rules: Int, lists: Int)
        /// Une partie protège, une autre non. **Le cas existe vraiment maintenant** qu'il y
        /// a plusieurs listes : une refusée n'emporte plus les cinq autres. Le dire vaut
        /// mieux que d'annoncer « actif » sur une protection amputée.
        case partial(rules: Int, why: String)
        case failed(String)

        var summary: String {
            switch self {
            case .off:       return "Blocage désactivé"
            case .compiling: return "Préparation…"
            case .active(let rules, let lists):
                return "\(rules) règles actives, \(lists) liste\(lists > 1 ? "s" : "")"
            case .partial(let rules, let why): return "\(rules) règles actives — \(why)"
            case .failed(let why):  return "Blocage indisponible — \(why)"
            }
        }

        var isBusy: Bool { if case .compiling = self { return true }; return false }
    }

    private(set) var state: State = .off

    /// Les règles sont-elles réellement posées sur les vues web ? Une page chargée avant
    /// qu'elles le soient garde l'ancienne liste : WebKit les applique au moment de la
    /// requête, pas après coup.
    var isReady: Bool { !compiled.isEmpty }
    var onChange: (() -> Void)?
    /// Appelé quand les règles viennent d'être installées. Une règle ajoutée ne change rien
    /// à la page tant que la compilation n'a pas fini — recharger avant, c'est recharger
    /// pour rien et croire que le réglage n'a pas marché.
    var onApplied: (() -> Void)?
    /// L'espace courant est-il privé ? Décide où va une exception posée maintenant.
    var isPrivate: () -> Bool = { false }

    /// Les règles écrites par l'utilisateur vivent dans leur propre liste compilée, à côté
    /// des listes livrées : elles ne se désactivent pas, et elles n'ont pas à être
    /// recompilées quand on touche à une liste du catalogue.
    private static let userIdentifier = "wuji.user"
    private static let signatureKey = "blockingSignature"

    private unowned let settings: Settings
    let userRules: UserRules

    private var controllers: [WKUserContentController] = []
    private var compiled: [WKContentRuleList] = []

    init(settings: Settings, userRules: UserRules) {
        self.settings = settings
        self.userRules = userRules
    }

    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        compiled.forEach { controller.add($0) }
    }

    // MARK: - Compilation

    /// Le catalogue tel qu'il est réellement livré : chaque liste, ce qu'elle pèse, et si
    /// elle est allumée. Lu à même le paquet et non déclaré à côté — une liste annoncée
    /// dans les réglages mais absente du paquet est un contrôle mort.
    private(set) var catalog: [(list: RuleList, count: Int, isEnabled: Bool)] = []

    /// Le nombre de règles réellement posées, livrées et personnelles confondues.
    private(set) var bundledCount = 0

    func start() { compile() }

    /// Assemble chaque liste allumée, y recopie les exceptions, puis compile ce qui a changé.
    func compile() {
        guard settings.blockingEnabled else { return apply([], state: .off) }

        // Les exceptions ferment **chaque** liste : `ignore-previous-rules` n'annule que ce
        // qui le précède dans la sienne. C'est la contrainte qui décide de tout le reste.
        let exceptions = (settings.blockingExceptions + settings.privateBlockingExceptions)
            .map(WebKitRule.exception(for:))

        var catalog: [(list: RuleList, count: Int, isEnabled: Bool)] = []
        var groups: [(identifier: String, json: String)] = []
        var missing: [String] = []
        var total = 0

        for list in RuleList.all {
            guard let rules = Self.asset(list.file) else { missing.append(list.name); continue }
            let isEnabled = settings.isEnabled(list)
            catalog.append((list, rules.count, isEnabled))
            guard isEnabled, !rules.isEmpty else { continue }
            total += rules.count
            groups.append((list.identifier, Self.json(rules + exceptions)))
        }
        self.catalog = catalog

        // Déjà au format de WebKit, comme tout le reste : rien à traduire.
        let mine = userRules.rules
        if !mine.isEmpty {
            total += mine.count
            groups.append((Self.userIdentifier, Self.json(mine + exceptions)))
        }
        bundledCount = total

        guard !groups.isEmpty else {
            return apply([], state: missing.isEmpty
                ? .failed("aucune liste n'est activée")
                : .failed("les règles livrées sont introuvables"))
        }

        state = .compiling
        onChange?()

        Task { [weak self] in
            guard let store = WKContentRuleListStore.default() else { return }
            var lists: [WKContentRuleList] = []
            var refused: [String] = []

            for group in groups {
                let key = "\(Self.signatureKey).\(group.identifier)"
                let signature = Self.signature(of: group.json)
                // Même contenu qu'au dernier lancement : la liste compilée est encore dans
                // le magasin de WebKit, on la reprend telle quelle.
                if signature == UserDefaults.standard.string(forKey: key),
                   let known = try? await store.contentRuleList(forIdentifier: group.identifier) {
                    lists.append(known)
                    continue
                }
                do {
                    if let list = try await store.compileContentRuleList(
                        forIdentifier: group.identifier, encodedContentRuleList: group.json) {
                        UserDefaults.standard.set(signature, forKey: key)
                        lists.append(list)
                    }
                } catch {
                    // Une règle écrite à la main peut être refusée par le moteur. Avant, elle
                    // emportait tout le blocage ; maintenant elle n'emporte que sa liste, et
                    // on dit laquelle.
                    UserDefaults.standard.removeObject(forKey: key)
                    refused.append(RuleList.named(group.identifier
                        .replacingOccurrences(of: "wuji.", with: ""))?.name ?? "vos règles")
                }
            }

            let posées = lists.count
            let state: State
            if lists.isEmpty {
                state = .failed("aucune liste n'a pu être compilée")
            } else if !refused.isEmpty {
                state = .partial(rules: total,
                                 why: "refusée par le moteur : \(refused.joined(separator: ", "))")
            } else if !missing.isEmpty {
                state = .partial(rules: total,
                                 why: "liste introuvable : \(missing.joined(separator: ", "))")
            } else {
                state = .active(rules: total, lists: posées)
            }
            self?.apply(lists, state: state)
            await Self.sweepStore(keeping: Set(groups.map(\.identifier)))
        }
    }

    private static func json(_ rules: [String]) -> String {
        "[" + rules.joined(separator: ",") + "]"
    }

    private static func signature(of json: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(json.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Une liste livrée avec l'application : une règle par ligne, telle qu'elle est écrite
    /// dans le dépôt.
    ///
    /// Le fichier porte aussi des repères de lecture — les lignes en `//` qui nomment les
    /// sections. On ne retient que les lignes qui sont des règles, donc le moteur ne voit
    /// jamais rien d'autre, et le fichier reste relisible par un humain.
    nonisolated static func asset(_ file: String) -> [String]? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return rules(in: text)
    }

    /// Le tri des lignes, séparé de la lecture du fichier pour que les tests puissent le
    /// vérifier sur les assets du dépôt, sans paquet ni fenêtre.
    nonisolated static func rules(in text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                  .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            }
            .filter { $0.hasPrefix("{") && $0.hasSuffix("}") }
    }

    /// Efface du magasin de WebKit tout ce qui n'est plus posé.
    ///
    /// Le magasin garde ce qu'on y a mis, indéfiniment. Les tranches de l'époque où Wuji
    /// compilait vingt-deux listes y occupaient encore soixante-dix-huit mégaoctets alors
    /// que plus rien ne les réclamait. Une liste qu'on éteint dans les réglages passe par
    /// le même chemin : elle quitte le disque, elle ne dort pas dedans.
    private static func sweepStore(keeping current: Set<String>) async {
        guard let store = WKContentRuleListStore.default() else { return }
        let identifiers = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for name in identifiers where !current.contains(name) {
            try? await store.removeContentRuleList(forIdentifier: name)
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

    /// Le bloqueur casse parfois une page. Pouvoir l'éteindre **sur ce site seulement**
    /// évite d'avoir à choisir entre la page et la protection partout ailleurs.
    func isExcepted(_ url: URL?) -> Bool {
        guard let site = Site.name(of: url) else { return false }
        return (settings.blockingExceptions + settings.privateBlockingExceptions)
            .contains { Site.name(ofHost: $0) == site }
    }

    func toggleException(for url: URL?) {
        guard let site = Site.name(of: url) else { return }
        let matches = { (entry: String) in Site.name(ofHost: entry) == site }
        // En privé, l'exception va dans le registre éphémère : elle vaut pour la session et
        // ne suit pas l'utilisateur dans ses espaces normaux.
        if isPrivate() {
            if settings.privateBlockingExceptions.contains(where: matches) {
                settings.privateBlockingExceptions.removeAll(where: matches)
            } else {
                settings.privateBlockingExceptions.append(site)
            }
        } else if settings.blockingExceptions.contains(where: matches) {
            settings.blockingExceptions.removeAll(where: matches)
        } else {
            settings.blockingExceptions.append(site)
        }
        compile()
    }

    // MARK: - Règles de l'utilisateur

    /// Ajoute une règle, si elle en est une. Rend `false` quand elle est refusée — l'appelant
    /// le dit à l'écran : une règle avalée en silence se cherche longtemps.
    @discardableResult
    func addUserRule(_ rule: String) -> Bool {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        guard WebKitRule.isValid(rule) else { return false }
        userRules.add(rule)
        compile()
        return true
    }

    /// Corrige une règle sans la déplacer.
    @discardableResult
    func replaceUserRule(_ rule: String, with replacement: String) -> Bool {
        let replacement = replacement.trimmingCharacters(in: .whitespaces)
        guard WebKitRule.isValid(replacement),
              userRules.replace(rule, with: replacement) else { return false }
        compile()
        return true
    }

    func removeUserRule(_ rule: String) {
        userRules.remove(rule)
        compile()
    }
}

