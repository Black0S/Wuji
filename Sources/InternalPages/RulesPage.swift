import Foundation

/// La page `wuji://rules` : ce que vous avez masqué vous-même.
///
/// **Elles étaient enterrées sous le catalogue.** Les règles personnelles vivaient en haut
/// de la page « Blocage », au-dessus de cent soixante et une listes ; on les croisait en
/// cherchant autre chose, et jamais quand on les cherchait. Ce ne sont pourtant pas les
/// mêmes objets : une liste vient d'ailleurs et se coche, une règle vient d'un geste qu'on
/// a fait sur une page précise. Deux natures, deux entrées dans le sommaire.
///
/// **Rangées par site, parce que c'est ainsi qu'on les retrouve.** On ne se souvient pas
/// d'un sélecteur ; on se souvient d'avoir masqué quelque chose sur un site, et l'on vient
/// voir ce qu'on y a fait — ou le défaire quand la page a changé sous la règle.
@MainActor
enum RulesPage {

    /// Ce que la page a besoin de savoir. Rien d'autre : les listes ne la concernent pas.
    struct State {
        var mine: [UserRules.Rule]
    }

    /// Ce que l'en-tête annonce. Extrait parce que la mise à jour sur place le renvoie
    /// aussi : deux formulations du même compte finiraient par diverger.
    static func tally(_ state: State) -> String {
        let count = state.mine.count
        guard count > 0 else { return "aucune règle posée" }
        let sites = Set(state.mine.map(\.host)).count
        return "\(count) élément\(count > 1 ? "s" : "") masqué\(count > 1 ? "s" : "")"
            + " sur \(sites) site\(sites > 1 ? "s" : "")"
    }

