import AppKit

/// Les réglages.
///
/// Règle tenue ici : **aucun contrôle mort.** Chaque interrupteur de cette fenêtre pilote
/// quelque chose de réel. Un réglage qui ne fait rien est pire qu'un réglage absent — il
/// donne l'illusion d'un produit plus avancé qu'il ne l'est, et c'est ce qui rend les
/// maquettes trompeuses quand on les prend pour un cahier des charges.
///
/// Le curseur « UI Transparency » de la maquette n'existe donc pas : la direction
/// artistique est en flat, il ne piloterait rien.
///
/// **Tout est relu au démarrage.** Ça paraît évident et ça ne l'était pas : les réglages
/// vivaient en mémoire, donc le thème, le moteur de recherche et la rétention d'historique
/// revenaient à leur valeur d'usine à chaque lancement. Un réglage qu'il faut refaire
/// chaque matin n'est pas un réglage.
@MainActor
final class Settings {

    enum Theme: String, CaseIterable {
        case light, dark, auto

        var label: String {
            switch self {
            case .light: return "Clair"
            case .dark:  return "Sombre"
            case .auto:  return "Auto"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .light: return NSAppearance(named: .aqua)
            case .dark:  return NSAppearance(named: .darkAqua)
            case .auto:  return nil
            }
        }
    }

    enum SearchEngine: String, CaseIterable {
        case duckduckgo, qwant, google, bing

        var label: String {
            switch self {
            case .duckduckgo: return "DuckDuckGo"
            case .qwant:      return "Qwant"
            case .google:     return "Google"
            case .bing:       return "Bing"
            }
        }

        var endpoint: String {
            switch self {
            case .duckduckgo: return "https://duckduckgo.com/"
            case .qwant:      return "https://www.qwant.com/"
            case .google:     return "https://www.google.com/search"
            case .bing:       return "https://www.bing.com/search"
            }
        }

        func url(for query: String) -> URL? {
            var components = URLComponents(string: endpoint)
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            return components?.url
        }
    }

    // MARK: - Apparence

    var theme: Theme { didSet { store.set(theme.rawValue, forKey: Key.theme); changed() } }

    // MARK: - Recherche et contenu

    var searchEngine: SearchEngine {
        didSet { store.set(searchEngine.rawValue, forKey: Key.searchEngine); changed() }
    }
    var pageZoom: CGFloat { didSet { store.set(Double(pageZoom), forKey: Key.pageZoom); changed() } }

    /// Le zoom retenu pour un site, quand il diffère du réglage général.
    ///
    /// **Un site qui se lit mal ne doit pas imposer sa correction à tous les autres.** Le
    /// réglage général reste la valeur par défaut ; ceci ne garde que les écarts, ce qui
    /// évite d'enregistrer une ligne pour chaque site visité.
    var siteZoom: [String: Double] {
        didSet { store.set(siteZoom, forKey: Key.siteZoom); changed() }
    }
    /// Rétention de l'historique, en jours. La spec §4.1 la veut configurable : c'est ce
    /// qui rend « vos données restent chez vous » vérifiable plutôt que déclaratif.
    var historyRetention: Int {
        didSet { store.set(historyRetention, forKey: Key.retention); changed() }
    }

    /// L'agent que Wuji annonce aux sites.
    ///
    /// **Se faire passer pour un autre navigateur est parfois la seule façon d'entrer.**
    /// Des sites refusent tout ce qu'ils ne reconnaissent pas, et le moteur reste WebKit
    /// quoi qu'on déclare — on ne gagne pas les capacités de Chrome en portant son nom, on
    /// gagne le droit d'essayer.
    enum Agent: String, CaseIterable {
        case safari, chrome, firefox

        var label: String {
            switch self {
            case .safari:  return "Safari"
            case .chrome:  return "Chrome"
            case .firefox: return "Firefox"
            }
        }

        /// Ce qui est ajouté à l'agent que WebKit compose lui-même. Safari est le défaut,
        /// et le plus discret : c'est la foule dans laquelle on se cache.
        var applicationName: String {
            switch self {
            case .safari:  return "Version/26.6 Safari/605.1.15"
            case .chrome:  return "Version/26.6 Safari/605.1.15 Chrome/131.0.0.0"
            case .firefox: return "Version/26.6 Safari/605.1.15 Firefox/133.0"
            }
        }
    }

