import Foundation

/// Les pages `wuji://ad-block`.
///
/// Trois sujets, trois adresses, une colonne pour passer de l'un à l'autre — la même
/// grammaire que la fenêtre de réglages, en HTML.
///
/// **Tout ce qui concerne le blocage se cherche sous Blocage.** Les listes livrées, les
/// sites exclus, les règles écrites à la main : trois questions voisines, qu'on se pose en
/// même temps. Les interrupteurs des listes ont d'abord vécu dans Réglages › Fonctions,
/// où six lignes noyaient les trois autres réglages et où personne n'allait les chercher.
/// Seul l'interrupteur général reste là-bas : il commande une fonction de l'application,
/// pas le contenu d'une liste.
///
/// Trois arguments — le résumé d'état, le nombre de règles livrées, la compilation en
/// cours — arrivaient ici sans jamais être affichés ; ils ont été retirés plutôt que
/// branchés sur un affichage inventé pour les justifier. Ce que la page montre maintenant,
/// elle le montre parce qu'on peut agir dessus.
@MainActor
enum AdBlockPage {

    enum Section: String {
        case lists, unactive, myRules

        static func from(path: String) -> Section {
            switch path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "lists":    return .lists
            case "unactive": return .unactive
            default:         return .myRules
            }
        }

        var title: String {
            switch self {
            case .lists:    return "Listes de règles"
            case .unactive: return "Sans Protection"
            case .myRules:  return "Mes Règles"
            }
        }

        var address: String {
            switch self {
            case .lists:    return "wuji://ad-block/lists"
            case .unactive: return "wuji://ad-block/unactive"
            case .myRules:  return "wuji://ad-block/my-rules"
            }
        }
    }

    /// Une liste livrée, telle que la page doit la montrer.
    struct List {
        let id: String
        let name: String
        let summary: String
        let count: Int
        let isOn: Bool
    }

    static func html(section: Section, lists: [List], isBlockingOn: Bool,
                     userRules: [String], exceptions: [String]) -> String {
        let body: String
        switch section {
        case .lists:    body = listsSection(lists, isBlockingOn: isBlockingOn)
        case .unactive: body = exceptionsSection(exceptions)
        case .myRules:  body = rulesSection(userRules)
        }

        return InternalShell.page(
            title: section.title, current: section.address,
            body: body, script: script, style: style + switchStyle)

    }

    // MARK: - Sections

    /// Les listes livrées, une par ligne, avec ce qu'elles pèsent.
    ///
    /// **Chaque liste se compile à part**, donc en éteindre une la retire réellement du
    /// moteur et du disque au lieu de la neutraliser. Le compte de règles est celui du
    /// fichier livré, pas une estimation : c'est ce qui rend le choix vérifiable plutôt
    /// que déclaratif.
    ///
    /// Elles vivaient dans Réglages › Fonctions, entre le navigateur par défaut et la
    /// veille des onglets. Six interrupteurs et six phrases y noyaient les trois autres
    /// réglages, et surtout ils n'y étaient pas cherchés : ce qui concerne le blocage se
    /// cherche sous Blocage, à côté des sites exclus et des règles écrites à la main.
    private static func listsSection(_ lists: [List], isBlockingOn: Bool) -> String {
        let total = lists.filter(\.isOn).reduce(0) { $0 + $1.count }
        let actives = lists.filter(\.isOn).count

        // Le blocage éteint, ces interrupteurs ne piloteraient rien : on le dit au lieu
        // de les afficher allumés. Un contrôle mort est pire qu'un contrôle absent.
        let entête = isBlockingOn
            ? "\(actives) liste\(actives > 1 ? "s" : "") active\(actives > 1 ? "s" : ""), \(total) règles"
            : "Le blocage est éteint"

        return """
        <header>
          <div class="titles">
            <h1>Listes de règles</h1>
            <p>\(entête)</p>
          </div>
        </header>
        <main>
        \(isBlockingOn
          ? "<ul>\(lists.map(listRow).joined())</ul>"
          : #"<p class="empty">Le blocage est éteint dans Réglages › Fonctions.<br>Ces listes ne s'appliquent pas tant qu'il l'est.</p>"#)
        <p class="note">
          Ces listes sont livrées avec l'application, écrites dans le format que WebKit
          compile — rien n'est téléchargé, rien n'est traduit au démarrage. Chacune est
          compilée séparément : éteinte, elle quitte le moteur et le disque plutôt que d'y
          rester neutralisée. Vos règles et vos exceptions par site s'appliquent toujours,
          quelles que soient les listes allumées.
        </p>
        </main>
        """
    }

    private static func listRow(_ list: List) -> String {
        """
        <li data-id="\(escape(list.id))">
          <div class="body">
            <span class="name">\(escape(list.name))<span class="count">\(list.count) règles</span></span>
            <span class="detail">\(escape(list.summary))</span>
          </div>
          <label class="switch">
            <input type="checkbox" class="toggle"\(list.isOn ? " checked" : "")><span></span>
          </label>
        </li>
        """
    }

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

    /// L'interrupteur est le même dessin que dans les réglages : deux formes différentes
    /// pour la même décision feraient deux applications.
    private static let switchStyle = """
    li .detail { white-space: normal; overflow: visible; line-height: 1.5; }
    .count { margin-left: 8px; color: var(--muted); font-size: 11px; font-weight: 400;
             font-variant-numeric: tabular-nums; }
    .switch { position: relative; display: inline-block; width: 40px; height: 24px; flex: none; }
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
