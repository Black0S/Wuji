import Foundation
import WebKit

/// Le blocage, tel que WebKit le fait.
///
/// **Aucun moteur de blocage n'est écrit ici.** Les règles sont compilées par
/// `WKContentRuleListStore` et appliquées dans le processus réseau : une requête bloquée
/// ne part pas, et la page n'apprend jamais qu'elle a été empêchée. Un bloqueur écrit en
/// JavaScript dans la page — ce que font les extensions — arrive après coup, coûte un
/// script sur chaque document, et se laisse détecter. Celui-ci ne coûte rien à la page.
///
/// **Rien n'est embarqué, rien n'est téléchargé sans qu'on le demande.** Wuji ne livre
/// aucune liste ; tant qu'on n'en active pas une, il ne bloque rien et n'a contacté
/// personne.
///
/// **La compilation se paie une fois.** Transformer douze mégaoctets de règles en table de
/// décision prend plusieurs secondes ; WebKit garde le résultat dans son magasin, sur le
/// disque, et `lookUpContentRuleList` le rend au lancement suivant sans rien recompiler.
/// C'est pourquoi on retient la version installée : c'est elle, et non la présence du
/// fichier, qui dit s'il faut refaire le travail.
@MainActor
final class ContentBlocker {

    /// Ce qu'une liste est en train de faire, pour que la page le dise.
    enum Progress: Equatable {
        case idle
        case downloading(String)
        case compiling(String)
        case failed(String, String)
    }

    private let settings: Settings
    private let store = WKContentRuleListStore.default()

    /// Les listes compilées et prêtes, par identité de liste.
    private(set) var installed: [String: [WKContentRuleList]] = [:]
    private(set) var progress: Progress = .idle
    /// Prévenu quand l'état change — la page se redessine, la barre rallume son bouclier.
    var onChange: (() -> Void)?

    var isActive: Bool { !installed.isEmpty }
    var ruleCount: Int { settings.ruleListRules.values.reduce(0, +) }

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Au lancement

    /// Reprend ce qui était activé, **sans rien retélécharger**.
    ///
    /// C'est tout l'intérêt du magasin de WebKit : les règles compilées survivent au
    /// redémarrage. Une liste qui n'y est plus — magasin vidé, mise à jour de macOS — est
    /// simplement oubliée ici : la page la remontrera comme installable, plutôt que de
    /// promettre un blocage qui n'a pas lieu.
    func restore() {
        for id in settings.enabledRuleLists {
            guard let files = settings.ruleListFiles[id] else { continue }
            Task { @MainActor in
                var lists: [WKContentRuleList] = []
                for file in files {
                    guard let list = await lookUp(identifier: identifier(for: file)) else {
                        lists = []
                        break
                    }
                    lists.append(list)
                }
                guard !lists.isEmpty else { return forget(id) }
                installed[id] = lists
                onChange?()
            }
        }
    }