    var agent: Agent { didSet { store.set(agent.rawValue, forKey: Key.agent); changed() } }

    /// Les scripts de l'utilisateur, en bloc.
    ///
    /// Éteint, **l'icône quitte la barre** : une fonction qu'on n'utilise pas ne doit pas
    /// occuper de place.
    var userScriptsEnabled: Bool {
        didSet { store.set(userScriptsEnabled, forKey: Key.userScripts); changed() }
    }

    /// Chercher une version plus récente au lancement.
    ///
    /// **Éteint par défaut, et ce n'est pas de la timidité.** Le projet promet que rien ne
    /// part de cette machine sans qu'on l'ait demandé ; une requête au démarrage
    /// contredirait cette phrase pour tout le monde, y compris ceux qui ne l'ont pas lue.
    /// Le bouton « Vérifier » reste disponible à tout moment.
    var checkUpdatesAtLaunch: Bool {
        didSet { store.set(checkUpdatesAtLaunch, forKey: Key.checkUpdates); changed() }
    }

    /// Proposer d'enregistrer les mots de passe, et les remplir.
    ///
    /// **Allumé par défaut, et c'est un changement de position assumé.** Le projet refusait
    /// d'en garder tant qu'il n'avait pas de trousseau ; il n'en a toujours pas, et n'en
    /// aura jamais — il range dans celui de macOS. Éteint, plus rien n'est proposé ni
    /// rempli ; ce qui est déjà dans le trousseau y reste, parce que ce n'est pas à un
    /// réglage de navigateur d'effacer ce que le système garde.
    var passwordsEnabled: Bool {
        didSet { store.set(passwordsEnabled, forKey: Key.passwords); changed() }
    }

    // MARK: - Blocage

    /// Les listes de blocage en service, par nom de fichier d'origine.
    ///
    /// **Wuji n'en livre aucune.** Ce tableau est vide tant qu'on n'a rien choisi, et c'est
    /// l'état par défaut : un navigateur qui arriverait avec ses listes aurait choisi pour
    /// vous ce qu'il faut bloquer, et personne ne saurait dire quoi.
    var enabledRuleLists: [String] {
        didSet { store.set(enabledRuleLists, forKey: Key.enabledRuleLists); changed() }
    }

    /// La version installée de chaque liste. C'est elle qui dit s'il faut refaire le
    /// travail de compilation, et non la présence du fichier — les règles compilées vivent
    /// dans le magasin de WebKit, pas chez nous.
    var ruleListVersions: [String: String] {
        didSet { store.set(ruleListVersions, forKey: Key.ruleListVersions); changed() }
    }

    /// Les fichiers compilés de chaque liste. Une grande liste en compte plusieurs : WebKit
    /// refuse au-delà de cent cinquante mille règles, et la conversion découpe.
    var ruleListFiles: [String: [String]] {
        didSet { store.set(ruleListFiles, forKey: Key.ruleListFiles); changed() }
    }

    /// Combien de règles chaque liste apporte — pour le dire, rien d'autre.
    var ruleListRules: [String: Int] {
        didSet { store.set(ruleListRules, forKey: Key.ruleListRules); changed() }
    }

    /// Les sites où le blocage est **suspendu**.
    ///
    /// **Une pause par site, pas un interrupteur général.** Un site qui se casse à cause
    /// d'une règle se répare en levant le blocage sur lui seul ; couper partout pour un site
    /// est le geste qu'on ne défait jamais, parce qu'on oublie l'avoir fait.
    var pausedHosts: [String] {
        didSet { store.set(pausedHosts, forKey: Key.pausedHosts); changed() }
    }

    /// Les règles posées à la main, par le sélecteur d'éléments.
    ///
    /// **Elles ne vont nulle part.** Une règle dit ce qu'on ne veut pas voir sur un site
    /// qu'on visite : c'est une information sur soi, et elle reste ici.
    var userBlockRules: [UserRules.Rule] {
        didSet {
            store.set(try? JSONEncoder().encode(userBlockRules), forKey: Key.userBlockRules)
            changed()
        }
    }

