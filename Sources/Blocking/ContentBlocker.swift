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

    /// Le dernier échec, s'il y en a eu un. Il porte l'identité autant que le nom : la
    /// page doit savoir **quelle ligne** a échoué pour lui rendre sa case, et un nom
    /// affiché ne suffit pas à retrouver une ligne.
    struct Failure: Equatable {
        let id: String
        let name: String
        let why: String
    }

    /// Un fichier téléchargé, prêt à compiler. Séparé du téléchargement pour que celui-ci
    /// puisse se faire hors de l'acteur principal : convertir trente-sept mégaoctets en
    /// chaîne sur le fil de l'interface fige la fenêtre le temps de la conversion.
    struct Ready: Sendable {
        let identifier: String
        let json: String
    }

    /// Ce qu'un téléchargement rapporte. Un type à nous plutôt que `Result` : la raison
    /// d'un refus est une phrase qu'on affiche, pas une erreur qu'on relance.
    enum Fetched: Sendable {
        case ready([Ready])
        case refused(String)
    }

    private let settings: Settings
    private let store = WKContentRuleListStore.default()

    /// Les listes compilées et prêtes, par identité de liste.
    private(set) var installed: [String: [WKContentRuleList]] = [:]
    /// Ce que chaque liste est en train de faire — « téléchargement », « compilation ».
    ///
    /// **Un dictionnaire, pas un état unique.** « Tout mettre à jour » en enchaîne dix-neuf,
    /// et un seul état courant aurait obligé la page à deviner de qui il parlait. C'est
    /// aussi ce qui permet de tenir la case cochée pendant le travail : une liste en cours
    /// d'installation n'est pas encore dans les réglages, et la page la décochait sous le
    /// doigt de celui qui venait de la cocher.
    private(set) var working: [String: String] = [:]
    private(set) var failure: Failure?
    /// Combien de règles ont été écartées par la garde, liste par liste. Dit plutôt que tu :
    /// une liste amputée sans qu'on le sache est une liste en qui on croit à tort.
    private(set) var dropped: [String: Int] = [:]
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
                    guard let list = await lookUp(identifier: Self.identifier(for: file)) else {
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
    func sweep(_ report: ((Int) -> Void)? = nil) {
        let keep = Set(settings.enabledRuleLists.flatMap { settings.ruleListFiles[$0] ?? [] }
            .map { Self.identifier(for: $0) })
            .union([UserRules.identifier])

        store?.getAvailableContentRuleListIdentifiers { identifiers in
            MainActor.assumeIsolated {
                var jetées = 0
                for id in identifiers ?? []
                where id.hasPrefix("wuji.") && !keep.contains(id) {
                    self.store?.removeContentRuleList(forIdentifier: id) { _ in }
                    jetées += 1
                }
                if jetées > 0 { report?(jetées) }
            }
        }
    }

    // MARK: - Installer, retirer

    /// Télécharge, compile et met en service. Rend l'erreur en français, ou `nil`.
    @discardableResult
    func install(_ list: RuleList) async -> String? {
        working[list.id] = "téléchargement"
        failure = nil
        onChange?()
        defer { working[list.id] = nil; onChange?() }

        switch await Self.download(list) {
        case .refused(let why):
            return fail(list, why)
        case .ready(let parts):
            return await compileAndRemember(list, parts)
        }
    }

    /// Met une liste à jour **sans jamais la laisser sans règles**.
    ///
    /// L'ancienne façon retirait puis réinstallait : un échec de réseau entre les deux
    /// laissait la liste absente des réglages, c'est-à-dire décochée, alors qu'on n'avait
    /// rien demandé de tel. On compile donc d'abord — le magasin remplace un fichier de même
    /// nom sans qu'on ait à le supprimer — et l'on ne jette ensuite que les morceaux dont la
    /// nouvelle version n'a plus l'usage : une conversion qui change de découpage laisserait
    /// sinon ses anciennes tranches sur le disque pour toujours.
    @discardableResult
    func update(_ list: RuleList) async -> String? {
        let anciens = Set(settings.ruleListFiles[list.id] ?? [])
        if let why = await install(list) { return why }
        discard(anciens.subtracting(list.parts.map(\.file)))
        return nil
    }

    /// Installe ou met à jour un lot de listes, en **recouvrant le réseau et la compilation**.
    ///
    /// Une mise à jour se passe en deux temps de natures différentes : télécharger, qui
    /// attend le réseau, et compiler, qui occupe WebKit pendant plusieurs secondes. Faites
    /// à la file, dix-neuf listes paient les deux dix-neuf fois. La suivante se télécharge
    /// donc pendant que la courante compile — une seule d'avance, jamais deux : on ne garde
    /// pas deux fichiers de trente mégaoctets en mémoire pour gagner deux secondes.
    ///
    /// Rend les échecs, dans l'ordre. Une liste qui échoue n'arrête pas les autres : c'est
    /// souvent une seule liste qui a bougé chez elle, et abandonner les dix-huit restantes
    /// pour celle-là serait le contraire de ce qu'on a demandé.
    /// `onStep` est appelé après chaque liste, avec le rang et le total : c'est ce que le
    /// bouton affiche pendant qu'il travaille. Un lot de dix-neuf listes prend une minute,
    /// et un bouton qui ne dit rien pendant une minute passe pour cassé.
    func applyAll(_ lists: [RuleList], onStep: (Int, Int) -> Void = { _, _ in }) async -> [String] {
        var failures: [String] = []
        var avance: (id: String, résultat: Fetched)?
        failure = nil

        for (index, list) in lists.enumerated() {
            working[list.id] = "téléchargement"
            onChange?()

            let téléchargé: Fetched
            if let avance, avance.id == list.id {
                téléchargé = avance.résultat
            } else {
                téléchargé = await Self.download(list)
            }
            avance = nil

            // La suivante part maintenant : elle traversera le réseau pendant que WebKit
            // compile celle-ci, et sera prête quand son tour viendra.
            var suivante: Task<Fetched, Never>?
            let après = index + 1 < lists.count ? lists[index + 1] : nil
            if let après, après.bytes <= Self.lookAheadLimit {
                suivante = Task.detached { await Self.download(après) }
            }

            let anciens = Set(settings.ruleListFiles[list.id] ?? [])
            switch téléchargé {
            case .refused(let why):
                failures.append("« \(list.name) » : \(why)")
                _ = fail(list, why)
            case .ready(let parts):
                if let why = await compileAndRemember(list, parts) {
                    failures.append("« \(list.name) » : \(why)")
                } else {
                    discard(anciens.subtracting(list.parts.map(\.file)))
                }
            }
            working[list.id] = nil
            onStep(index + 1, lists.count)
            onChange?()

            if let suivante, let après { avance = (après.id, await suivante.value) }
        }
        return failures
    }

    /// Au-delà, on ne prend pas d'avance : deux gros fichiers en mémoire coûtent plus que
    /// les secondes qu'ils font gagner.
    private static let lookAheadLimit = 32 * 1_048_576

    /// Retire une liste du service **et du disque**. Garder des règles compilées pour une
    /// liste qu'on a décochée occuperait des centaines de mégaoctets pour rien.
    func remove(_ id: String) {
        let files = settings.ruleListFiles[id] ?? []
        installed[id] = nil
        working[id] = nil
        if failure?.id == id { failure = nil }
        forget(id)
        discard(Set(files))
        onChange?()
    }

    /// Jette des fichiers compilés du magasin. C'est **la** façon de rendre la place : le
    /// magasin est sur le disque et ne se vide pas tout seul.
    private func discard(_ files: Set<String>) {
        for file in files {
            store?.removeContentRuleList(forIdentifier: Self.identifier(for: file)) { _ in }
        }
    }

    /// La version installée diffère-t-elle de celle du catalogue ?
    ///
    /// **La version amont ne dit pas tout, et pour deux raisons mesurées.** Seize listes du
    /// dépôt n'en publient aucune — les listes d'uBlock et celles d'EasyList n'ont pas de
    /// numéro dans leur en-tête : comparer deux chaînes vides les aurait déclarées à jour
    /// pour toujours. Et une conversion améliorée ne touche pas à la version d'origine :
    /// un correctif du convertisseur n'aurait donc atteint personne.
    ///
    /// Le nombre de règles produites répond aux deux : il vient du même index, il change
    /// quand la liste change **et** quand la conversion change, et on le retient déjà.
    func isOutdated(_ list: RuleList) -> Bool {
        guard settings.ruleListFiles[list.id] != nil else { return false }
        // L'empreinte du fichier d'origine et le nombre de règles produites, ensemble : la
        // première dit que la liste a changé chez son mainteneur, le second qu'elle a
        // changé chez le convertisseur. Une liste installée avant que le dépôt ne publie
        // d'empreinte n'en a pas : on retombe alors sur la version, puis sur le compte.
        if let posée = settings.ruleListBuilds[list.id], !posée.isEmpty {
            return posée != list.build
        }
        if let connue = settings.ruleListVersions[list.id], connue != list.version { return true }
        if let comptées = settings.ruleListRules[list.id], comptées != list.rules { return true }
        return false
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

    /// Le blocage est-il suspendu pour ce site ?
    func isPaused(_ host: String?) -> Bool {
        guard let host else { return false }
        return settings.pausedHosts.contains(UserRules.registrable(host))
    }

    func setPaused(_ paused: Bool, host: String) {
        let site = UserRules.registrable(host)
        if paused {
            if !settings.pausedHosts.contains(site) { settings.pausedHosts.append(site) }
        } else {
            settings.pausedHosts.removeAll { $0 == site }
        }
        onChange?()
    }

    /// Repose les règles sur une vue déjà ouverte : activer une liste doit valoir tout de
    /// suite, sans avoir à recharger l'onglet à la main.
    func reapply(to controller: WKUserContentController, host: String? = nil) {
        controller.removeAllContentRuleLists()
        // **La pause se fait en ne posant rien.** WebKit n'a pas de « désactiver » : une
        // liste posée s'applique. On la retire donc de la vue, et on la repose quand on
        // quitte le site — c'est aussi ce qui garantit qu'une pause ne déborde jamais sur
        // l'onglet d'à côté.
        guard !isPaused(host) else { return }
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
    ///
    /// `nonisolated` : le téléchargement en a besoin, et il ne travaille pas sur l'acteur
    /// principal. Un calcul de chaîne n'a de toute façon rien à y faire.
    nonisolated static func identifier(for file: String) -> String {
        "wuji." + file.replacingOccurrences(of: ".json", with: "")
    }

    /// Va chercher les morceaux d'une liste, **hors de l'acteur principal**.
    ///
    /// Ce qui se passait avant sur le fil de l'interface : trente-sept mégaoctets reçus,
    /// puis convertis en `String`, ce qui recopie l'octet à l'octet — la fenêtre ne
    /// répondait plus pendant la conversion, sans qu'aucune ligne ne dise pourquoi. Rien
    /// ici ne touche à l'état de la classe : c'est ce qui rend le déplacement possible.
    ///
    /// Les morceaux partent **en parallèle**. Une grande liste est découpée en tranches
    /// parce que WebKit refuse au-delà de cent cinquante mille règles ; elles ne dépendent
    /// pas les unes des autres, et les demander à la file ne payait que l'attente.
    nonisolated static func download(_ list: RuleList) async -> Fetched {
        await withTaskGroup(of: (Int, Fetched).self) { group in
            for (rang, part) in list.parts.enumerated() {
                group.addTask {
                    do {
                        let (data, response) = try await URLSession.shared.data(
                            from: RuleCatalog.file(part.file))
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            return (rang, .refused("téléchargement refusé"))
                        }
                        guard let json = String(data: data, encoding: .utf8) else {
                            return (rang, .refused("fichier illisible (\(part.file))"))
                        }
                        return (rang, .ready([Ready(identifier: identifier(for: part.file),
                                                    json: json)]))
                    } catch {
                        return (rang, .refused("réseau indisponible"))
                    }
                }
            }
            // Rassemblés dans l'ordre des tranches : elles se posent dans cet ordre, et
            // l'ordre d'arrivée du réseau n'a rien à voir avec celui des règles.
            var prêts = [Ready?](repeating: nil, count: list.parts.count)
            for await (rang, résultat) in group {
                switch résultat {
                case .refused(let why):
                    group.cancelAll()
                    return .refused(why)
                case .ready(let prêt):
                    prêts[rang] = prêt.first
                }
            }
            return .ready(prêts.compactMap { $0 })
        }
    }

    /// Compile ce qui a été téléchargé et le met en service.
    private func compileAndRemember(_ list: RuleList, _ parts: [Ready]) async -> String? {
        working[list.id] = "compilation"
        onChange?()
        var compiled: [WKContentRuleList] = []
        for part in parts {
            // **Une condition qu'on ne comprend pas rend la règle inerte, jamais plus
            // large.** WebKit ignore une clé de déclencheur inconnue : une règle dont c'est
            // justement cette clé qui restreint devient alors « bloquer tout ». Le balayage
            // coûte six millisecondes par mégaoctet et ne construit rien — voir `RuleGuard`.
            var json = part.json
            if !RuleGuard.onlyKnownKeys(json), let propre = RuleGuard.filtered(json) {
                json = propre.json
                dropped[list.id, default: 0] += propre.dropped
            }
            var rules = await compile(identifier: part.identifier, json: json)
            if rules == nil, let propre = RuleGuard.filtered(part.json) {
                // Le chemin cher, et seulement quand quelque chose a cassé : une valeur
                // inconnue — `resource-type: ["xmlhttprequest"]` — fait refuser le fichier
                // **entier**. On relit, on écarte les fautives, on retente. Des dizaines de
                // milliers de règles valent mieux qu'un fichier perdu pour une.
                rules = await compile(identifier: part.identifier, json: propre.json)
                if rules != nil { dropped[list.id, default: 0] += propre.dropped }
            }
            guard let rules else {
                // WebKit refuse une liste qu'il ne sait pas lire, et ne dit pas laquelle des
                // cent mille règles l'a gênée. On nomme le fichier : c'est ce qu'il faut
                // pour aller voir dans le dépôt.
                return fail(list, "règles refusées par WebKit (\(part.identifier))")
            }
            compiled.append(rules)
        }
        installed[list.id] = compiled
        settings.rememberRuleList(list.id, version: list.version,
                                  files: list.parts.map(\.file), rules: list.rules,
                                  build: list.build)
        return nil
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
        failure = Failure(id: list.id, name: list.name, why: reason)
        return reason
    }

    private func forget(_ id: String) {
        settings.forgetRuleList(id)
    }
}
