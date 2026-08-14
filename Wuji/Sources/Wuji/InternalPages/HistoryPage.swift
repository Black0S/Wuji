import AppKit

/// La page `wuji://history`.
///
/// **Une vraie page, pas un panneau.** L'omnibox répond à « je sais où je vais » ; la page
/// répond à « je cherche quelque chose que j'ai vu ». Ce sont deux gestes différents, et
/// le second demande de la place : des jours, des heures, des titres entiers.
///
/// Le style reprend les tokens du chrome à la lettre — mêmes valeurs, mêmes rayons, mêmes
/// gris. C'est la seule façon qu'une page interne ne se lise pas comme un site étranger
/// ouvert dans l'application.
@MainActor
enum HistoryPage {

    static func html(entries: [HistoryEntry], icons: FaviconStore) -> String {
        let groups = group(entries)
        let rows = groups.map { group in
            let items = group.entries.map { row($0, icons) }.joined()
            return """
            <section>
              <h2>\(escape(group.title))</h2>
              <ul>\(items)</ul>
            </section>
            """
        }.joined()

        let empty = entries.isEmpty ? """
            <p class="empty">Aucune page enregistrée.<br>
            L'historique se remplit à mesure que vous naviguez, et reste sur cette machine.</p>
            """ : ""

        return InternalShell.page(
            title: "Historique", current: "wuji://history",
            body: """
              <header>
                <div class="titles">
                  <h1>Historique</h1>
                  <p id="count">\(entries.count) page\(entries.count > 1 ? "s" : "") · conservées sur cette machine</p>
                </div>
                <input id="q" type="search" placeholder="Rechercher" autocomplete="off" spellcheck="false">
                <button id="clear" class="ghost">Tout effacer</button>
              </header>
              <main>\(rows)\(empty)<p class="empty" id="none" hidden>Aucun résultat.</p></main>
              """,
            script: script, style: style)

    }

    // MARK: - Regroupement

    private struct Group {
        let title: String
        let entries: [HistoryEntry]
    }

    /// Par jour, avec « Aujourd'hui » et « Hier » nommés : une date en chiffres demande un
    /// calcul mental pour dire la même chose.
    private static func group(_ entries: [HistoryEntry]) -> [Group] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM"

        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.lastVisit)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }

        return order.map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Aujourd'hui" }
            else if calendar.isDateInYesterday(day) { title = "Hier" }
            else { title = formatter.string(from: day).capitalized }
            return Group(title: title, entries: buckets[day] ?? [])
        }
    }

    private static func row(_ entry: HistoryEntry, _ icons: FaviconStore) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "fr_FR")
        time.dateFormat = "HH:mm"
        let host = entry.url.host() ?? ""
        return """
        <li data-url="\(escape(entry.url.absoluteString))" data-search="\(escape((entry.title + " " + host).lowercased()))">
          \(InternalStyle.favicon(for: entry.url, icons))
          <a href="\(escape(entry.url.absoluteString))">\(escape(entry.title))</a>
          <span class="host">\(escape(host))</span>
          <span class="time">\(time.string(from: entry.lastVisit))</span>
          <button class="remove" title="Retirer de l'historique">✕</button>
        </li>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Style

    /// Ce qui appartient à cette page seulement — le reste vient d'`InternalStyle`.
    private static let style = """
    a {
      flex: 1; min-width: 0; color: inherit; text-decoration: none;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    li:hover a { text-decoration: underline; }
    .host { color: var(--muted); font-size: 12px; max-width: 220px;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .time { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; }
    .remove {
      width: 20px; height: 20px; padding: 0; border: 0; border-radius: 6px;
      background: transparent; color: var(--muted); cursor: pointer;
      font-size: 11px; line-height: 1; opacity: 0;
    }
    /* La croix n'apparaît qu'au survol : une par ligne en permanence, c'est autant de
       bruit pour une action rare. */
    li:hover .remove { opacity: 1; }
    .remove:hover { background: var(--danger); color: #fff; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiHistory.postMessage(payload);

    document.getElementById('clear').addEventListener('click', () => send({ action: 'clear' }));

    document.addEventListener('click', (event) => {
      const button = event.target.closest('.remove');
      if (!button) return;
      const row = button.closest('li');
      send({ action: 'delete', url: row.dataset.url });
      row.remove();
      // Le compte suit la ligne retirée : sans ça l'en-tête annonce une page de plus
      // qu'il n'en reste, jusqu'au prochain rechargement.
      const total = document.querySelectorAll('main li').length;
      document.getElementById('count').textContent =
        `${total} page${total > 1 ? 's' : ''} · conservées sur cette machine`;
    });

    // Filtrage dans la page plutôt qu'un aller-retour vers l'application : la liste est
    // déjà là, et une recherche qui attend une réponse ne se sent pas instantanée.
    const field = document.getElementById('q');
    field.addEventListener('input', () => {
      const needle = field.value.trim().toLowerCase();
      let shown = 0;
      document.querySelectorAll('main li').forEach((row) => {
        const match = !needle || row.dataset.search.includes(needle);
        row.hidden = !match;
        if (match) shown++;
      });
      document.querySelectorAll('main section').forEach((section) => {
        section.hidden = !section.querySelector('li:not([hidden])');
      });
      document.getElementById('none').hidden = shown > 0 || !needle;
    });
    field.focus();
    """
}
