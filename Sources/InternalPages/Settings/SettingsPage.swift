import Foundation

/// Les réglages, en pages `wuji://settings`.
///
/// **La fenêtre séparée disparaît.** Elle obligeait à maintenir un second vocabulaire — des
/// contrôles AppKit, une mise en page à la main, une colonne de sections qui ressemblait à
/// celle du navigateur sans jamais être la même. Les réglages sont du contenu comme
/// l'historique ou les favoris : ils vivent dans un onglet, avec le sommaire commun, et
/// tout ce qui existe dans l'application se rejoint depuis n'importe laquelle de ses pages.
///
/// Règle inchangée : **aucun contrôle mort.** Chaque interrupteur pilote quelque chose de
/// réel, sinon il n'est pas là.
@MainActor
enum SettingsPage {

    enum Section {
        case features, appearance, privacy, search, websites, passwords, zoom, permissions

        static func from(path: String) -> Section {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "features":    return .features
            case "privacy":     return .privacy
            case "search":      return .search
            case "websites":    return .websites
            case "passwords":   return .passwords
            case "zoom":        return .zoom
            case "permissions": return .permissions
            default:            return .appearance
            }
        }

        var title: String {
            switch self {
            case .features:    return "Fonctions"
            case .appearance:  return "Apparence"
            case .privacy:     return "Confidentialité"
            case .search:      return "Recherche"
            case .websites:    return "Sites web"
            case .passwords:   return "Mots de passe"
            case .zoom:        return "Zoom par site"
            case .permissions: return "Autorisations"
            }
        }

        var address: String {
            switch self {
            case .features:    return "wuji://settings/features"
            case .appearance:  return "wuji://settings"
            case .privacy:     return "wuji://settings/privacy"
            case .search:      return "wuji://settings/search"
            case .websites:    return "wuji://settings/websites"
            case .passwords:   return "wuji://settings/passwords"
            case .zoom:        return "wuji://settings/zoom"
            case .permissions: return "wuji://settings/permissions"
            }
        }
    }

    struct State {
        var theme: String
        var searchEngine: String
        var pageZoom: Double
        var retention: Int
        var historyCount: Int
        /// Combien de sites ont laissé des données — cookies, stockage local, cache.
        /// `nil` tant que WebKit n'a pas répondu : le compte arrive d'un appel asynchrone,
        /// et annoncer zéro en attendant serait annoncer faux.
        var siteDataCount: Int?
        /// Ce que chaque site a laissé — son nom, et les familles de données en clair.
        var siteData: [(host: String, kinds: String)]
        var isDefaultBrowser: Bool
        var siteZoom: [(site: String, zoom: Int)]
        var version: String
        var checkUpdates: Bool
        var agent: String
        /// Les autorisations accordées ou refusées, par site.
        var permissions: [(host: String, kind: String, isAllowed: Bool)]
        /// Les identifiants rangés dans le trousseau — **hôte et compte seulement**. Le
        /// secret n'entre jamais dans cette page : ce qui y entre peut en ressortir.
        var logins: [(host: String, user: String)]
        var passwordsEnabled: Bool
        /// L'état du coffre. Deux booléens et non un : « pas encore créé » et « fermé » ne
        /// se traitent pas pareil — l'un se crée, l'autre s'ouvre.
        var vaultExists: Bool
        var vaultUnlocked: Bool
        /// La biométrie : disponible sur cette machine, et allumée pour ce coffre.
        var biometryAvailable: Bool
        var biometryEnabled: Bool
        /// Comment la clé est gardée quand la fonction est allumée : par l'Enclave, ou par
        /// une vérification que Wuji fait lui-même. La différence est réelle, donc elle est
        /// écrite sur la ligne plutôt que supposée.
        var biometrySealed: Bool
        /// Un ancien élément dort encore dans le trousseau, que Wuji n'utilise plus et ne
        /// peut pas effacer. Dit plutôt que tu, parce que c'est un secret de quelqu'un.
        var biometryLeftover = false
        /// Le nom que le système donne à sa biométrie — « Touch ID » ici, autre chose
        /// ailleurs. On l'affiche tel quel plutôt que de le supposer.
        var biometryName: String
    }

    static func html(section: Section, state: State) -> String {
        let body: String
        switch section {
        case .features:    body = features(state)
        case .appearance:  body = appearance(state)
        case .privacy:     body = privacy(state)
        case .search:      body = search(state)
        case .websites:    body = websites(state)
        case .passwords:   body = passwords(state)
        case .zoom:        body = zoom(state)
        case .permissions: body = permissions(state)
        }

        return InternalShell.page(
            title: section.title, current: section.address,
            body: """
            <header>
              <div class="titles">
                <h1>\(section.title)</h1>
                <p>Réglages de Wuji</p>
              </div>
            </header>
            <main>\(body)</main>
            """,
            script: script, style: style)
    }

    // MARK: - Sections

    /// Ce qu'on allume et ce qu'on éteint.
    ///
    /// **Une fonction éteinte disparaît de l'interface.** Sans ça, on garderait un bouton
}
