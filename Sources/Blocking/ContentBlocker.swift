import CryptoKit
import WebKit

/// Le blocage.
///
/// **Les règles arrivent déjà traduites.** L'asset `wuji-rules.json` est écrit dans le format de
/// `WKContentRuleList` — celui que WebKit compile directement. Il n'y a plus de
/// convertisseur au démarrage, plus de listes à télécharger, plus d'index à reconstruire :
/// le navigateur lit un fichier de treize kilo-octets et le donne au moteur.
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
        case active(rules: Int)
        case failed(String)

        var summary: String {
            switch self {
            case .off:              return "Blocage désactivé"
            case .compiling:        return "Préparation…"
            case .active(let rules): return "\(rules) règles actives"
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

    private static let identifier = "wuji.rules"
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

    /// Le nombre de règles de l'asset, lu une fois. Sert à l'affichage, et à rien d'autre.
    private(set) var bundledCount = 0

    func start() { compile() }

    /// Assemble l'asset, les règles de l'utilisateur et ses exceptions, puis compile.
    ///
    /// **Une seule liste compilée.** Elle tient très largement sous le plafond de WebKit, et
    /// `ignore-previous-rules` n'annulant que dans la liste où il figure, tout doit de toute
    /// façon vivre au même endroit pour que les exceptions fonctionnent.
    func compile() {
        guard settings.blockingEnabled else { return apply([], state: .off) }
        guard let asset = Self.asset() else {
            return apply([], state: .failed("les règles livrées sont introuvables"))
        }

        // Déjà au format de WebKit, comme tout le reste : rien à traduire.
        let mine = userRules.rules
        // Les exceptions viennent en dernier : `ignore-previous-rules` annule ce qui le
        // précède, et rien d'autre.
        let exceptions = (settings.blockingExceptions + settings.privateBlockingExceptions)
            .map(WebKitRule.exception(for:))

        bundledCount = asset.count
        let json = "[" + (asset + mine + exceptions).joined(separator: ",") + "]"
        let total = asset.count + mine.count

        // Même contenu qu'au dernier lancement : la liste compilée est encore dans le
        // magasin de WebKit, on la reprend telle quelle.
        var hasher = SHA256()
        hasher.update(data: Data(json.utf8))
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        state = .compiling
        onChange?()

        Task { [weak self] in
            guard let store = WKContentRuleListStore.default() else { return }
            if signature == UserDefaults.standard.string(forKey: Self.signatureKey),
               let known = try? await store.contentRuleList(forIdentifier: Self.identifier) {
                self?.apply([known], state: .active(rules: total))
                await Self.sweepStore()
                return
            }
            do {
                guard let list = try await store.compileContentRuleList(
                    forIdentifier: Self.identifier, encodedContentRuleList: json) else { return }
                UserDefaults.standard.set(signature, forKey: Self.signatureKey)
                self?.apply([list], state: .active(rules: total))
                await Self.sweepStore()
            } catch {
                // Une règle écrite à la main peut être refusée par le moteur. On le dit, et
                // on garde ce qui marchait : un bloqueur amputé vaut mieux qu'un bloqueur
                // éteint, et un message vaut mieux qu'un silence.
                self?.apply(self?.compiled ?? [],
                            state: .failed("une règle a été refusée par le moteur"))
            }
        }
    }

    /// L'asset livré avec l'application : une règle par ligne, telle qu'elle est écrite
    /// dans le dépôt.
    ///
    /// Le fichier porte aussi des repères de lecture — les lignes en `//` qui nomment les
    /// sections. On ne retient que les lignes qui sont des règles, donc le moteur ne voit
    /// jamais rien d'autre, et le fichier reste relisible par un humain.
    nonisolated private static func asset() -> [String]? {
        guard let url = Bundle.main.url(forResource: "wuji-rules", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            .filter { $0.hasPrefix("{") && $0.hasSuffix("}") }
    }

    /// Efface du magasin de WebKit tout ce qui n'est pas la liste courante.
    ///
    /// Le magasin garde ce qu'on y a mis, indéfiniment. Les tranches de l'époque où Wuji
    /// compilait vingt-deux listes y occupaient encore soixante-dix-huit mégaoctets alors
    /// que plus rien ne les réclamait.
    private static func sweepStore() async {
        guard let store = WKContentRuleListStore.default() else { return }
        let identifiers = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for name in identifiers where name != identifier {
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

    func addUserRule(_ rule: String) {
        userRules.add(rule)
        compile()
    }

    func removeUserRule(_ rule: String) {
        userRules.remove(rule)
        compile()
    }
}