    /// Retient tout ce qu'il faut pour remettre une liste en service au lancement suivant.
    func rememberRuleList(_ id: String, version: String, files: [String], rules: Int) {
        batch {
            if !enabledRuleLists.contains(id) { enabledRuleLists.append(id) }
            ruleListVersions[id] = version
            ruleListFiles[id] = files
            ruleListRules[id] = rules
        }
    }

    func forgetRuleList(_ id: String) {
        batch {
            enabledRuleLists.removeAll { $0 == id }
            ruleListVersions[id] = nil
            ruleListFiles[id] = nil
            ruleListRules[id] = nil
        }
    }

    /// Quatre écritures, **un seul avis**.
    ///
    /// Chaque champ prévient à part, et l'avis relit tous les onglets ouverts pour leur
    /// reposer zoom, agent et couleur de fond. Retenir une liste touche quatre champs :
    /// c'était donc quatre parcours de la session pour un seul geste, et soixante-seize
    /// pour « Tout mettre à jour » sur dix-neuf listes. On garde l'avis pour la fin.
    ///
    /// Le compteur plutôt qu'un booléen : deux lots imbriqués — cela arrivera — ne doivent
    /// pas laisser le premier rendre la main au milieu du second.
    func batch(_ body: () -> Void) {
        batching += 1
        body()
        batching -= 1
        guard batching == 0, pending else { return }
        pending = false
        onChange?()
    }

    private var batching = 0
    private var pending = false

    var onChange: (() -> Void)?

    // MARK: - Stockage

    private let store = UserDefaults.standard

    private enum Key {
        static let theme = "theme"
        static let searchEngine = "searchEngine"
        static let pageZoom = "pageZoom"
        static let siteZoom = "siteZoom"
        static let retention = "historyRetention"
        static let agent = "agent"
        static let userScripts = "userScriptsEnabled"
        static let checkUpdates = "checkUpdatesAtLaunch"
        static let passwords = "passwordsEnabled"
        static let enabledRuleLists = "enabledRuleLists"
        static let ruleListVersions = "ruleListVersions"
        static let ruleListFiles = "ruleListFiles"
        static let ruleListRules = "ruleListRules"
        static let userBlockRules = "userBlockRules"
        static let pausedHosts = "pausedHosts"
        /// L'ancienne clé, relue une fois pour ne rien perdre — voir l'initialisation.
        static let extensionFolders = "extensionFolders"
    }

    init() {
        // Les valeurs par défaut sont déclarées ici et nulle part ailleurs : `object(forKey:)`
        // distingue « jamais réglé » de « réglé à zéro », ce que `bool(forKey:)` ne fait pas.
        theme = Theme(rawValue: store.string(forKey: Key.theme) ?? "") ?? .auto
        searchEngine = SearchEngine(rawValue: store.string(forKey: Key.searchEngine) ?? "") ?? .duckduckgo
        pageZoom = store.object(forKey: Key.pageZoom).map { CGFloat($0 as? Double ?? 1) } ?? 1
        siteZoom = store.dictionary(forKey: Key.siteZoom) as? [String: Double] ?? [:]
        historyRetention = store.object(forKey: Key.retention) as? Int ?? 90
        agent = Agent(rawValue: store.string(forKey: Key.agent) ?? "") ?? .safari
        userScriptsEnabled = store.object(forKey: Key.userScripts) as? Bool ?? true
        checkUpdatesAtLaunch = store.bool(forKey: Key.checkUpdates)
        passwordsEnabled = store.object(forKey: Key.passwords) as? Bool ?? true
        enabledRuleLists = store.stringArray(forKey: Key.enabledRuleLists) ?? []
        ruleListVersions = store.dictionary(forKey: Key.ruleListVersions) as? [String: String] ?? [:]
        ruleListFiles = store.dictionary(forKey: Key.ruleListFiles) as? [String: [String]] ?? [:]
        ruleListRules = store.dictionary(forKey: Key.ruleListRules) as? [String: Int] ?? [:]
        pausedHosts = store.stringArray(forKey: Key.pausedHosts) ?? []
        userBlockRules = (store.data(forKey: Key.userBlockRules))
            .flatMap { try? JSONDecoder().decode([UserRules.Rule].self, from: $0) } ?? []
    }

    private func changed() {
        guard batching == 0 else { pending = true; return }
        onChange?()
    }
}