    /// Jette du magasin ce qui n'est plus à personne.
    ///
    /// **Les règles compilées survivent au code qui les a demandées.** Le magasin de WebKit
    /// est sur le disque et ne se vide pas tout seul : les six listes de l'ancien bloqueur
    /// intégré y dormaient encore, des mois après sa suppression, et y seraient restées
    /// pour toujours. Le même sort attend une liste dont la conversion change de découpage,
    /// ou qu'on décoche pendant que l'application ne tourne pas.
    ///
    /// On ne touche qu'à ce qui porte notre préfixe : le magasin est partagé avec WebKit
    /// lui-même, qui y range ses propres listes.
    func sweep() {
        let keep = Set(settings.enabledRuleLists.flatMap { settings.ruleListFiles[$0] ?? [] }
            .map { identifier(for: $0) })
            .union([UserRules.identifier])

        store?.getAvailableContentRuleListIdentifiers { identifiers in
            MainActor.assumeIsolated {
                for id in identifiers ?? []
                where id.hasPrefix("wuji.") && !keep.contains(id) {
                    self.store?.removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }
    }

    // MARK: - Installer, retirer

    /// Télécharge, compile et met en service. Rend l'erreur en français, ou `nil`.
    @discardableResult
    func install(_ list: RuleList) async -> String? {
        progress = .downloading(list.name)
        onChange?()
        defer { progress = .idle; onChange?() }

        var compiled: [WKContentRuleList] = []
        for part in list.parts {
            let identifier = identifier(for: part.file)
            do {
                let (data, response) = try await URLSession.shared.data(
                    from: RuleCatalog.file(part.file))
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = String(data: data, encoding: .utf8) else {
                    return fail(list, "téléchargement refusé")
                }
                progress = .compiling(list.name)
                onChange?()
                guard let rules = await compile(identifier: identifier, json: json) else {
                    // WebKit refuse une liste qu'il ne sait pas lire, et ne dit pas
                    // laquelle des cent mille règles l'a gênée. On nomme le fichier :
                    // c'est ce qu'il faut pour aller voir dans le dépôt.
                    return fail(list, "règles refusées par WebKit (\(part.file))")
                }
                compiled.append(rules)
            } catch {
                return fail(list, "réseau indisponible")
            }
        }

        installed[list.id] = compiled
        settings.rememberRuleList(list.id, version: list.version,
                                  files: list.parts.map(\.file), rules: list.rules)
        return nil
    }

    /// Retire une liste du service **et du disque**. Garder des règles compilées pour une
    /// liste qu'on a décochée occuperait des centaines de mégaoctets pour rien.
    func remove(_ id: String) {
        let files = settings.ruleListFiles[id] ?? []
        installed[id] = nil
        forget(id)
        for file in files {
            store?.removeContentRuleList(forIdentifier: identifier(for: file)) { _ in }
        }
        onChange?()
    }

    /// La version installée diffère-t-elle de celle du catalogue ?
    func isOutdated(_ list: RuleList) -> Bool {
        guard let known = settings.ruleListVersions[list.id] else { return false }
        return known != list.version
    }

    func isInstalled(_ id: String) -> Bool { installed[id] != nil }

    // MARK: - Poser les règles

    /// Applique tout ce qui est en service à une configuration neuve.
    ///
    /// Chaque onglet a son propre contrôleur de contenu — c'est ce qui empêche deux pages
    /// qui chargent en même temps de se voler leurs scripts —, donc les règles se posent
    /// une fois par vue, à sa création.
    func apply(to configuration: WKWebViewConfiguration) {
        reapply(to: configuration.userContentController)
    }

    /// Repose les règles sur une vue déjà ouverte : activer une liste doit valoir tout de
    /// suite, sans avoir à recharger l'onglet à la main.
    func reapply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        for lists in installed.values {
            for list in lists { controller.add(list) }
        }
        // Les règles posées à la main sont une liste comme les autres, et se posent avec.
        if let mine = userRules?.compiled { controller.add(mine) }
    }

    /// Les règles personnelles, pour les poser en même temps que les listes. Une référence
    /// faible : c'est l'application qui tient les deux, et deux objets qui se retiendraient
    /// l'un l'autre ne partiraient jamais.
    weak var userRules: UserRules?

    // MARK: - Le magasin de WebKit

    /// L'identité dans le magasin. Préfixée : le magasin est celui de l'application, et un
    /// nom nu risquerait de croiser celui d'autre chose un jour.
    private func identifier(for file: String) -> String {
        "wuji." + file.replacingOccurrences(of: ".json", with: "")
    }

    private func lookUp(identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store?.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(identifier: String, json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store?.compileContentRuleList(forIdentifier: identifier,
                                          encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func fail(_ list: RuleList, _ reason: String) -> String {
        progress = .failed(list.name, reason)
        return reason
    }

    private func forget(_ id: String) {
        settings.forgetRuleList(id)
    }
}
