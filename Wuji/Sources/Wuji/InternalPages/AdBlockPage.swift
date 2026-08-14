import Foundation

/// La page `wuji://ad-block`.
///
/// Elle montre ce qui protège réellement : les listes, leur date, ce que chacune a donné
/// après traduction. Un bloqueur qui affiche « Protection active » et rien d'autre demande
/// qu'on lui fasse confiance ; celui-ci montre ses chiffres, y compris ceux qui l'arrangent
/// mal — les règles sans équivalent WebKit et celles écartées faute de place.
@MainActor
enum AdBlockPage {

    static func html(state: String, lists: [FilterList], userRules: [String],
                     exceptions: [String], isBusy: Bool) -> String {
        """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        \(InternalStyle.meta)
        <title>Blocage</title>
        <style>\(InternalStyle.shared)\(style)</style>
        </head>
        <body>
          <header>
            <div class="titles">
              <h1>Blocage</h1>
              <p>\(escape(state))</p>
            </div>
            <button id="update" class="ghost"\(isBusy ? " disabled" : "")>
              \(isBusy ? "En cours…" : "Mettre à jour")
            </button>
          </header>

          <main>
            <section>
              <h2>Listes</h2>
              <ul>\(lists.map(row).joined())</ul>
              <form id="add">
                <input id="url" type="url" placeholder="https://…/liste.txt" spellcheck="false">
                <button type="submit" class="ghost">Ajouter</button>
              </form>
              <p class="note">
                Les listes appartiennent à leurs auteurs — uBlock Origin, EasyList, AdGuard.
                Wuji n'en entretient aucune : une liste maison serait périmée le mois suivant
                et donnerait une fausse impression de protection. Elles ne sont téléchargées
                que sur cette page, jamais en arrière-plan.
              </p>
            </section>

            <section>
              <h2>Sites sans protection</h2>
              \(exceptions.isEmpty
                ? #"<p class="empty small">Aucun. La protection s'éteint site par site depuis l'icône de la barre.</p>"#
                : "<ul>\(exceptions.map(exception).joined())</ul>")
            </section>

            <section>
              <h2>Mes règles</h2>
              \(userRules.isEmpty
                ? #"<p class="empty small">Aucune. « Bloquer un élément » dans le menu de l'icône en écrit une.</p>"#
                : "<ul>\(userRules.map(userRule).joined())</ul>")
              <p class="note">
                Ce sont les seules règles que Wuji garde en propre. Elles passent après les
                listes, donc elles peuvent les corriger. Format Adblock&nbsp;:
                <code>site.com##.selecteur</code> pour masquer,
                <code>@@||site.com^</code> pour laisser passer.
              </p>
            </section>
          </main>
          <script>\(script)</script>
        </body>
        </html>
        """
    }

    private static func row(_ list: FilterList) -> String {
        let detail: String
        if let updated = list.updated {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateFormat = "d MMMM 'à' HH:mm"
            let converted = list.rules > 0
                ? " · \(list.rules) règles sur \(list.lines) lignes"
                : ""
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
    form { display: flex; gap: 8px; margin: 10px 12px 0; }
    input[type=url] {
      flex: 1; height: 32px; padding: 0 12px; background: transparent; color: var(--text);
      border: 1px solid var(--hairline); border-radius: 8px; font: inherit; outline: none;
    }
    input[type=url]:focus { border-color: var(--muted); }
    .note { margin: 12px 12px 0; color: var(--muted); font-size: 12px; line-height: 1.6; }
    .note code { font-size: 11px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    .empty.small { padding: 16px 12px; text-align: left; }
    .ghost:hover { color: var(--text); border-color: var(--muted); }
    .ghost:disabled { opacity: .5; cursor: default; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiAdBlock.postMessage(payload);

    document.getElementById('update').addEventListener('click', (event) => {
      event.target.disabled = true;
      event.target.textContent = 'En cours…';
      send({ action: 'update' });
    });

    document.getElementById('add').addEventListener('submit', (event) => {
      event.preventDefault();
      const field = document.getElementById('url');
      if (!field.value.trim()) return;
      send({ action: 'add', url: field.value.trim() });
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
