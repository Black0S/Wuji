import Foundation

/// Les pages `wuji://ad-block`.
///
/// Trois sujets, trois adresses, une colonne pour passer de l'un à l'autre — la même
/// grammaire que la fenêtre de réglages, en HTML.
///
/// **Il n'y a plus de catalogue à gérer, donc plus rien à cocher.** Les règles arrivent avec
/// l'application, déjà écrites dans le format de WebKit. La page ne demande donc plus de
/// choisir : elle dit ce qui protège, ce qui est exclu, et ce que l'utilisateur a ajouté.
/// Un bloqueur qui affiche « Protection active » et rien d'autre demande qu'on lui fasse
/// confiance ; celui-ci montre ses chiffres, et dit aussi ce qu'il ne fait pas.
@MainActor
enum AdBlockPage {

    enum Section: String {
        case unactive, myRules

        static func from(path: String) -> Section {
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "unactive"
                ? .unactive : .myRules
        }

        var title: String {
            switch self {
            case .unactive: return "Sans Protection"
            case .myRules:  return "Mes Règles"
            }
        }

        var address: String {
            switch self {
            case .unactive: return "wuji://ad-block/unactive"
            case .myRules:  return "wuji://ad-block/my-rules"
            }
        }
    }

    static func html(section: Section, state: String, bundled: Int,
                     userRules: [String], exceptions: [String], isBusy: Bool) -> String {
        let body: String
        switch section {
        case .unactive: body = exceptionsSection(exceptions)
        case .myRules:  body = rulesSection(userRules)
        }

        return InternalShell.page(
            title: section.title, current: section.address,
            body: body, script: script, style: style)

    }

    // MARK: - Sections

    private static func exceptionsSection(_ hosts: [String]) -> String {
        """
        <header>
          <div class="titles">
            <h1>Sans Protection</h1>
            <p>\(hosts.count) site\(hosts.count > 1 ? "s" : "")</p>
          </div>
        </header>
        <main>
        \(hosts.isEmpty
          ? #"<p class="empty">Aucun site exclu.<br>Le bouclier de la barre éteint la protection sur la page ouverte.</p>"#
          : "<ul>\(hosts.map(exception).joined())</ul>")
        <p class="note">
          Un site exclu ne voit plus aucune règle s'appliquer — ni les listes, ni les
          vôtres. C'est fait pour les pages qu'un filtre casse : un lecteur vidéo, une
          banque, un mur de paiement.
        </p>
        </main>
        """
    }

    /// Les règles, **rangées par site**.
    ///
    /// Une liste à plat marche tant qu'il y en a trois. Au trentième, on cherche « qu'est-ce
    /// que j'ai fait sur ce site » et on relit tout. Le site est la seule clé qui réponde à
    /// cette question, et c'est aussi celle sous laquelle on écrit une règle — le sélecteur
    /// d'élément ne produit jamais rien d'autre.
    private static func rulesSection(_ rules: [String]) -> String {
        var bySite: [String: [String]] = [:]
        var loose: [String] = []
        for rule in rules {
            if let site = WebKitRule.site(of: rule) { bySite[site, default: []].append(rule) }
            else { loose.append(rule) }
        }

        let sites = bySite.keys.sorted().map { site -> String in
            let entries = bySite[site] ?? []
            return """
            <section>
              <h3>\(escape(site))<span>\(entries.count)</span></h3>
              <ul>\(entries.map(userRule).joined())</ul>
            </section>
            """
        }.joined()

        // Une règle qui ne vise aucun site en particulier — un domaine bloqué partout —
        // n'a pas de dossier où aller, et la ranger sous un site inventé serait mentir.
        let everywhere = loose.isEmpty ? "" : """
        <section>
          <h3>Partout<span>\(loose.count)</span></h3>
          <ul>\(loose.map(userRule).joined())</ul>
        </section>
        """

        return """
        <header>
          <div class="titles">
            <h1>Mes Règles</h1>
            <p>\(rules.count) règle\(rules.count > 1 ? "s" : "") sur \(bySite.count + (loose.isEmpty ? 0 : 1)) site\(bySite.count > 1 ? "s" : "")</p>
          </div>
        </header>
        <main>
        \(rules.isEmpty
          ? #"<p class="empty">Aucune règle.<br>« Bloquer un élément » dans le menu du bouclier en écrit une, au bon format.</p>"#
          : sites + everywhere)
        <form id="addRule">
          <input id="rule" type="text" placeholder='{"action":{"type":"block"},"trigger":{"url-filter":"…"}}' spellcheck="false">
          <button type="submit" class="ghost">Ajouter</button>
        </form>
        <p class="note">
          Ce sont les seules règles que Wuji garde en propre. Elles s'appliquent en plus des
          règles livrées, et dans le même format qu'elles — celui de WebKit, écrit une fois
          et jamais traduit. « Bloquer un élément » dans le menu du bouclier en rédige une
          pour vous ; la syntaxe est décrite dans
          <code>Blocking/Assets/README.md</code>.
        </p>
        </main>
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

    /// La phrase d'abord, le texte exact ensuite. Une règle reste lisible dans son
    /// fichier ; une liste de règles ne se lit pas en JSON.
    private static func userRule(_ rule: String) -> String {
        """
        <li data-rule="\(escape(rule))">
          <div class="body">
            <span class="name">\(escape(WebKitRule.describe(rule)))</span>
            <span class="detail mono">\(escape(rule))</span>
          </div>
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
