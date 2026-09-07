import Foundation

/// La page `wuji://blocking`.
///
/// **Elle commence vide, et c'est le propos.** Wuji ne livre aucune liste : cette page dit
/// ce qui existe, pas ce qui est déjà en place. Tant qu'on n'a rien coché, rien n'a été
/// téléchargé et rien n'est bloqué — un navigateur qui arriverait avec ses listes aurait
/// choisi pour vous ce qu'il faut bloquer, et personne ne saurait dire quoi.
@MainActor
enum BlockingPage {

    /// Ce que la page a besoin de savoir. Le catalogue est passé tel quel : la page ne
    /// décide de rien, elle affiche.
    struct State {
        var catalog: [RuleList]
        var installed: Set<String>
        var outdated: Set<String>
        var activeRules: Int
        /// Ce qui est en cours, en français — ou `nil` quand rien ne travaille.
        var busy: String?
        /// L'échec du dernier essai, s'il y en a eu un.
        var failure: String?
        /// Le catalogue n'a pas pu être lu : la page le dit et propose de réessayer, au
        /// lieu d'afficher une liste vide qu'on prendrait pour « il n'y a rien ».
        var unreachable: Bool
        /// Ce que vous avez masqué vous-même, et où le blocage est suspendu.
        var mine: [UserRules.Rule]
        var paused: [String]
    }

    /// Ce que l'en-tête annonce. Extrait parce que la mise à jour sur place le renvoie
    /// aussi : deux formulations du même compte finiraient par diverger.
    static func tally(_ state: State) -> String {
        let active = state.installed.count
        return state.catalog.isEmpty && state.unreachable
            ? "catalogue injoignable"
            : "\(active) liste\(active > 1 ? "s" : "") en service"
                + (state.activeRules > 0 ? " · \(format(state.activeRules)) règles" : "")
    }

