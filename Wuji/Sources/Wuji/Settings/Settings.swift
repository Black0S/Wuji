import AppKit

/// Les réglages du prototype.
///
/// Règle tenue ici : **aucun contrôle mort.** Chaque interrupteur de cette fenêtre pilote
/// quelque chose de réel. Un réglage qui ne fait rien est pire qu'un réglage absent — il
/// donne l'illusion d'un produit plus avancé qu'il ne l'est, et c'est ce qui rend les
/// maquettes trompeuses quand on les prend pour un cahier des charges.
///
/// Le curseur « UI Transparency » de la maquette n'existe donc pas : la direction
/// artistique est en flat, il ne piloterait rien. Sa place revient au délai d'escamotage,
/// qui est un vrai paramètre — et justement celui que J0 doit trouver.
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

    // Apparence
    var theme: Theme = .auto { didSet { changed() } }
    /// Le garde-fou d'accessibilité de la spec §4.5 : l'auto-masquage est hostile à la
    /// navigation clavier exclusive et à VoiceOver. En faire un choix, jamais une contrainte.
    var alwaysVisibleUI = false { didSet { changed() } }
    var hideDelay: TimeInterval = 0.35 { didSet { changed() } }

    // Révélation — les seuils que J0 doit trouver, réglables sans recompiler
    var revealZone: CGFloat = 6 { didSet { changed() } }
    var keepZone: CGFloat = 96 { didSet { changed() } }
    var edgeEnabled = true { didSet { changed() } }
    var overscrollEnabled = true { didSet { changed() } }
    var threeFingerEnabled = true { didSet { changed() } }

    // Recherche et contenu
    var searchEngine: SearchEngine = .duckduckgo { didSet { changed() } }
    var homepage = "https://www.apple.com" { didSet { changed() } }
    var pageZoom: CGFloat = 1 { didSet { changed() } }
    var safariInspection = false { didSet { changed() } }

    var onChange: (() -> Void)?

    private func changed() { onChange?() }
}
