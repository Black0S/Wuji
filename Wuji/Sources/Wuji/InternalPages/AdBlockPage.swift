import Foundation

/// Les pages `wuji://ad-block`.
///
/// Trois sujets, trois adresses, une colonne pour passer de l'un à l'autre — la même
/// grammaire que la fenêtre de réglages, en HTML. Les empiler sur une seule page marchait
/// tant qu'il y avait six listes ; à vingt-trois, les règles de l'utilisateur se retrouvent
/// sous deux écrans de défilement.
///
/// Elles montrent ce qui protège réellement : les listes, leur date, ce que chacune a donné
/// après traduction. Un bloqueur qui affiche « Protection active » et rien d'autre demande
/// qu'on lui fasse confiance ; celui-ci montre ses chiffres, y compris ceux qui l'arrangent
/// mal — les règles sans équivalent WebKit.
@MainActor
enum AdBlockPage {

    enum Section: String {
        case rules, unactive, myRules

        static func from(path: String) -> Section {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "unactive": return .unactive
            case "my-rules": return .myRules
            default:         return .rules
            }
        }

        var title: String {
            switch self {
            case .rules:    return "Ad-Block Règles"
            case .unactive: return "Sans Protection"
            case .myRules:  return "Mes Règles"
            }
        }

        var address: String {
            switch self {
            case .rules:    return "wuji://ad-block"
            case .unactive: return "wuji://ad-block/unactive"
            case .myRules:  return "wuji://ad-block/my-rules"
            }
        }
    }

    static func html(section: Section, state: String, lists: [FilterList],
                     userRules: [String], exceptions: [String], isBusy: Bool) -> String {
        let body: String
        switch section {
        case .rules:    body = listsSection(lists, isBusy: isBusy)
        case .unactive: body = exceptionsSection(exceptions)
        case .myRules:  body = rulesSection(userRules)
        }

        return InternalShell.page(
            title: section.title, current: section.address,
            body: body, script: script, style: style)

    }

    // MARK: - Sections

    private static func listsSection(_ lists: [FilterList], isBusy: Bool) -> String {
        let active = lists.filter(\.isEnabled).count
        return """
        <header>
          <div class="titles">
            <h1>Ad-Block Règles</h1>
            <p>\(active) liste\(active > 1 ? "s" : "") active\(active > 1 ? "s" : "") sur \(lists.count)</p>
          </div>
          <button id="update" class="ghost"\(isBusy ? " disabled" : "")>\(isBusy ? "En cours…" : "Mettre à jour")</button>
        </header>
        \(groups(lists))
        <form id="add">
          <input id="url" type="url" placeholder="https://…/liste.txt" spellcheck="false">
          <button type="submit" class="ghost">Ajouter</button>
        </form>
        <p class="note">
          Les listes appartiennent à leurs auteurs — uBlock Origin, EasyList, AdGuard,
          Peter Lowe. Wuji n'en entretient aucune : une liste maison serait périmée le mois
          suivant et donnerait une fausse impression de protection. Elles ne sont
          téléchargées que depuis cette page, jamais en arrière-plan.
        </p>
        """
    }

    /// Rangées par rayon puis par paquet, comme dans uBlock : soixante-dix listes à la
    /// file ne se lisent pas, et cinq morceaux d'« EasyList – Annoyances » se comprennent
    /// mieux sous leur titre commun qu'éparpillés dans l'ordre alphabétique.
    private static func groups(_ lists: [FilterList]) -> String {
        FilterListStore.groupOrder.compactMap { group -> String? in
            let entries = lists.filter { $0.group == group }
            guard !entries.isEmpty else { return nil }
            let active = entries.filter(\.isEnabled).count

            let loose = entries.filter { $0.parent == nil }
            var seen: Set<String> = []
            let bundles = entries.compactMap(\.parent).filter { seen.insert($0).inserted }

            let body = loose.map(row).joined() + bundles.map { name -> String in
                let children = entries.filter { $0.parent == name }
                let on = children.filter(\.isEnabled).count
                return """
                <li class="bundle"><span class="name">\(escape(name))</span>
                  <span class="detail">\(on)/\(children.count)</span></li>
                <ul class="children">\(children.map(row).joined())</ul>
                """
            }.joined()

            // Les régions sont repliées : trente-huit lignes dont on n'en veut qu'une.
            let collapsed = FilterListStore.collapsedGroups.contains(group)
            let heading = """
            <h3>\(escape(FilterListStore.groupTitle(group)))<span>\(active)/\(entries.count)</span></h3>
            """
            return collapsed
                ? """
                  <section><details><summary>\(heading)</summary><ul>\(body)</ul></details></section>
                  """
                : "<section>\(heading)<ul>\(body)</ul></section>"
        }.joined()
    }

    private static func exceptionsSection(_ hosts: [String]) -> String {
        """
        <header>
          <div class="titles">
            <h1>Sans Protection</h1>
            <p>\(hosts.count) site\(hosts.count > 1 ? "s" : "")</p>
          </div>
        </header>
        \(hosts.isEmpty
          ? #"<p class="empty">Aucun site exclu.<br>Le bouclier de la barre éteint la protection sur la page ouverte.</p>"#
          : "<ul>\(hosts.map(exception).joined())</ul>")
        <p class="note">
          Un site exclu ne voit plus aucune règle s'appliquer — ni les listes, ni les
          vôtres. C'est fait pour les pages qu'un filtre casse : un lecteur vidéo, une
          banque, un mur de paiement.
        </p>
        """
    }

    private static func rulesSection(_ rules: [String]) -> String {
        """
        <header>
          <div class="titles">
            <h1>Mes Règles</h1>
            <p>\(rules.count) règle\(rules.count > 1 ? "s" : "")</p>
          </div>
        </header>
        \(rules.isEmpty
          ? #"<p class="empty">Aucune règle.<br>« Bloquer un élément » dans le menu du bouclier en écrit une.</p>"#
          : "<ul>\(rules.map(userRule).joined())</ul>")
        <form id="addRule">
          <input id="rule" type="text" placeholder="site.com##.selecteur" spellcheck="false">
          <button type="submit" class="ghost">Ajouter</button>
        </form>
        <p class="note">
          Ce sont les seules règles que Wuji garde en propre. Elles s'appliquent en plus des
          listes et sont recopiées dans chaque tranche compilée, donc vos exceptions valent
          partout. Format Adblock&nbsp;: <code>site.com##.selecteur</code> pour masquer,
          <code>@@||site.com^</code> pour laisser passer.
        </p>
        """
    }

    // MARK: - Lignes

    private static func row(_ list: FilterList) -> String {
        let detail: String
        if let updated = list.updated {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateFormat = "d MMMM 'à' HH:mm"
            let converted = list.rules > 0 ? " · \(list.rules) règles sur \(list.lines) lignes" : ""
            detail = "Mise à jour le \(formatter.string(from: updated))\(converted)"
        } else {
            detail = "Jamais téléchargée"
        }

        return """
        <li data-id="\(list.id.uuidString)">
          <input type="checkbox" class="toggle"\(list.isEnabled ? " checked" : "")>
          <div class="body">
            <span class="name">\(escape(list.title))</span>
            <span class="detail">\(escape(detail))</span>
            <span class="detail source">\(escape(list.source.absoluteString))</span>
          </div>
          <button data-action="remove" title="Retirer" aria-label="Retirer">\(cross)</button>
        </li>
        """
    }

    private static func exception(_ host: String) -> String {
        """
        <li data-host="\(escape(host))">
          <span class="mono">\(escape(host))</span>
          <button data-action="unexcept" title="Réactiver la protection">\(cross)</button>
        </li>
        """
    }

    private static func userRule(_ rule: String) -> String {
        """
        <li data-rule="\(escape(rule))">
          <span class="mono">\(escape(rule))</span>
          <button data-action="unrule" title="Supprimer">\(cross)</button>
        </li>
        """
    }

    private static let cross = """
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" \
    stroke-width="1.5" stroke-linecap="round"><path d="M4.2 4.2l7.6 7.6M11.8 4.2l-7.6 7.6"/></svg>
    """

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Style

    /// La colonne de gauche reprend celle du navigateur : même fond en retrait, mêmes
    /// lignes, même sélection. Deux colonnes de navigation qui ne se ressembleraient pas
    /// feraient deux applications.
    private static let style = """
    li { height: auto; padding: 10px 12px; align-items: center; gap: 12px; }
    .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail { color: var(--muted); font-size: 12px;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .source { opacity: .7; }
    .mono { flex: 1; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    input[type=checkbox] { accent-color: var(--text); width: 15px; height: 15px; flex: none; }
    li > button {
      width: 22px; height: 22px; flex: none; padding: 0; border: 0; border-radius: 6px;
      background: transparent; color: var(--muted); cursor: pointer; opacity: 0;
      display: flex; align-items: center; justify-content: center;
    }
    li:hover > button { opacity: 1; }
    li > button:hover { background: var(--danger); color: #fff; }
    form { display: flex; gap: 8px; margin-top: 12px; }
    form input {
      flex: 1; height: 32px; padding: 0 12px; background: transparent; color: var(--text);
      border: 1px solid var(--hairline); border-radius: 8px; font: inherit; outline: none;
    }
    form input:focus { border-color: var(--muted); }
    .note { margin-top: 16px; color: var(--muted); font-size: 12px; line-height: 1.6; }
    .note code { font-size: 11px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    .empty { text-align: left; padding-top: 24px; padding-bottom: 8px; }
    section { margin-top: 20px; }
    h3 {
      display: flex; align-items: baseline; gap: 8px; margin: 0 0 4px; padding: 0 12px;
      font-size: 11px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;
      color: var(--muted);
    }
    h3 span { font-weight: 400; letter-spacing: 0; opacity: .7; }
    /* Le titre d'un paquet n'est pas une liste : pas de case, et un texte en retrait
       pour qu'on lise « ceci contient ce qui suit ». */
    li.bundle { color: var(--muted); padding-top: 14px; gap: 8px; }
    li.bundle:hover { background: transparent; }
    li.bundle .name { font-size: 12px; font-weight: 600; flex: none; }
    .children { padding-left: 20px; }
    summary { cursor: pointer; list-style: none; }
    summary::-webkit-details-marker { display: none; }
    summary h3::after { content: '▸'; margin-left: 2px; opacity: .5; }
    details[open] summary h3::after { content: '▾'; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiAdBlock.postMessage(payload);

    const update = document.getElementById('update');
    if (update) update.addEventListener('click', () => {
      update.disabled = true;
      update.textContent = 'En cours…';
      send({ action: 'update' });
    });

    const add = document.getElementById('add');
    if (add) add.addEventListener('submit', (event) => {
      event.preventDefault();
      const field = document.getElementById('url');
      if (!field.value.trim()) return;
      send({ action: 'add', url: field.value.trim() });
      field.value = '';
    });

    const addRule = document.getElementById('addRule');
    if (addRule) addRule.addEventListener('submit', (event) => {
      event.preventDefault();
      const field = document.getElementById('rule');
      if (!field.value.trim()) return;
      send({ action: 'rule', rule: field.value.trim() });
      field.value = '';
    });

    document.addEventListener('change', (event) => {
      if (!event.target.classList.contains('toggle')) return;
      send({ action: 'enable', id: event.target.closest('li').dataset.id,
             value: event.target.checked });
    });

    document.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-action]');
      if (!button) return;
      const row = button.closest('li');
      send({ action: button.dataset.action, id: row.dataset.id,
             host: row.dataset.host, rule: row.dataset.rule });
      row.remove();
    });
    """
}
