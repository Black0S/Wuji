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

    // MARK: - Extensions

    /// Les extensions activées, par identifiant de paquet.
    ///
    /// **On enregistre ce qui est allumé, à l'inverse des listes de blocage d'autrefois.**
    /// Une extension trouvée sur la machine n'a rien demandé à personne : elle arrive donc
    /// éteinte, et son activation est une décision qu'on a prise en lisant ce qu'elle
    /// réclame. Le contraire aurait fait tourner du code tiers sur simple installation
    /// d'une application dans `/Applications`.
    var enabledExtensions: [String] {
        didSet { store.set(enabledExtensions, forKey: Key.enabledExtensions); changed() }
    }

    /// Les extensions posées dans la barre du haut, **dans l'ordre où on les y a mises**.
    ///
    /// Un tableau et non un ensemble : la barre a un ordre, on le voit, et le rendre
    /// arbitraire ferait danser les icônes d'un lancement à l'autre.
    var pinnedExtensions: [String] {
        didSet { store.set(pinnedExtensions, forKey: Key.pinnedExtensions); changed() }
    }

    /// Ce que l'on a **désigné** : une application, un `.appex`, un dossier décompressé.
    ///
    /// Wuji ne parcourt plus `/Applications`. Il y proposait tout ce qu'il trouvait, ce qui
    /// était commode et dressait, sans qu'on l'ait demandé, la liste de ce qui est installé
    /// sur l'ordinateur. On désigne, il regarde ; il ne regarde rien d'autre.
    var extensionSources: [String] {
        didSet { store.set(extensionSources, forKey: Key.extensionSources); changed() }
    }

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
        static let enabledExtensions = "enabledExtensions"
        static let pinnedExtensions = "pinnedExtensions"
        static let extensionSources = "extensionSources"
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
        enabledExtensions = store.stringArray(forKey: Key.enabledExtensions) ?? []
        pinnedExtensions = store.stringArray(forKey: Key.pinnedExtensions) ?? []
        // Les dossiers ouverts à la main du temps où la liste venait d'un balayage : ils
        // sont des sources comme les autres, et les oublier ferait disparaître ce que
        // quelqu'un avait déjà ajouté.
        extensionSources = store.stringArray(forKey: Key.extensionSources)
            ?? store.stringArray(forKey: Key.extensionFolders)
            ?? []
    }

    private func changed() { onChange?() }
}
