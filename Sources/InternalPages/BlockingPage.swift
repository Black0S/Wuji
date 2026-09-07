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
        /// Ce que chaque liste est en train de faire — « téléchargement », « compilation ».
        ///
        /// **Par liste, et pas un état unique.** Une liste en cours d'installation n'est pas
        /// encore dans les réglages : la page la décochait sous le doigt de celui qui venait
        /// de la cocher, le temps du téléchargement. Elle compte ici comme cochée, parce
        /// qu'elle l'est — c'est la demande qui a été faite.
        var working: [String: String] = [:]
        /// L'échec du dernier essai, s'il y en a eu un. Il porte l'identité de la ligne :
        /// sans elle, la page ne saurait pas à qui rendre sa case.
        var failure: ContentBlocker.Failure?
        /// Le catalogue n'a pas pu être lu : la page le dit et propose de réessayer, au
        /// lieu d'afficher une liste vide qu'on prendrait pour « il n'y a rien ».
        var unreachable: Bool
        /// Les sites où le blocage est suspendu. Ce que vous avez masqué vous-même vit
        /// maintenant sur `wuji://rules` : cocher une liste écrite ailleurs et poser une
        /// règle sur une page qu'on regarde sont deux gestes différents, et le catalogue
        /// enterrait le second.
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
    /// `catalog` : le catalogue a changé de contenu, pas seulement d'état — il vient
    /// d'arriver, ou il a été rechargé. On renvoie alors les familles entières, parce
    /// qu'aucun correctif d'attribut ne sait faire apparaître des lignes qui n'existent pas.
    ///
    /// **Et seulement dans ce cas.** Cent soixante et une lignes pèsent cent kilo-octets ;
    /// les renvoyer à chaque case cochée les ferait traverser le pont une dizaine de fois
    /// pour un état que trois attributs suffisent à corriger.
    static func patch(_ state: State, catalog: Bool = false) -> String {
        var payload: [String: Any] = [
            "tally": tally(state),
            "notice": notice(state),
            "installed": Array(state.installed),
            "outdated": Array(state.outdated),
            "working": state.working,
            "failed": state.failure?.id ?? "",
            "updates": updatable(state).count
        ]
        if catalog { payload["catalog"] = groups(state) }
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // **La réponse est un mot convenu, pas la valeur du correctif.** Une fonction qui
        // ne renvoie rien vaut `undefined`, que WebKit rend comme « rien » — c'est-à-dire
        // exactement comme un crochet absent. Le côté natif en concluait que la page ne
        // savait pas se mettre à jour et la rechargeait : la liste remontait en haut et le
        // filtre s'effaçait à chaque case cochée, précisément ce que ce correctif existe
        // pour éviter. Le repli sur le rechargement demeure, pour le seul cas qu'il vise.
        return """
        window.__wujiBlockingPatch ? (window.__wujiBlockingPatch(\(json)), 'wuji-ok') : 'absent'
        """
    }

    /// Ce qui est en service **et** périmé : ce que « Tout mettre à jour » a à faire.
    static func updatable(_ state: State) -> [RuleList] {
        state.catalog.filter { state.installed.contains($0.id) && state.outdated.contains($0.id) }
    }

    /// Le bandeau ne dit plus que les échecs.
    ///
    /// **Ce qui travaille se dit sur la ligne concernée.** Un bandeau qui apparaît en haut
    /// de la page pousse toute la liste vers le bas, puis la laisse remonter quand il
    /// disparaît : un soubresaut à chaque case cochée, sous le doigt qui vient de cliquer.
    /// La ligne, elle, a déjà sa hauteur — un mot de plus sur son titre ne déplace rien.
    private static func notice(_ state: State) -> String {
        if let failure = state.failure {
            return #"<p class="failure">« "# + escape(failure.name) + " » : "
                + escape(failure.why) + "</p>"
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
        // **Le bouton existe toujours, caché quand il n'a rien à faire.** La page se met à
        // jour sur place : un bouton absent du document ne pourrait pas apparaître quand
        // une nouvelle version l'est.
        let attente = updatable(state).count
        let updateAll = #"<button class="button" id="tout-jour" data-action="update-all""#
            + (attente == 0 ? " hidden" : "")
            + ">Tout mettre à jour" + (attente == 0 ? "" : " (\(attente))") + "</button>"

        return InternalShell.page(
            title: "Blocage", current: "wuji://blocking",
            body: """
              <header>
                <div class="titles">
                  <h1>Blocage</h1>
                  <p>\(tally)</p>
                </div>
                \(updateAll)
                <button class="ghost" data-action="reload">Actualiser</button>
              </header>
              <main>
                <div id="notice">\(notice)</div>
                \(paused(state))
                <div class="search"\(state.catalog.isEmpty ? " hidden" : "")>
                  <input type="search" class="filter" placeholder="Filtrer les listes"
                         autocomplete="off" spellcheck="false">
                  <span class="count"></span>
                </div>
                <div id="catalogue">\(groups(state))</div>
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
        let sections = order.map { group in
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
        return families(order, byGroup) + sections
    }

    /// **Les familles en tête, comme des jetons.** Le filtre par mot-clé suppose qu'on
    /// connaît déjà le nom de ce qu'on cherche ; on vient plus souvent chercher *une
    /// catégorie* — la publicité, le pistage — sans savoir quelle liste la couvre. Les
    /// jetons répondent à cette question-là, et se combinent avec le mot-clé : « Publicité »
    /// puis « adguard » n'est pas la même demande que l'un ou l'autre seul.
    ///
    /// « Toutes » d'abord, et actif par défaut : un jeu de filtres sans état neutre oblige
    /// à deviner comment revenir en arrière.
    private static func families(_ order: [String], _ byGroup: [String: [RuleList]]) -> String {
        guard order.count > 1 else { return "" }
        let total = byGroup.values.reduce(0) { $0 + $1.count }
        let jetons = order.map { group in
            """
            <button class="puce" data-famille="\(escape(group))">\(escape(group))\
            <span>\(byGroup[group]?.count ?? 0)</span></button>
            """
        }.joined()
        return """
        <div class="familles">
          <button class="puce active" data-famille="">Toutes<span>\(total)</span></button>
          \(jetons)
        </div>
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
        let working = state.working[list.id]
        return """
        <li data-id="\(escape(list.id))">
          <input type="checkbox" class="toggle"\(installed || working != nil ? " checked" : "")>
          <div class="body">
            <span class="name">\(escape(list.name))<span class="stale"\(stale ? "" : " hidden") \
        > · à jour disponible</span><span class="work"\(working == nil ? " hidden" : "")> · \
        \(escape(working ?? ""))…</span></span>
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
    /* **Les boutons de l'en-tête ne se compriment pas.** Serrés par le titre, ils
       repliaient leur libellé sur deux lignes et grandissaient l'en-tête ; « Tout mettre à
       jour » disparaissant une fois le travail fait, tout ce qui suivait remontait alors de
       dix-sept points. C'est le titre qui cède la place, et il sait se tronquer. */
    header .button, header .ghost { flex: none; white-space: nowrap; }
    /* **La ligne garde sa hauteur, bouton ou pas.** « Mettre à jour » est le plus haut de
       ses éléments — trente-deux points, bordure comprise — et le cacher faisait remonter
       de vingt-trois points tout ce qui se trouvait dessous : c'est-à-dire au moment précis
       où l'on venait de mettre cette liste à jour, là où l'on regardait. La hauteur
       réservée est celle du bouton plus les marges, pas un nombre choisi à l'œil. */
    li {
      height: auto; min-height: 54px; padding: 10px 12px; align-items: flex-start; gap: 12px;
    }
    /* Le bouton d'une ligne est plus court que la ligne la plus courte : c'est ce qui fait
       qu'apparaître ou disparaître ne change jamais la hauteur du rang. */
    li .update { height: 26px; padding: 0 10px; font-size: 12px; }
    li input[type=checkbox] { margin-top: 3px; }
    li[hidden] { display: none; }
    .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail { color: var(--muted); font-size: 12px;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    input[type=checkbox] { accent-color: var(--text); width: 15px; height: 15px; flex: none; }
    .search { display: flex; align-items: center; gap: 10px; margin: 4px 0 8px; }
    .search[hidden] { display: none; }
    .search input {
      flex: 1; min-width: 0; padding: 7px 10px; font: inherit; font-size: 13px;
      color: var(--text); background: var(--hover); border: 0; border-radius: 8px;
    }
    .search input:focus { outline: 1px solid var(--muted); }
    .search .count { color: var(--muted); font-size: 12px; white-space: nowrap; }
    /* Les familles en jetons : une ligne qui se replie, jamais une barre qui déborde. */
    .familles { display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 14px; }
    .puce {
      display: inline-flex; align-items: baseline; gap: 6px; padding: 5px 11px;
      font: inherit; font-size: 12px; color: var(--muted); background: var(--hover);
      border: 0; border-radius: 999px; cursor: pointer; white-space: nowrap;
    }
    .puce span { font-size: 11px; opacity: .65; }
    .puce:hover { color: var(--text); }
    .puce.active { color: var(--bg, #000); background: var(--text); }
    .puce.active span { opacity: .55; }
    /* Ce qui travaille se dit sur la ligne, en gris, à la suite du nom : aucune hauteur
       n'est ajoutée, donc rien ne se déplace sous le doigt qui vient de cliquer. */
    .work { color: var(--muted); font-weight: 400; }
    .work[hidden] { display: none; }
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
    /* Le compte ne se replie pas : « 4 · 4 en service » passait à la ligne dans une fenêtre
       étroite dès qu'une liste entrait en service, et le titre gagnait une ligne — donc
       tout ce qui suivait descendait, à chaque case cochée. */
    .group h2 .tally, .block h2 .tally {
      color: var(--muted); font-weight: 400; font-size: 12px; white-space: nowrap;
    }
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

    // **Ce que l'utilisateur vient de demander, avant que le natif l'ait fait.**
    // Une liste cochée n'entre dans les réglages qu'une fois téléchargée et compilée —
    // plusieurs secondes. Sans cette mémoire, le premier correctif qui passait entre-temps
    // décochait la case sous le doigt qui venait de la cocher. On garde donc l'intention
    // jusqu'à ce que le natif la rejoigne, ou qu'il annonce qu'il a échoué dessus.
    const attente = new Map();

    const travail = (ligne, texte) => {
      const mention = ligne.querySelector('.work');
      if (!mention) return;
      mention.textContent = texte ? ' · ' + texte + '…' : '';
      mention.hidden = !texte;
    };

    document.addEventListener('change', (event) => {
      if (!event.target.classList.contains('toggle')) return;
      const ligne = event.target.closest('li');
      const id = ligne.dataset.id;
      const voulu = event.target.checked;
      attente.set(id, voulu);
      travail(ligne, voulu ? 'en attente' : '');
      send({ action: voulu ? 'install' : 'remove', id });
    });

    document.addEventListener('click', (event) => {
      const bouton = event.target.closest('[data-action]');
      if (!bouton) return;
      const ligne = bouton.closest('li');
      const règle = bouton.closest('.rule');
      if (bouton.dataset.action === 'update' && ligne) {
        attente.set(ligne.dataset.id, true);
        travail(ligne, 'en attente');
      }
      send({ action: bouton.dataset.action,
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
      const tout = document.getElementById('tout-jour');
      if (tout) {
        tout.hidden = !état.updates;
        if (état.updates) tout.textContent = `Tout mettre à jour (${état.updates})`;
      }

      // Le catalogue n'arrive qu'une fois, et seulement quand il a changé : la page servie
      // avant la fin du téléchargement n'a aucune ligne, et aucun attribut ne sait en créer.
      if (état.catalog !== undefined) {
        const catalogue = document.getElementById('catalogue');
        if (catalogue) catalogue.innerHTML = état.catalog;
        const recherche = document.querySelector('.search');
        if (recherche) recherche.hidden = !document.querySelector('li[data-id]');
        famille = '';
        filtrer();
      }

      const posées = new Set(état.installed);
      const vieilles = new Set(état.outdated);
      for (const ligne of document.querySelectorAll('li[data-id]')) {
        const id = ligne.dataset.id;
        const enCours = état.working[id];
        // Le natif a rejoint l'intention, ou il a échoué dessus : dans les deux cas, la
        // page n'a plus rien à retenir. Sans la seconde condition, une case resterait
        // cochée pour toujours après un téléchargement refusé.
        const réel = posées.has(id) || enCours !== undefined;
        if (attente.get(id) === réel || état.failed === id) attente.delete(id);
        const cible = attente.has(id) ? attente.get(id) : réel;

        const case_ = ligne.querySelector('.toggle');
        // On ne touche à la case que si elle ment : réécrire `checked` à l'identique
        // relancerait l'animation de la coche à chaque rafraîchissement.
        if (case_ && case_.checked !== cible) case_.checked = cible;
        travail(ligne, enCours || (attente.get(id) === true ? 'en attente' : ''));

        const périmée = posées.has(id) && vieilles.has(id);
        const mention = ligne.querySelector('.stale');
        if (mention) mention.hidden = !périmée;
        const bouton = ligne.querySelector('.update');
        if (bouton) bouton.hidden = !périmée;
      }
      // Le compte de chaque famille se relit dans la page : il est écrit dans le titre du
      // groupe, et une case cochée le rendrait faux jusqu'au prochain rechargement.
      for (const groupe of document.querySelectorAll('.group')) {
        const total = groupe.querySelectorAll('li[data-id]').length;
        const actives = [...groupe.querySelectorAll('.toggle')].filter((c) => c.checked).length;
        const compteur = groupe.querySelector('h2 .tally');
        if (compteur) {
          compteur.textContent = total + (actives > 0 ? ` · ${actives} en service` : '');
        }
      }
    };

    // Le filtrage se fait ici : cent soixante et une lignes qu'un aller-retour par message
    // redessinerait à chaque frappe, pour un texte que la page a déjà sous la main.
    const plier = (t) => t.toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '');
    let famille = '';

    const filtrer = () => {
      const champ = document.querySelector('.filter');
      const aiguille = plier(champ ? champ.value.trim() : '');
      const lignes = document.querySelectorAll('li[data-id]');
      let visibles = 0;
      for (const ligne of lignes) {
        // Les deux filtres se combinent : une famille choisie **et** un mot-clé sont deux
        // moitiés d'une même demande, pas deux demandes qui se remplacent.
        const groupe = ligne.closest('.group');
        const sienne = !famille || (groupe && groupe.dataset.group === famille);
        const montrer = sienne && (!aiguille || plier(ligne.textContent || '').includes(aiguille));
        ligne.hidden = !montrer;
        if (montrer) visibles++;
      }
      // Une famille dont plus rien ne ressort disparaît avec son titre : « Par langue · 57 »
      // au-dessus du vide se lit comme un défaut d'affichage.
      for (const groupe of document.querySelectorAll('.group')) {
        groupe.hidden = ![...groupe.querySelectorAll('li')].some((l) => !l.hidden);
      }
      const compteur = document.querySelector('.search .count');
      if (compteur) {
        compteur.textContent = (aiguille || famille) ? `${visibles} sur ${lignes.length}` : '';
      }
    };

    document.addEventListener('input', (event) => {
      if (event.target.classList.contains('filter')) filtrer();
    });

    document.addEventListener('click', (event) => {
      const puce = event.target.closest('.puce');
      if (!puce) return;
      famille = puce.dataset.famille;
      for (const autre of document.querySelectorAll('.puce')) {
        autre.classList.toggle('active', autre === puce);
      }
      filtrer();
    });
    """
}
