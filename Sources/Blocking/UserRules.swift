import Foundation
import WebKit

/// Les règles que vous avez posées vous-même.
///
/// **Une liste comme les autres, et compilée comme les autres.** Ce que le sélecteur
/// désigne devient une règle `css-display-none` au format de WebKit ; elle rejoint une
/// liste personnelle que `WKContentRuleListStore` compile au même titre qu'AdGuard ou
/// EasyList. Rien n'est injecté dans la page, rien ne s'exécute au chargement : le moteur
/// masque avant de dessiner, donc on ne voit pas l'élément apparaître puis partir.
///
/// **Elles sont à vous et ne vont nulle part.** Écrites dans les réglages de l'application,
/// jamais envoyées, jamais partagées. Une règle dit ce qu'on ne veut pas voir sur un site
/// qu'on visite : c'est une information sur soi, pas une contribution.
@MainActor
final class UserRules {

    /// Une règle : un hôte, un sélecteur, et la date pour pouvoir la retrouver.
    struct Rule: Codable, Equatable, Identifiable {
        let host: String
        let selector: String
        var created = Date()
        var id: String { host + "\u{1F}" + selector }
    }

    /// L'identité de la liste personnelle dans le magasin de WebKit.
    static let identifier = "wuji.user-rules"

    private let settings: Settings
    private let store = WKContentRuleListStore.default()
    private(set) var compiled: WKContentRuleList?
    var onChange: (() -> Void)?

    var rules: [Rule] { settings.userBlockRules }
    var isEmpty: Bool { rules.isEmpty }

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Poser, retirer

    /// Ajoute une règle et recompile. Rend `false` si elle existait déjà.
    @discardableResult
    func add(host: String, selector: String) async -> Bool {
        let host = Self.registrable(host)
        let rule = Rule(host: host, selector: selector)
        guard !settings.userBlockRules.contains(where: { $0.id == rule.id }) else { return false }
        settings.userBlockRules.append(rule)
        await recompile()
        return true
    }

    func remove(id: String) {
        settings.userBlockRules.removeAll { $0.id == id }
        Task { @MainActor in await recompile() }
    }

    func removeAll(for host: String) {
        settings.userBlockRules.removeAll { $0.host == host }
        Task { @MainActor in await recompile() }
    }

    // MARK: - Compiler

    /// Reprend la liste personnelle au lancement.
    ///
    /// On recompile plutôt que de rechercher dans le magasin : une règle ajoutée puis le
    /// navigateur fermé sans que la compilation ait abouti laisserait une liste périmée, et
    /// quelques dizaines de règles se compilent en quelques millisecondes — c'est moins cher
    /// que de tenir un compte de ce qui a été écrit.
    func restore() async {
        await recompile()
    }

    private func recompile() async {
        guard !rules.isEmpty else {
            compiled = nil
            store?.removeContentRuleList(forIdentifier: Self.identifier) { _ in }
            onChange?()
            return
        }
        guard let json = Self.encode(rules) else { return }
        compiled = await withCheckedContinuation { continuation in
            store?.compileContentRuleList(forIdentifier: Self.identifier,
                                          encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
        onChange?()
    }

    /// Traduit les règles au format que WebKit compile.
    ///
    /// `if-domain` avec une étoile devant couvre les sous-domaines : une règle posée sur
    /// `exemple.fr` vaut aussi pour `www.exemple.fr`, ce qu'on attend sans le dire.
    /// `url-filter` reste `.*` — c'est le domaine qui restreint, pas l'adresse.
    static func encode(_ rules: [Rule]) -> String? {
        let entries: [[String: Any]] = rules.map { rule in
            ["trigger": ["url-filter": ".*", "if-domain": ["*" + rule.host]],
             "action": ["type": "css-display-none", "selector": rule.selector]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// L'hôte sous lequel ranger la règle.
    ///
    /// **Le site, pas la machine.** `www.exemple.fr` et `m.exemple.fr` servent la même page
    /// à deux adresses ; une règle posée sur l'une doit valoir sur l'autre, sinon il faudrait
    /// la reposer à chaque sous-domaine. `Site.name` sait où s'arrête « ce site » — c'est la
    /// liste des suffixes publics qui le dit, pas un point compté à rebours.
    static func registrable(_ host: String) -> String {
        Site.name(of: URL(string: "https://" + host)) ?? host
    }
}
