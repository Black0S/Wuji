import Foundation

/// La page `wuji://scripts`.
///
/// Même grammaire que les autres pages internes. Ce qu'elle montre en plus : **où** un
/// script s'applique. Un script utilisateur s'exécute avec les pleins pouvoirs sur les
/// pages qu'il vise ; savoir lesquelles est la seule information qui compte avant de
/// l'activer.
@MainActor
enum ScriptsPage {

    static func html(scripts: [UserScript]) -> String {
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
                  <p>\(scripts.count) script\(scripts.count > 1 ? "s" : "") · exécutés sur cette machine</p>
                </div>
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
          <button data-action="remove" title="Supprimer" aria-label="Supprimer">\(cross)</button>
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
      if (!event.target.classList.contains('toggle')) return;
      send({ action: 'enable', id: event.target.closest('li').dataset.id,
             value: event.target.checked });
    });

    document.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-action]');
      if (!button) return;
      const row = button.closest('li');
      send({ action: button.dataset.action, id: row.dataset.id });
      row.remove();
    });
    """
}