    /// Ce que la page reçoit pour se mettre à jour **sans se redessiner**.
    ///
    /// Recharger la page à chaque changement remettait la liste en haut et effaçait le
    /// filtre qu'on venait de taper — deux fois de suite, puisque cocher une liste produit
    /// un état « en cours » puis un état « en service ». Ce n'est pas un détail de confort :
    /// on ne peut pas cocher trois listes trouvées par un mot-clé si chaque clic efface le
    /// mot-clé.
    static func patch(_ state: State) -> String {
        let payload: [String: Any] = [
            "tally": tally(state),
            "notice": notice(state),
            "installed": Array(state.installed),
            "outdated": Array(state.outdated)
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__wujiBlockingPatch && window.__wujiBlockingPatch(\(json))"
    }

    private static func notice(_ state: State) -> String {
        if let busy = state.busy {
            return #"<p class="busy">"# + escape(busy) + "…</p>"
        }
        if let failure = state.failure {
            return #"<p class="failure">"# + escape(failure) + "</p>"
        }
        if state.unreachable {
            return """
            <p class="failure">Le catalogue n'a pas pu être lu. Vérifiez la connexion, puis
            <button class="link" data-action="reload">réessayez</button>.</p>
            """
        }
        return ""
    }

    static func html(state: State) -> String {
        let tally = tally(state)

        let notice = notice(state)

        return InternalShell.page(
            title: "Blocage", current: "wuji://blocking",
            body: """
              <header>
                <div class="titles">
                  <h1>Blocage</h1>
                  <p>\(tally)</p>
                </div>
                <button class="ghost" data-action="reload">Actualiser</button>
              </header>
              <main>
                <div id="notice">\(notice)</div>
                \(personal(state))\(paused(state))
                \(state.catalog.isEmpty ? "" : search)
                \(groups(state))
                <p class="note">
                  Wuji n'embarque aucune liste. Celles-ci viennent de
                  <code>Black0S/Wuji-Rules-List</code>, qui récupère les listes d'origine —
                  AdGuard, EasyList, uBlock, les listes par langue — et les convertit au
                  format de bloqueur de contenu de WebKit. Rien n'est téléchargé tant que
                  vous n'avez rien coché.
                  <br><br>
                  <strong>C'est WebKit qui filtre, pas un script.</strong> Les règles sont
                  compilées en table de décision et appliquées dans le processus réseau :
                  une requête bloquée ne part pas, et la page n'apprend jamais qu'elle a été
                  empêchée. Un bloqueur écrit en JavaScript arrive après coup, coûte un
                  script sur chaque document, et se laisse détecter.
                  <br><br>
                  La compilation d'une grande liste prend quelques secondes, <em>une fois</em> :
                  WebKit garde le résultat sur le disque et le retrouve au lancement suivant.
                  C'est aussi ce qui explique la place occupée — décocher une liste la rend.
                  <br><br>
                  Le pourcentage est la part des règles d'origine que la conversion a su
                  rendre. En dessous de cent, une partie de la syntaxe n'a pas d'équivalent
                  chez WebKit : le masquage cosmétique, surtout, qui demande d'injecter du
                  style dans la page.
                </p>
              </main>
              """,
            script: script, style: style)
    }

    /// **Le catalogue par familles.** Cent soixante et une lignes à plat ne se parcourent
    /// pas : on y cherche une liste dont on connaît le nom, ou l'on renonce. Groupées, on
    /// lit d'abord ce qu'on vient chercher — la publicité, le pistage —, et les cinquante-
    /// sept listes par langue tiennent dans une section qu'on saute d'un regard.
    ///
    /// Les groupes viennent du dépôt, pas d'un classement inventé ici ; leur ordre, si.
    private static func groups(_ state: State) -> String {
        var order: [String] = []
        var byGroup: [String: [RuleList]] = [:]
        for list in state.catalog {
            if byGroup[list.group] == nil { order.append(list.group) }
            byGroup[list.group, default: []].append(list)
        }
        return order.map { group in
            let lists = byGroup[group] ?? []
            let active = lists.filter { state.installed.contains($0.id) }.count
            return """
            <div class="group" data-group="\(escape(group))">
              <h2>\(escape(group))<span class="tally">\(lists.count)\
            \(active > 0 ? " · \(active) en service" : "")</span></h2>
              <ul>\(lists.map { row($0, state) }.joined())</ul>
            </div>
            """
        }.joined()
    }

    /// Les règles posées à la main, là où on les retrouve.
    ///
    /// **Elles étaient invisibles.** Le sélecteur d'éléments les créait, le menu du bouclier
    /// permettait de tout retirer d'un site — mais rien ne montrait ce qu'on avait masqué,
    /// ni où. Une règle qu'on ne peut pas relire est une règle qu'on n'ose plus poser.
    private static func personal(_ state: State) -> String {
        guard !state.mine.isEmpty else { return "" }
        let rows = state.mine
            .sorted { ($0.host, $0.selector) < ($1.host, $1.selector) }
            .map { rule in
                """
                <div class="rule" data-rule="\(escape(rule.id))">
                  <span class="mono host">\(escape(rule.host))</span>
                  <span class="mono selector">\(escape(rule.selector))</span>
                  <button class="button danger" data-action="forget-rule">Oublier</button>
                </div>
                """
            }.joined()
        return """
        <div class="block">
          <h2>Règles personnalisées<span class="tally">\(state.mine.count)</span></h2>
          <p class="hint">Posées avec « Masquer un élément… », depuis le bouclier de la barre.
            Elles ne vont nulle part : ce sont des informations sur vous.</p>
        </div>
        <div class="rules">\(rows)</div>
        """
    }

    /// Les sites où le blocage est suspendu.
    private static func paused(_ state: State) -> String {
        guard !state.paused.isEmpty else { return "" }
        let rows = state.paused.sorted().map { host in
            """
            <div class="rule" data-host="\(escape(host))">
              <span class="mono host">\(escape(host))</span>
              <span class="selector">blocage suspendu</span>
              <button class="button" data-action="resume">Reprendre</button>
            </div>
            """
        }.joined()
        return """
        <div class="block">
          <h2>En pause<span class="tally">\(state.paused.count)</span></h2>
          <p class="hint">Aucune règle n'est posée sur ces sites, y compris les vôtres.</p>
        </div>
        <div class="rules">\(rows)</div>
        """
    }

    private static let search = """
    <div class="search">
      <input type="search" class="filter" placeholder="Filtrer les listes"
             autocomplete="off" spellcheck="false">
      <span class="count"></span>
    </div>
    """

    private static func row(_ list: RuleList, _ state: State) -> String {
        let installed = state.installed.contains(list.id)
        let outdated = state.outdated.contains(list.id)
        let detail = "\(format(list.rules)) règles · \(size(list.bytes))"
            + (list.coverage < 100 ? " · \(Int(list.coverage.rounded())) % converti" : "")
            // Toutes les listes ne se versionnent pas : « · v » tout court se lirait comme
            // une version manquante à afficher, alors qu'il n'y en a simplement pas.
            + (list.version.isEmpty ? "" : " · v\(list.version)")

        // **Le bouton et la mention existent toujours, cachés quand ils ne servent pas.**
        // La page se met à jour sur place — cocher une liste ne la redessine plus —, et
        // patcher un attribut `hidden` est autrement plus sûr que de reconstruire du HTML
        // depuis du JavaScript.
        let stale = outdated && installed
        return """
        <li data-id="\(escape(list.id))">
          <input type="checkbox" class="toggle"\(installed ? " checked" : "")>
          <div class="body">
            <span class="name">\(escape(list.name))<span class="stale"\(stale ? "" : " hidden") \
        > · à jour disponible</span></span>
            <span class="detail">\(escape(detail))</span>
            \(list.summary.isEmpty ? "" : #"<span class="detail">"# + escape(list.summary) + "</span>")
          </div>
          <button class="button update" data-action="update"\(stale ? "" : " hidden")>Mettre à jour</button>
        </li>
        """
    }

    /// Les grands nombres se lisent par groupes de trois, ou ne se lisent pas.
    private static func format(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func size(_ bytes: Int) -> String {
        let mo = Double(bytes) / 1_048_576
        return mo >= 1 ? String(format: "%.1f Mo", mo)
                       : String(format: "%.0f ko", Double(bytes) / 1024)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
    header { display: flex; align-items: flex-start; gap: 12px; }
    header .titles { flex: 1; min-width: 0; }
    li { height: auto; padding: 10px 12px; align-items: flex-start; gap: 12px; }
    li input[type=checkbox] { margin-top: 3px; }
    li[hidden] { display: none; }
    .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail { color: var(--muted); font-size: 12px;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    input[type=checkbox] { accent-color: var(--text); width: 15px; height: 15px; flex: none; }
    .search { display: flex; align-items: center; gap: 10px; margin: 4px 0 8px; }
    .search input {
      flex: 1; min-width: 0; padding: 7px 10px; font: inherit; font-size: 13px;
      color: var(--text); background: var(--hover); border: 0; border-radius: 8px;
    }
    .search input:focus { outline: 1px solid var(--muted); }
    .search .count { color: var(--muted); font-size: 12px; white-space: nowrap; }
    /* Ce qui travaille et ce qui a échoué : deux lignes, jamais deux fenêtres. */
    .busy, .failure { font-size: 13px; margin: 0 0 10px; }
    .busy { color: var(--muted); }
    .failure { color: var(--danger); }
    .link { background: none; border: 0; padding: 0; font: inherit;
            color: var(--text); text-decoration: underline; cursor: pointer; }
    /* Les familles : un titre discret, un compte à droite. Une section se saute d'un
       regard — c'est tout l'intérêt d'en avoir. */
    .group h2, .block h2 {
      display: flex; align-items: baseline; gap: 8px; font-size: 13px; font-weight: 600;
      margin: 22px 0 6px; padding: 0 2px; color: var(--text);
    }
    .group h2 .tally, .block h2 .tally { color: var(--muted); font-weight: 400; font-size: 12px; }
    .block .hint { margin: 0 2px 8px; color: var(--muted); font-size: 12px; line-height: 1.5; }
    /* Le filtre traverse les sections : celles qui n'ont plus rien à montrer disparaissent
       avec leur titre, sinon on lirait « Par langue · 57 » au-dessus du vide. */
    .group[hidden], .rule[hidden] { display: none; }
    .rules { display: flex; flex-direction: column; }
    .rule {
      display: flex; align-items: center; gap: 12px; padding: 7px 12px;
      border-radius: var(--radius, 8px);
    }
    .rule:hover { background: var(--hover); }
    .rule .host { flex: none; min-width: 140px; }
    .rule .selector { flex: 1; min-width: 0; color: var(--muted); font-size: 12px;
                      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
    .note { margin-top: 16px; color: var(--muted); font-size: 12px; line-height: 1.6; }
    .note code { font-size: 11px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiBlocking.postMessage(payload);

    document.addEventListener('change', (event) => {
      if (!event.target.classList.contains('toggle')) return;
      send({ action: event.target.checked ? 'install' : 'remove',
             id: event.target.closest('li').dataset.id });
    });

    document.addEventListener('click', (event) => {
      const button = event.target.closest('[data-action]');
      if (!button) return;
      // Trois porteurs d'identité : une ligne de liste, une règle, un site en pause. On
      // envoie celui qu'on trouve — le nom du champ compte peu, l'action dit ce que c'est.
      const ligne = button.closest('li');
      const règle = button.closest('.rule');
      send({ action: button.dataset.action,
             id: (ligne && ligne.dataset.id) || (règle && (règle.dataset.rule || règle.dataset.host)) || null });
    });

    // **La page se met à jour sur place, elle ne se recharge pas.** Recharger remettait la
    // liste en haut et effaçait le filtre à chaque case cochée. On patche donc ce qui a
    // changé — le compte, le bandeau, l'état de chaque ligne — et rien d'autre ne bouge.
    window.__wujiBlockingPatch = (état) => {
      const compte = document.querySelector('header .titles p');
      if (compte) compte.textContent = état.tally;
      const bandeau = document.getElementById('notice');
      if (bandeau) bandeau.innerHTML = état.notice;

      const posées = new Set(état.installed);
      const vieilles = new Set(état.outdated);
      for (const ligne of document.querySelectorAll('li[data-id]')) {
        const id = ligne.dataset.id;
        const case_ = ligne.querySelector('.toggle');
        // On ne touche à la case que si elle ment : réécrire `checked` à l'identique
        // relancerait l'animation de la coche à chaque rafraîchissement.
        if (case_ && case_.checked !== posées.has(id)) case_.checked = posées.has(id);
        const périmée = posées.has(id) && vieilles.has(id);
        const mention = ligne.querySelector('.stale');
        if (mention) mention.hidden = !périmée;
        const bouton = ligne.querySelector('.update');
        if (bouton) bouton.hidden = !périmée;
      }
    };

    // Le filtrage se fait ici : cent soixante et une lignes qu'un aller-retour par message
    // redessinerait à chaque frappe, pour un texte que la page a déjà sous la main.
    const plier = (t) => t.toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '');
    document.addEventListener('input', (event) => {
      if (!event.target.classList.contains('filter')) return;
      const aiguille = plier(event.target.value.trim());
      const lignes = document.querySelectorAll('li[data-id]');
      let visibles = 0;
      for (const ligne of lignes) {
        const montrer = !aiguille || plier(ligne.textContent || '').includes(aiguille);
        ligne.hidden = !montrer;
        if (montrer) visibles++;
      }
      // Une famille dont plus rien ne ressort disparaît avec son titre : « Par langue · 57 »
      // au-dessus du vide se lit comme un défaut d'affichage.
      for (const groupe of document.querySelectorAll('.group')) {
        groupe.hidden = ![...groupe.querySelectorAll('li')].some((l) => !l.hidden);
      }
      const compteur = document.querySelector('.search .count');
      if (compteur) compteur.textContent = aiguille ? `${visibles} sur ${lignes.length}` : '';
    });
    """
}