    /// Ce que la page reçoit pour se mettre à jour **sans se redessiner**.
    ///
    /// Retirer une règle rechargeait la page, donc remettait la liste en haut et effaçait le
    /// filtre. On remplace le corps de la liste et le compte, et rien d'autre ne bouge — la
    /// position de défilement, en particulier, qui est la seule chose que le rechargement
    /// avait de sûr à détruire.
    ///
    /// La réponse est un mot convenu, pas la valeur d'une fonction : une fonction qui ne
    /// renvoie rien vaut `undefined`, ce que WebKit rend comme « rien », c'est-à-dire
    /// exactement comme un crochet absent. Le côté natif rechargeait alors la page qu'il
    /// venait de mettre à jour.
    static func patch(_ state: State) -> String {
        let payload: [String: Any] = ["tally": tally(state), "body": list(state)]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        window.__wujiRulesPatch ? (window.__wujiRulesPatch(\(json)), 'wuji-ok') : 'absent'
        """
    }

    static func html(state: State) -> String {
        InternalShell.page(
            title: "Mes règles", current: "wuji://rules",
            body: """
              <header>
                <div class="titles">
                  <h1>Mes règles</h1>
                  <p id="tally">\(tally(state))</p>
                </div>
              </header>
              <main>
                <div class="search"\(state.mine.count > 6 ? "" : " hidden")>
                  <input type="search" class="filter" placeholder="Filtrer par site ou sélecteur"
                         autocomplete="off" spellcheck="false">
                  <span class="count"></span>
                </div>
                <div id="liste">\(list(state))</div>
                <p class="note">
                  Une règle se pose depuis le bouclier de la barre, « Masquer un élément… » :
                  on désigne l'encart qui gêne, et il disparaît sur-le-champ.
                  <br><br>
                  <strong>Ce sont des règles WebKit, pas un script.</strong> Chaque sélecteur
                  devient une règle <code>css-display-none</code> compilée avec les listes :
                  le moteur masque avant de dessiner, donc on ne voit jamais l'élément
                  apparaître puis partir. Rien ne s'exécute au chargement des pages.
                  <br><br>
                  <strong>Elles ne vont nulle part.</strong> Écrites dans les réglages de
                  l'application, jamais envoyées, jamais partagées. Ce qu'on ne veut pas voir
                  sur un site qu'on visite est une information sur soi, pas une contribution.
                  <br><br>
                  Une règle vaut pour le site et ses sous-domaines : posée sur
                  <code>exemple.fr</code>, elle vaut aussi sur <code>www.exemple.fr</code>.
                  Elle ne vaut pas ailleurs — un sélecteur juste ici ne désigne rien là-bas.
                </p>
              </main>
              """,
            script: script, style: style)
    }

    /// La liste, par site. Vide, elle explique le geste au lieu de ne rien montrer.
    private static func list(_ state: State) -> String {
        guard !state.mine.isEmpty else {
            return """
            <p class="empty">Rien de masqué pour l'instant. Sur une page qui vous gêne,
            ouvrez le bouclier de la barre d'adresse et choisissez
            « Masquer un élément… ».</p>
            """
        }
        var order: [String] = []
        var byHost: [String: [UserRules.Rule]] = [:]
        for rule in state.mine.sorted(by: { ($0.host, $0.selector) < ($1.host, $1.selector) }) {
            if byHost[rule.host] == nil { order.append(rule.host) }
            byHost[rule.host, default: []].append(rule)
        }
        return order.map { host in
            let rules = byHost[host] ?? []
            let rows = rules.map { rule in
                """
                <div class="rule" data-rule="\(escape(rule.id))">
                  <span class="mono selector">\(escape(rule.selector))</span>
                  <span class="when">\(escape(when(rule.created)))</span>
                  <button class="button danger" data-action="forget-rule">Oublier</button>
                </div>
                """
            }.joined()
            return """
            <div class="group" data-host="\(escape(host))">
              <h2>\(escape(host))<span class="tally">\(rules.count)</span>
                <button class="link" data-action="forget-host">Tout retirer</button></h2>
              <div class="rules">\(rows)</div>
            </div>
            """
        }.joined()
    }

    /// La date d'une règle, à la maille où elle sert : savoir si on l'a posée aujourd'hui ou
    /// il y a trois mois suffit à décider si elle a encore une raison d'être.
    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "'aujourd’hui' HH:mm"
                                                                    : "d MMM yyyy"
        return formatter.string(from: date)
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
    .search { display: flex; align-items: center; gap: 10px; margin: 4px 0 8px; }
    .search[hidden] { display: none; }
    .search input {
      flex: 1; min-width: 0; padding: 7px 10px; font: inherit; font-size: 13px;
      color: var(--text); background: var(--hover); border: 0; border-radius: 8px;
    }
    .search input:focus { outline: 1px solid var(--muted); }
    .search .count { color: var(--muted); font-size: 12px; white-space: nowrap; }
    /* Un site, un titre, ses règles dessous. « Tout retirer » se tient à droite du titre :
       c'est un geste sur le site entier, il n'a rien à faire dans la liste des règles. */
    .group h2 {
      display: flex; align-items: baseline; gap: 8px; font-size: 13px; font-weight: 600;
      margin: 22px 0 6px; padding: 0 2px; color: var(--text);
    }
    .group h2 .tally { color: var(--muted); font-weight: 400; font-size: 12px; }
    .group h2 .link { margin-left: auto; font-size: 12px; }
    .group[hidden], .rule[hidden] { display: none; }
    .link { background: none; border: 0; padding: 0; font: inherit;
            color: var(--muted); text-decoration: underline; cursor: pointer; }
    .link:hover { color: var(--text); }
    .rules { display: flex; flex-direction: column; }
    .rule {
      display: flex; align-items: center; gap: 12px; padding: 7px 12px;
      border-radius: var(--radius, 8px);
    }
    .rule:hover { background: var(--hover); }
    .rule .selector { flex: 1; min-width: 0;
                      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rule .when { flex: none; color: var(--muted); font-size: 12px; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
    .empty { color: var(--muted); font-size: 13px; line-height: 1.6; margin: 10px 2px; }
    .note { margin-top: 22px; color: var(--muted); font-size: 12px; line-height: 1.6; }
    .note code { font-size: 11px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiBlocking.postMessage(payload);

    document.addEventListener('click', (event) => {
      const bouton = event.target.closest('[data-action]');
      if (!bouton) return;
      const règle = bouton.closest('.rule');
      const groupe = bouton.closest('.group');
      send({ action: bouton.dataset.action,
             id: (règle && règle.dataset.rule) || (groupe && groupe.dataset.host) || null });
    });

    // **La page se met à jour sur place, elle ne se recharge pas.** Un rechargement
    // remettait la liste en haut et effaçait le filtre à chaque règle retirée.
    window.__wujiRulesPatch = (état) => {
      const compte = document.getElementById('tally');
      if (compte) compte.textContent = état.tally;
      const liste = document.getElementById('liste');
      if (liste) liste.innerHTML = état.body;
      const recherche = document.querySelector('.search');
      const champ = document.querySelector('.filter');
      // Le filtre n'apparaît qu'au-delà de quelques règles, et se réapplique au corps
      // reconstruit : sinon la règle qu'on vient de retirer emporterait le filtrage avec
      // elle et l'on retrouverait la liste entière sous un champ qui dit le contraire.
      if (recherche) recherche.hidden = document.querySelectorAll('.rule').length <= 6;
      if (champ && champ.value.trim()) filtrer(champ.value);
    };

    const plier = (t) => t.toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '');
    const filtrer = (valeur) => {
      const aiguille = plier(valeur.trim());
      const règles = document.querySelectorAll('.rule');
      let visibles = 0;
      for (const règle of règles) {
        const site = règle.closest('.group');
        const texte = (site ? site.dataset.host + ' ' : '') + (règle.textContent || '');
        const montrer = !aiguille || plier(texte).includes(aiguille);
        règle.hidden = !montrer;
        if (montrer) visibles++;
      }
      // Un site dont plus rien ne ressort disparaît avec son titre : « exemple.fr · 3 »
      // au-dessus du vide se lit comme un défaut d'affichage.
      for (const groupe of document.querySelectorAll('.group')) {
        groupe.hidden = ![...groupe.querySelectorAll('.rule')].some((r) => !r.hidden);
      }
      const compteur = document.querySelector('.search .count');
      if (compteur) compteur.textContent = aiguille ? `${visibles} sur ${règles.length}` : '';
    };

    document.addEventListener('input', (event) => {
      if (event.target.classList.contains('filter')) filtrer(event.target.value);
    });
    """
}
