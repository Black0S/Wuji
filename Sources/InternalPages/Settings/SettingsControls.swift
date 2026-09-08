import Foundation

/// Les briques communes aux sections : lignes, interrupteurs, listes, et la feuille de
/// style qui les habille. Rien ici ne connaît un réglage en particulier.
@MainActor
extension SettingsPage {

    // MARK: - Contrôles

    static func row(title: String, subtitle: String, control: String) -> String {
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

    static func toggle(name: String, isOn: Bool) -> String {
        """
        <label class="switch">
          <input type="checkbox" name="\(name)"\(isOn ? " checked" : "")><span></span>
        </label>
        """
    }

    static func radios(name: String, options: [(String, String)], selected: String) -> String {
        options.map { value, label in
            """
            <label class="radio">
              <input type="radio" name="\(name)" value="\(value)"\(value == selected ? " checked" : "")>
              \(label)
            </label>
            """
        }.joined()
    }

    static func select(name: String, options: [(String, String)], selected: String) -> String {
        let items = options.map { value, label in
            "<option value=\"\(value)\"\(value == selected ? " selected" : "")>\(label)</option>"
        }.joined()
        return "<select name=\"\(name)\">\(items)</select>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Style

    static let style = """
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
    /* Les boutons viennent de la feuille commune : ils sont les mêmes ici et ailleurs.
       Le menu déroulant partage leur gabarit, et rien d'autre. */
    select {
      height: 32px; padding: 0 12px; background: transparent; color: var(--text);
      border: 1px solid var(--hairline); border-radius: 8px; font: inherit; cursor: pointer;
      text-decoration: none; display: inline-flex; align-items: center;
    }
    select:hover { border-color: var(--muted); }
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
    /* Le filtre : un champ discret au-dessus de la liste qu'il réduit. Il n'a pas de
       bouton — chercher est immédiat, et une recherche qu'il faut valider fait douter
       qu'elle ait marché. */
    .search { display: flex; align-items: center; gap: 10px; margin: 4px 0 8px; }
    .search input {
      flex: 1; min-width: 0; padding: 7px 10px; font: inherit; font-size: 13px;
      color: var(--text); background: var(--hover); border: 0; border-radius: 8px;
    }
    .search input:focus { outline: 1px solid var(--muted); }
    .search .count { color: var(--muted); font-size: 12px; white-space: nowrap; }
    .permission[hidden] { display: none; }
    .row.block .button + .button { margin-left: 8px; }
    """

    static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiSettings.postMessage(payload);

    document.addEventListener('change', (event) => {
      const field = event.target;
      if (!field.name) return;
      const value = field.type === 'checkbox' ? field.checked
                  : field.type === 'radio' ? field.value : field.value;
      send({ action: 'set', key: field.name, value: String(value) });
    });

    // **Le filtrage se fait ici, sans rien renvoyer à Wuji.** Un aller-retour par message
    // redessinerait toute la liste à chaque frappe — et ferait transiter ce que la page a
    // déjà sous la main. Casse et accents mis de côté : on tape « elodie » pour « élodie ».
    const plier = (texte) => texte.toLowerCase()
      .normalize('NFD').replace(/[\\u0300-\\u036f]/g, '');

    const filtrer = (champ) => {
      const portée = champ.dataset.filter;
      const aiguille = plier(champ.value.trim());
      const liste = document.querySelector(`[data-filterable="${portée}"]`);
      if (!liste) return;
      let visibles = 0;
      for (const ligne of liste.children) {
        if (!ligne.dataset) continue;
        // Le texte de la ligne suffit : hôte, compte, verdict y sont déjà.
        const foin = plier(ligne.textContent || '');
        const montrer = !aiguille || foin.includes(aiguille);
        ligne.hidden = !montrer;
        if (montrer) visibles++;
      }
      const compteur = document.querySelector(`[data-count="${portée}"]`);
      if (compteur) {
        compteur.textContent = aiguille ? `${visibles} sur ${liste.children.length}` : '';
      }
    };

    // Le chiffre suit le curseur pendant qu'on le déplace : sans ça on règle à l'aveugle.
    document.addEventListener('input', (event) => {
      const field = event.target;
      if (field.classList.contains('filter')) { return filtrer(field); }
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
             user: row ? row.dataset.user : null,
             kind: row ? row.dataset.kind : null });
      if (row) row.remove();
    });
    """
}
