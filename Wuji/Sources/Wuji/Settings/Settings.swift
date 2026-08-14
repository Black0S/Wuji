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
    var safariInspection: Bool {
        didSet { store.set(safariInspection, forKey: Key.inspection); changed() }
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

    // MARK: - Protection

    var blockingEnabled: Bool {
        didSet { store.set(blockingEnabled, forKey: Key.blocking); changed() }
    }
    /// Les sites où la protection est éteinte, par hôte. Une page cassée par le filtrage
    /// ne doit pas obliger à choisir entre cette page et la protection partout ailleurs.
    var blockingExceptions: [String] {
        didSet { store.set(blockingExceptions, forKey: Key.blockingExceptions); changed() }
    }

    /// Les exceptions posées depuis un espace privé.
    ///
    /// **Elles ne sont pas écrites sur le disque et meurent avec la session.** Lever la
    /// protection sur un site en privé la levait aussi en normal : la décision d'un moment
    /// où l'on demande explicitement à ne rien laisser survivait à ce moment-là, ce qui est
    /// le contraire de ce que « privé » promet.
    var privateBlockingExceptions: [String] = [] { didSet { changed() } }

    var onChange: (() -> Void)?

    // MARK: - Stockage

    private let store = UserDefaults.standard

    private enum Key {
        static let theme = "theme"
        static let searchEngine = "searchEngine"
        static let pageZoom = "pageZoom"
        static let inspection = "safariInspection"
        static let retention = "historyRetention"
        static let blocking = "blockingEnabled"
        static let blockingExceptions = "blockingExceptions"
        static let agent = "agent"
    }

    init() {
        // Les valeurs par défaut sont déclarées ici et nulle part ailleurs : `object(forKey:)`
        // distingue « jamais réglé » de « réglé à zéro », ce que `bool(forKey:)` ne fait pas.
        theme = Theme(rawValue: store.string(forKey: Key.theme) ?? "") ?? .auto
        searchEngine = SearchEngine(rawValue: store.string(forKey: Key.searchEngine) ?? "") ?? .duckduckgo
        pageZoom = store.object(forKey: Key.pageZoom).map { CGFloat($0 as? Double ?? 1) } ?? 1
        safariInspection = store.bool(forKey: Key.inspection)
        historyRetention = store.object(forKey: Key.retention) as? Int ?? 90
        blockingEnabled = store.object(forKey: Key.blocking) as? Bool ?? true
        blockingExceptions = store.stringArray(forKey: Key.blockingExceptions) ?? []
        agent = Agent(rawValue: store.string(forKey: Key.agent) ?? "") ?? .safari
    }

    private func changed() { onChange?() }
}
