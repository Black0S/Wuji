import Foundation

/// La page `wuji://scripts`.
///
/// Même grammaire que les autres pages internes. Ce qu'elle montre en plus : **où** un
/// script s'applique. Un script utilisateur s'exécute avec les pleins pouvoirs sur les
/// pages qu'il vise ; savoir lesquelles est la seule information qui compte avant de
/// l'activer.
@MainActor
enum ScriptsPage {

    static func html(scripts: [UserScript], isEnabled: Bool) -> String {
        let rows = scripts.map(row).joined()
        let empty = scripts.isEmpty ? """
            <p class="empty">Aucun script.<br>
            Ouvrez une adresse en <code>.user.js</code> pour l'installer, ou collez-la ci-dessous.</p>
            """ : ""

        return InternalShell.page(
            title: "Scripts", current: "wuji://scripts",
            body: """
              <header>
                <div class="titles">
                  <h1>Scripts</h1>
                  <p>\(scripts.count) script\(scripts.count > 1 ? "s" : "") · \(isEnabled ? "exécutés sur cette machine" : "tous éteints")</p>
                </div>
                <!-- **L'interrupteur général est ici et non dans « Fonctions ».** Un réglage
                     rangé loin de ce qu'il commande oblige à traverser l'application pour
                     comprendre pourquoi rien ne s'exécute. -->
                <label class="master">
                  <input type="checkbox" id="master"\(isEnabled ? " checked" : "")>
                  <span>Scripts utilisateur</span>
                </label>
              </header>
              <main>
                <ul>\(rows)</ul>\(empty)
                <form id="add">
                  <input id="url" type="url" placeholder="https://…/quelque-chose.user.js" spellcheck="false">
                  <button type="submit" class="ghost">Installer</button>
                </form>
                <p class="note">
                  Un script utilisateur s'exécute avec les mêmes pouvoirs que la page : il peut
                  tout lire et tout modifier sur les adresses qu'il vise. N'installez que ce dont
                  vous comprenez la provenance.
                  <br><br>
                  Les instructions <code>@grant</code>, <code>@require</code> et
                  <code>@resource</code> ne sont pas gérées — elles supposent une API
                  d'extension que Wuji n'a pas.
                  <br><br>
                  L'interrupteur du haut éteint tout d'un coup : l'icône quitte la barre et plus
                  aucun script ne s'exécute. Ce qui est installé reste installé.
                </p>
              </main>
              """,
            script: script, style: style)

    }

    private static func row(_ item: UserScript) -> String {
        let scope = item.patterns.prefix(3).joined(separator: " · ")
            + (item.patterns.count > 3 ? " …" : "")
        let version = item.version.isEmpty ? "" : " · v\(escape(item.version))"
        return """
        <li data-id="\(item.id.uuidString)">
          <input type="checkbox" class="toggle"\(item.isEnabled ? " checked" : "")>
          <div class="body">
            <span class="name">\(escape(item.name))\(version)</span>
            <span class="detail">\(escape(item.descriptionText))</span>
            <span class="detail mono">\(escape(scope))</span>
          </div>
          \(item.source != nil
            ? #"<button data-action="update" title="Mettre à jour" aria-label="Mettre à jour">"# + arrow + "</button>"
            : "")
          <button data-action="remove" title="Supprimer" aria-label="Supprimer">\(cross)</button>
        </li>
        """
    }

    /// La flèche de mise à jour n'apparaît que sur un script venu d'une adresse : un
    /// script collé à la main n'a nulle part où aller chercher une version plus récente.
    private static let arrow = """
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" \
    stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.8 8a4.8 4.8 0 1 1-1.5-3.5"/><path d="M12.8 2.9v3.3H9.5"/></svg>
    """

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
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; opacity: .8; }
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
    /* L'interrupteur général : dans l'en-tête, à droite du compte, là où l'on regarde
       déjà pour savoir combien de scripts tournent. */
    header { display: flex; align-items: flex-start; gap: 12px; }
    header .titles { flex: 1; min-width: 0; }
    .master { display: flex; align-items: center; gap: 8px; font-size: 13px; cursor: pointer; }
    .master input { accent-color: var(--text); width: 15px; height: 15px; }
    .note { margin-top: 16px; color: var(--muted); font-size: 12px; line-height: 1.6; }
    .note code { font-size: 11px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    .empty code { font-size: 12px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiScripts.postMessage(payload);

    document.getElementById('add').addEventListener('submit', (event) => {
      event.preventDefault();
      const field = document.getElementById('url');
      if (!field.value.trim()) return;
      send({ action: 'install', url: field.value.trim() });
      field.value = '';
    });

    document.addEventListener('change', (event) => {
      if (event.target.id === 'master') {
        return send({ action: 'master', value: event.target.checked });
      }
      if (!event.target.classList.contains('toggle')) return;
      send({ action: 'enable', id: event.target.closest('li').dataset.id,
             value: event.target.checked });
    });

    document.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-action]');
      if (!button) return;
      const row = button.closest('li');
      send({ action: button.dataset.action, id: row.dataset.id });
      // Seule la suppression retire la ligne : une mise à jour la garde, et la page se
      // recharge quand le nouveau script est arrivé.
      if (button.dataset.action === 'remove') row.remove();
    });
    """
}
