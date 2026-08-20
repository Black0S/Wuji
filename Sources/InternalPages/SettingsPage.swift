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
        case features, appearance, privacy, search, websites, development

        static func from(path: String) -> Section {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "features":    return .features
            case "privacy":     return .privacy
            case "search":      return .search
            case "websites":    return .websites
            case "development": return .development
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
            case .development: return "Développement"
            }
        }

        var address: String {
            switch self {
            case .features:    return "wuji://settings/features"
            case .appearance:  return "wuji://settings"
            case .privacy:     return "wuji://settings/privacy"
            case .search:      return "wuji://settings/search"
            case .websites:    return "wuji://settings/websites"
            case .development: return "wuji://settings/development"
            }
        }
    }

    struct State {
        var theme: String
        var searchEngine: String
        var pageZoom: Double
        var inspection: Bool
        var retention: Int
        var historyCount: Int
        var blockingEnabled: Bool
        var isDefaultBrowser: Bool
        var sleepDelay: Int
        var siteZoom: [(site: String, zoom: Int)]
        var userScripts: Bool
        var agent: String
        var blockingSummary: String
        /// Les listes livrées, dans l'ordre du catalogue.
        var ruleLists: [(id: String, name: String, summary: String, count: Int, isOn: Bool)]
        /// Les autorisations accordées ou refusées, par site.
        var permissions: [(host: String, kind: String, isAllowed: Bool)]
    }

    static func html(section: Section, state: State) -> String {
        let body: String
        switch section {
        case .features:    body = features(state)
        case .appearance:  body = appearance(state)
        case .privacy:     body = privacy(state)
        case .search:      body = search(state)
        case .websites:    body = websites(state)
        case .development: body = development(state)
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
    /// qui ne pilote plus rien — exactement le contrôle mort que le projet s'interdit.
    private static func features(_ state: State) -> String {
        // Quand c'est déjà le cas, la ligne le dit au lieu d'offrir un bouton qui ne
        // ferait rien : un contrôle mort est pire qu'un contrôle absent.
        row(title: "Navigateur par défaut",
            subtitle: state.isDefaultBrowser
                ? "Les liens ouverts ailleurs sur ce Mac arrivent dans Wuji."
                : "macOS demandera confirmation — c'est lui qui tranche, pas nous.",
            control: state.isDefaultBrowser
                ? #"<span class="readout">C'est le cas</span>"#
                : #"<button class="button" data-action="make-default">Définir</button>"#)
        + row(title: "Bloquer publicités et traqueurs",
            subtitle: escape(state.blockingSummary)
                + ". Elles ne visent que des domaines : les publicités servies depuis le "
                + "domaine du site lui-même, YouTube au premier chef, lui échappent.",
            control: toggle(name: "blocking", isOn: state.blockingEnabled))
        + ruleLists(state)
        + row(title: "Décharger les onglets inactifs",
              subtitle: "Un onglet qu'on ne regarde plus rend sa mémoire, sans quitter la "
                  + "colonne — le survol le réveille avant même le clic. Aucune valeur ne "
                  + "convient à toutes les machines, d'où le choix.",
              control: select(name: "sleep",
                              options: [("0", "Jamais"), ("60", "1 minute"),
                                        ("300", "5 minutes"), ("900", "15 minutes"),
                                        ("1800", "30 minutes"), ("3600", "1 heure")],
                              selected: String(state.sleepDelay)))
        + row(title: "Scripts utilisateur",
              subtitle: "Du code à vous, exécuté sur les sites que vous désignez. Éteint, "
                  + "l'icône quitte la barre et plus aucun script ne s'exécute.",
              control: toggle(name: "userscripts", isOn: state.userScripts))
    }

    /// Les listes, une par ligne, avec ce qu'elles pèsent.
    ///
    /// **Chaque liste se compile à part**, donc en éteindre une la retire réellement du
    /// moteur au lieu de la neutraliser — elle quitte aussi le disque. Le compte de règles
    /// est celui du fichier livré, pas une estimation : c'est ce qui rend le choix
    /// vérifiable plutôt que déclaratif.
    private static func ruleLists(_ state: State) -> String {
        let intro = """
        <div class="row block">
          <div class="labels">
            <span class="title">Listes de règles</span>
            <span class="subtitle">Elles sont livrées avec l'application, écrites dans le
            format que WebKit compile. En éteindre une la retire du moteur ; vos règles et
            vos exceptions, elles, s'appliquent toujours.</span>
          </div>
        </div>
        """
        // Le blocage éteint, ces interrupteurs ne piloteraient rien : on le dit au lieu de
        // les afficher. Un contrôle mort est pire qu'un contrôle absent.
        guard state.blockingEnabled else {
            return intro + #"<p class="none">Le blocage est éteint : aucune liste ne s'applique.</p>"#
        }
        return intro + state.ruleLists.map { list in
            row(title: escape(list.name),
                subtitle: escape(list.summary)
                    + " <span class=\"readout inline\">\(list.count) règles</span>",
                control: toggle(name: "list:\(list.id)", isOn: list.isOn))
        }.joined()
    }

    private static func development(_ state: State) -> String {
        row(title: "Autoriser l'inspection Safari",
            subtitle: "Rend les pages de Wuji inspectables depuis Safari : menu "
                + "Développement, puis cette machine. L'inspecteur ne s'ouvre pas dans "
                + "Wuji — WebKit ne le propose qu'à Safari.",
            control: toggle(name: "inspection", isOn: state.inspection))
    }

    private static func appearance(_ state: State) -> String {
        row(title: "Thème",
            subtitle: "« Auto » suit le réglage du système.",
            control: radios(name: "theme",
                            options: [("light", "Clair"), ("dark", "Sombre"), ("auto", "Auto")],
                            selected: state.theme))
    }

    private static func privacy(_ state: State) -> String {
        row(title: "Conserver l'historique",
              subtitle: "Au-delà, les pages sont effacées au lancement suivant.",
              control: """
              <input type="range" name="retention" min="7" max="365" value="\(state.retention)">
              <span class="readout" id="retention-value">\(state.retention) j</span>
              """)
        + row(title: "Effacer l'historique",
              subtitle: "\(state.historyCount) page\(state.historyCount > 1 ? "s" : "") enregistrée\(state.historyCount > 1 ? "s" : ""). L'effacement est immédiat et définitif.",
              control: #"<button class="button danger" data-action="clear-history">Effacer</button>"#)
    }

    private static func search(_ state: State) -> String {
        row(title: "Moteur de recherche",
            subtitle: "Utilisé quand ce que vous tapez n'est pas une adresse.",
            control: select(name: "engine",
                            options: [("duckduckgo", "DuckDuckGo"), ("qwant", "Qwant"),
                                      ("google", "Google"), ("bing", "Bing")],
                            selected: state.searchEngine))
    }

    private static func websites(_ state: State) -> String {
        let zoom = row(title: "Zoom par défaut",
                       subtitle: "Appliqué à toutes les pages.",
                       control: """
                       <input type="range" name="zoom" min="50" max="200" step="5" value="\(Int(state.pageZoom * 100))">
                       <span class="readout" id="zoom-value">\(Int(state.pageZoom * 100)) %</span>
                       """)

        // Les autorisations : une par site, révocable. Sans cette liste, une réponse donnée
        // une fois deviendrait irrévocable — ce qui la rendrait dangereuse à donner.
        let zooms = state.siteZoom.isEmpty
            ? #"<p class="none">Aucun site n'a de zoom qui lui soit propre.</p>"#
            : state.siteZoom.map { entry in
                """
                <div class="permission" data-site="\(escape(entry.site))">
                  <span class="mono">\(escape(entry.site))</span>
                  <span class="verdict yes">\(entry.zoom) %</span>
                  <button class="button" data-action="forget-zoom">Oublier</button>
                </div>
                """
            }.joined()

        let permissions = state.permissions.isEmpty
            ? #"<p class="none">Aucun site n'a demandé la caméra ou le micro.</p>"#
            : state.permissions.map { entry in
                """
                <div class="permission" data-host="\(escape(entry.host))" data-kind="\(entry.kind)">
                  <span class="mono">\(escape(entry.host))</span>
                  <span class="verdict \(entry.isAllowed ? "yes" : "no")">
                    \(entry.isAllowed ? "autorisé" : "refusé") · \(label(entry.kind))
                  </span>
                  <button class="button" data-action="forget-permission">Oublier</button>
                </div>
                """
            }.joined()

        let agent = row(title: "Se présenter comme",
                        subtitle: "Des sites refusent ce qu'ils ne reconnaissent pas. Le moteur reste WebKit quoi qu'on déclare.",
                        control: select(name: "agent",
                                        options: [("safari", "Safari"), ("chrome", "Chrome"),
                                                  ("firefox", "Firefox")],
                                        selected: state.agent))

        return zoom + agent + """
        <div class="row block">
          <div class="labels">
            <span class="title">Zoom par site</span>
            <span class="subtitle">⌘+ et ⌘− règlent le site qu'on regarde, et il s'en souvient. ⌘0 lui rend le zoom par défaut.</span>
          </div>
        </div>
        <div class="permissions">\(zooms)</div>
        """ + """
        <div class="row block">
          <div class="labels">
            <span class="title">Autorisations des sites</span>
            <span class="subtitle">Une réponse est retenue par site. L'oublier, c'est redemander à la prochaine visite.</span>
          </div>
        </div>
        <div class="permissions">\(permissions)</div>
        """
    }

    private static func label(_ kind: String) -> String {
        switch kind {
        case "camera":     return "caméra"
        case "microphone": return "micro"
        case "location":   return "position"
        default:           return "caméra et micro"
        }
    }

    // MARK: - Contrôles

    private static func row(title: String, subtitle: String, control: String) -> String {
        """
        <div class="row">
          <div class="labels">
            <span class="title">\(title)</span>
            <span class="subtitle">\(subtitle)</span>
          </div>
          <div class="control">\(control)</div>
        </div>
        """
    }

    private static func toggle(name: String, isOn: Bool) -> String {
        """
        <label class="switch">
          <input type="checkbox" name="\(name)"\(isOn ? " checked" : "")><span></span>
        </label>
        """
    }

    private static func radios(name: String, options: [(String, String)], selected: String) -> String {
        options.map { value, label in
            """
            <label class="radio">
              <input type="radio" name="\(name)" value="\(value)"\(value == selected ? " checked" : "")>
              \(label)
            </label>
            """
        }.joined()
    }

    private static func select(name: String, options: [(String, String)], selected: String) -> String {
        let items = options.map { value, label in
            "<option value=\"\(value)\"\(value == selected ? " selected" : "")>\(label)</option>"
        }.joined()
        return "<select name=\"\(name)\">\(items)</select>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Style

    private static let style = """
    .row {
      display: flex; align-items: center; gap: 24px;
      padding: 16px 0; border-bottom: 1px solid var(--hairline);
    }
    .row:last-of-type { border-bottom: 0; }
    .labels { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
    .title { font-size: 13px; }
    .subtitle { color: var(--muted); font-size: 12px; line-height: 1.5; }
    .control { flex: none; display: flex; align-items: center; gap: 10px; }
    .readout { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums;
               min-width: 46px; text-align: right; }
    /* Un interrupteur dessiné plutôt que celui du système : le contrôle natif d'un
       formulaire web n'a ni la forme ni la couleur du reste de l'application. */
    .switch { position: relative; display: inline-block; width: 40px; height: 24px; }
    .switch input { opacity: 0; width: 0; height: 0; }
    .switch span {
      position: absolute; inset: 0; cursor: pointer; border-radius: 24px;
      background: var(--hairline); transition: background .15s ease;
    }
    .switch span::before {
      content: ""; position: absolute; width: 18px; height: 18px; left: 3px; top: 3px;
      background: #fff; border-radius: 50%; transition: transform .15s ease;
      box-shadow: 0 1px 2px rgba(0,0,0,.3);
    }
    .switch input:checked + span { background: var(--text); }
    .switch input:checked + span::before { transform: translateX(16px); }
    .radio { display: inline-flex; align-items: center; gap: 6px; margin-left: 14px;
             font-size: 13px; cursor: pointer; }
    .radio input { accent-color: var(--text); }
    select, .button {
      height: 32px; padding: 0 12px; background: transparent; color: var(--text);
      border: 1px solid var(--hairline); border-radius: 8px; font: inherit; cursor: pointer;
      text-decoration: none; display: inline-flex; align-items: center;
    }
    select:hover, .button:hover { border-color: var(--muted); }
    .button.danger:hover { background: var(--danger); border-color: var(--danger); color: #fff; }
    input[type=range] { accent-color: var(--text); width: 180px; }
    .row.block { border-bottom: 0; padding-bottom: 4px; }
    .permissions { display: flex; flex-direction: column; gap: 6px; padding-bottom: 16px; }
    .permission { display: flex; align-items: center; gap: 12px; }
    .permission .mono { flex: 1; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                        font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .verdict { font-size: 12px; color: var(--muted); }
    .verdict.no { color: var(--danger); }
    .none { color: var(--muted); font-size: 12px; padding-bottom: 16px; }
    /* Le compte de règles se lit dans la phrase, pas dans une colonne à part : il qualifie
       la liste, il ne se compare pas d'une ligne à l'autre. */
    .readout.inline { min-width: 0; text-align: left; font-variant-numeric: tabular-nums;
                      white-space: nowrap; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiSettings.postMessage(payload);

    document.addEventListener('change', (event) => {
      const field = event.target;
      if (!field.name) return;
      const value = field.type === 'checkbox' ? field.checked
                  : field.type === 'radio' ? field.value : field.value;
      send({ action: 'set', key: field.name, value: String(value) });
    });

    // Le chiffre suit le curseur pendant qu'on le déplace : sans ça on règle à l'aveugle.
    document.addEventListener('input', (event) => {
      const field = event.target;
      if (field.name === 'retention') {
        document.getElementById('retention-value').textContent = field.value + ' j';
      } else if (field.name === 'zoom') {
        document.getElementById('zoom-value').textContent = field.value + ' %';
      }
    });

    document.addEventListener('click', (event) => {
      const button = event.target.closest('[data-action]');
      if (!button) return;
      const row = button.closest('.permission');
      send({ action: button.dataset.action,
             site: row ? row.dataset.site : null,
             host: row ? row.dataset.host : null,
             kind: row ? row.dataset.kind : null });
      if (row) row.remove();
    });
    """
}
