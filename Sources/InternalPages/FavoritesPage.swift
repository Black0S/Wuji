import Foundation

/// La page `wuji://favorites`.
///
/// Même grammaire que l'historique et les téléchargements : un titre, une liste, un champ
/// de recherche. Trois pages internes qui se ressemblent à moitié seraient pires qu'une
/// seule — c'est la raison d'être d'`InternalStyle`.
///
/// **Pas de barre de favoris, pas d'épinglage dans la colonne.** Les onglets ont déjà
/// leurs espaces et leurs dossiers ; une seconde colonne de raccourcis toujours visible
/// serait une deuxième façon de ranger la même chose, et l'épinglage a justement été
/// retiré pour ça.
@MainActor
enum FavoritesPage {

    static func html(items: [Favorite], icons: FaviconStore) -> String {
        let rows = items.map { row($0, icons) }.joined()
        let empty = items.isEmpty ? """
            <p class="empty">Aucun favori.<br>
            <kbd>⌘D</kbd> met de côté la page ouverte, et la liste reste sur cette machine.</p>
            """ : ""

        return InternalShell.page(
            title: "Favoris", current: "wuji://favorites",
            body: """
              <header>
                <div class="titles">
                  <h1>Favoris</h1>
                  <p id="count">\(items.count) page\(items.count > 1 ? "s" : "") · conservées sur cette machine</p>
                </div>
                <input id="q" type="search" placeholder="Rechercher" autocomplete="off" spellcheck="false">
              </header>
              <main><ul>\(rows)</ul>\(empty)
                <p class="empty" id="none" hidden>Aucun résultat.</p>
              </main>
              """,
            script: script, style: style)

    }

    private static func row(_ item: Favorite, _ icons: FaviconStore) -> String {
        let host = item.url.host() ?? ""
        return """
        <li data-id="\(item.id.uuidString)"
            data-search="\(escape((item.title + " " + host).lowercased()))">
          \(InternalStyle.favicon(for: item.url, icons))
          <a href="\(escape(item.url.absoluteString))">\(escape(item.title))</a>
          <span class="host">\(escape(host))</span>
          <button data-action="rename" title="Renommer" aria-label="Renommer">\(pencil)</button>
          <button data-action="delete" title="Retirer des favoris" aria-label="Retirer des favoris">\(cross)</button>
        </li>
        """
    }

    /// Des icônes dessinées, comme sur la page des téléchargements : deux caractères
    /// n'auraient ni la même métrique ni le même poids optique côte à côte.
    private static let pencil = """
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" \
    stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">\
    <path d="M11.2 2.8l2 2L6 12H4v-2z"/></svg>
    """

    private static let cross = """
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" \
    stroke-width="1.5" stroke-linecap="round">\
    <path d="M4.2 4.2l7.6 7.6M11.8 4.2l-7.6 7.6"/></svg>
    """

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
    a {
      flex: 1; min-width: 0; color: inherit; text-decoration: none;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    li:hover a { text-decoration: underline; }
    .host { color: var(--muted); font-size: 12px; max-width: 220px;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    li > button {
      width: 22px; height: 22px; flex: none; padding: 0; border: 0; border-radius: 6px;
      background: transparent; color: var(--muted); cursor: pointer; opacity: 0;
      display: flex; align-items: center; justify-content: center;
    }
    /* Au survol seulement : deux boutons par ligne en permanence, c'est autant de bruit
       sur une liste qu'on parcourt des yeux. */
    li:hover > button { opacity: 1; }
    li > button:hover { background: var(--hover); color: var(--text); }
    li > button[data-action="delete"]:hover { background: var(--danger); color: #fff; }
    kbd {
      font: inherit; border: 1px solid var(--hairline); border-radius: 5px;
      padding: 1px 5px; color: var(--text);
    }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiFavorites.postMessage(payload);

    document.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-action]');
      if (!button) return;
      const row = button.closest('li');
      send({ action: button.dataset.action, id: row.dataset.id });
      // La suppression retire la ligne tout de suite : attendre le rechargement ferait
      // clignoter une liste dont on connaît déjà le résultat. Le compte suit dans la
      // foulée, sinon l'en-tête annonce une page de plus qu'il n'en reste.
      if (button.dataset.action === 'delete') { row.remove(); recount(); }
    });

    const recount = () => {
      const total = document.querySelectorAll('main li').length;
      document.getElementById('count').textContent =
        `${total} page${total > 1 ? 's' : ''} · conservées sur cette machine`;
    };

    // Filtrage dans la page : la liste est déjà là, et une recherche qui attend une
    // réponse ne se sent pas instantanée.
    const field = document.getElementById('q');
    field.addEventListener('input', () => {
      const needle = field.value.trim().toLowerCase();
      let shown = 0;
      document.querySelectorAll('main li').forEach((row) => {
        const match = !needle || row.dataset.search.includes(needle);
        row.hidden = !match;
        if (match) shown++;
      });
      document.getElementById('none').hidden = shown > 0 || !needle;
    });
    field.focus();
    """
}
