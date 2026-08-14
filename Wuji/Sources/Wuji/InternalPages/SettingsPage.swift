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
        case appearance, privacy, search, websites

        static func from(path: String) -> Section {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "privacy":  return .privacy
            case "search":   return .search
            case "websites": return .websites
            default:         return .appearance
            }
        }

        var title: String {
            switch self {
            case .appearance: return "Apparence"
            case .privacy:    return "Confidentialité"
            case .search:     return "Recherche"
            case .websites:   return "Sites web"
            }
        }

        var address: String {
            switch self {
            case .appearance: return "wuji://settings"
            case .privacy:    return "wuji://settings/privacy"
            case .search:     return "wuji://settings/search"
            case .websites:   return "wuji://settings/websites"
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
        var agent: String
        var blockingSummary: String
        /// Les autorisations accordées ou refusées, par site.
        var permissions: [(host: String, kind: String, isAllowed: Bool)]
    }

    static func html(section: Section, state: State) -> String {
        let body: String
        switch section {
        case .appearance: body = appearance(state)
        case .privacy:    body = privacy(state)
        case .search:     body = search(state)
        case .websites:   body = websites(state)
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

    private static func appearance(_ state: State) -> String {
        row(title: "Thème",
            subtitle: "« Auto » suit le réglage du système.",
            control: radios(name: "theme",
                            options: [("light", "Clair"), ("dark", "Sombre"), ("auto", "Auto")],
                            selected: state.theme))
    }

    private static func privacy(_ state: State) -> String {
        row(title: "Bloquer publicités et traceurs",
            subtitle: escape(state.blockingSummary) + ". Les listes viennent d'uBlock Origin et d'AdGuard.",
            control: toggle(name: "blocking", isOn: state.blockingEnabled))
        + row(title: "Listes de filtres",
              subtitle: "Abonnements, sites sans protection et règles à vous.",
              control: #"<a class="button" href="wuji://ad-block">Ouvrir</a>"#)
        + row(title: "Conserver l'historique",
              subtitle: "Au-delà, les pages sont effacées au lancement suivant.",
              control: """
              <input type="range" name="retention" min="7" max="365" value="\(state.retention)">
              <span class="readout" id="retention-value">\(state.retention) j</span>
              """)
        + row(title: "Effacer l'historique",
              subtitle: "\(state.historyCount) page\(state.historyCount > 1 ? "s" : "") enregistrée\(state.historyCount > 1 ? "s" : ""). L'effacement est immédiat et définitif.",
              control: #"<button class="button danger" data-action="clear-history">Effacer</button>"#)
        + row(title: "Autoriser l'inspection Safari",
              subtitle: "Ouvre l'inspecteur web d'Apple sur les pages de Wuji.",
              control: toggle(name: "inspection", isOn: state.inspection))
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
             host: row ? row.dataset.host : null,
             kind: row ? row.dataset.kind : null });
      if (row) row.remove();
    });
    """
}
