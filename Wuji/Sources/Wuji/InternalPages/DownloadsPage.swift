import Foundation

/// La page `wuji://downloads`.
///
/// Même grammaire que l'historique : un titre, une liste, une action de nettoyage. Deux
/// pages internes qui se ressembleraient à moitié seraient pires qu'une seule.
@MainActor
enum DownloadsPage {

    static func html(items: [DownloadItem]) -> String {
        let rows = items.map(row).joined()
        let empty = items.isEmpty ? """
            <p class="empty">Aucun téléchargement.<br>
            Les fichiers vont dans votre dossier Téléchargements, et Wuji n'en garde pas la liste.</p>
            """ : ""

        return InternalShell.page(
            title: "Téléchargements", current: "wuji://downloads",
            body: """
              <header>
                <div class="titles">
                  <h1>Téléchargements</h1>
                  <p>\(items.count) fichier\(items.count > 1 ? "s" : "") · cette session</p>
                </div>
                <button id="clear" class="ghost">Effacer la liste</button>
              </header>
              <main><ul>\(rows)</ul>\(empty)</main>
              """,
            script: script, style: style)

    }

    private static func row(_ item: DownloadItem) -> String {
        let detail: String
        let action: String
        switch item.state {
        case .running:
            detail = "\(size(item.received)) sur \(item.expected > 0 ? size(item.expected) : "?") · en cours"
            action = button("pause", "Mettre en pause") + button("cancel", "Annuler")
        case .paused:
            detail = "\(size(item.received)) sur \(item.expected > 0 ? size(item.expected) : "?") · en pause"
            action = button("resume", "Reprendre") + button("cancel", "Annuler")
        case .finished:
            // Une fois terminé, la taille du fichier sur le disque est la seule qui vaille.
            let onDisk = item.destination.flatMap {
                try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64
            } ?? item.received
            detail = "\(size(onDisk)) · terminé"
            action = button("reveal", "Afficher dans le Finder")
        case .failed(let reason):
            detail = "Échec · \(escape(reason))"
            action = button("retry", "Réessayer")
        }

        let bar = item.isActive ? """
            <div class="bar"><i style="width: \(Int(item.fraction * 100))%"></i></div>
            """ : ""

        return """
        <li data-id="\(item.id.uuidString)" class="\(item.isActive ? "running" : "")">
          <span class="glyph">\(escape(String(item.filename.suffix(4).uppercased().filter(\.isLetter).prefix(3))))</span>
          <div class="body">
            <span class="name">\(escape(item.filename))</span>
            <span class="detail">\(detail)</span>
            \(bar)
          </div>
          \(action)
        </li>
        """
    }

    private static func button(_ action: String, _ title: String) -> String {
        """
        <button data-action="\(action)" title="\(title)" aria-label="\(title)">\(icon(action))</button>
        """
    }

    /// Des icônes dessinées plutôt que des caractères. « ⏸ », « ✕ » et « ▶ » ont chacun
    /// leur métrique et leur taille optique : côte à côte, ils ne s'alignent jamais et
    /// n'ont pas le même poids. Un même gabarit et un même trait règlent les deux.
    private static func icon(_ name: String) -> String {
        let path: String
        switch name {
        case "pause":  path = #"<path d="M6 3.5v9M10 3.5v9"/>"#
        case "resume": path = #"<path d="M5.5 3.6l6.5 4.4-6.5 4.4z"/>"#
        case "cancel": path = #"<path d="M4.2 4.2l7.6 7.6M11.8 4.2l-7.6 7.6"/>"#
        case "retry":  path = #"<path d="M12.8 8a4.8 4.8 0 1 1-1.5-3.5"/><path d="M12.8 2.9v3.3H9.5"/>"#
        default:       path = #"<path d="M6 3.5H3.5v9h9V10"/><path d="M9.2 3.5h3.3v3.3"/><path d="M12.2 3.8L7.4 8.6"/>"#
        }
        return """
        <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor"         stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">\(path)</svg>
        """
    }

    private static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiDownloads.postMessage(payload);
    document.getElementById('clear').addEventListener('click', () => send({ action: 'clear' }));
    document.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-action]');
      if (!button) return;
      send({ action: button.dataset.action, id: button.closest('li').dataset.id });
    });
    // L'application pousse l'avancement ligne par ligne plutôt que de recharger la page :
    // une reconstruction complète à chaque paquet reçu faisait clignoter la liste et
    // remontait le défilement en haut.
    window.wujiProgress = (id, percent, detail) => {
      const row = document.querySelector(`li[data-id="${id}"]`);
      if (!row) return;
      row.querySelector('.detail').textContent = detail;
      const bar = row.querySelector('.bar i');
      if (bar) bar.style.width = percent + '%';
    };
    """

    private static let style = """
    li { height: auto; padding: 12px; align-items: center; }
    .glyph {
      width: 34px; height: 34px; flex: none; border-radius: 8px;
      border: 1px solid var(--hairline); color: var(--muted);
      display: flex; align-items: center; justify-content: center;
      font-size: 9px; font-weight: 600; letter-spacing: .5px;
    }
    .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
    .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail { color: var(--muted); font-size: 12px; }
    /* Une barre fine plutôt qu'un pourcentage : on veut savoir si ça avance, pas combien. */
    .bar { height: 2px; margin-top: 4px; background: var(--hover); border-radius: 2px; overflow: hidden; }
    .bar i { display: block; height: 100%; background: var(--muted); transition: width .2s ease-out; }
    li > button {
      width: 26px; height: 26px; flex: none; border: 0; border-radius: 8px;
      background: transparent; color: var(--muted); cursor: pointer; opacity: 0;
      /* Centrage par le conteneur, pas par la métrique du glyphe : c'est ce qui garantit
         que deux icônes côte à côte tombent sur le même axe. */
      display: flex; align-items: center; justify-content: center; padding: 0;
    }
    li:hover > button { opacity: 1; }
    li > button:hover { background: var(--hover); color: var(--text); }
    /* Les actions d'un téléchargement en cours restent visibles : les chercher au survol
       pendant que la barre avance serait une chasse. */
    li.running > button { opacity: 1; }
    /* Une barre en pause s'arrête franchement, sans transition qui suggérerait qu'elle
       bouge encore. */
    li:not(.running) .bar i { transition: none; }
    """
}

/// Le style commun aux pages internes.
///
/// Il existe pour une raison simple : deux pages internes qui divergeraient d'un gris ou
/// d'un rayon donneraient l'impression de deux applications. Les valeurs sont celles des
/// tokens du chrome.
///
/// **Le fond est celui de la sidebar, pas celui du contenu.** Une page interne n'est pas
/// un site : elle appartient à l'application. Lui donner le blanc du contenu la ferait
/// lire comme une page ouverte dans le navigateur, avec un cadre autour d'elle. Au fond
/// de la sidebar, elle prolonge la fenêtre.
@MainActor
enum InternalStyle {
    /// À placer dans chaque `<head>` : sans elle, WebKit suppose une page claire et rend
    /// les contrôles natifs sur cette base, même quand le reste est sombre.
    static let meta = #"<meta name="color-scheme" content="light dark">"#

    /// L'icône d'une ligne : celle du site si l'application la connaît déjà, un globe
    /// sinon.
    ///
    /// **Elle est intégrée à la page, jamais demandée par elle.** Une page interne qui
    /// pointe cent icônes vers cent domaines tire cent requêtes d'un coup, sans que
    /// personne les ait demandées — et il suffit que l'une ne réponde jamais pour que la
    /// page reste en chargement, barre en travers de l'écran comprise.
    static func favicon(for url: URL, _ icons: FaviconStore) -> String {
        if let uri = icons.dataURI(for: url) {
            return #"<img class="ico" src="\#(uri)" alt="">"#
        }
        // Le repli est dessiné et non masqué : une case vide décale l'œil d'une ligne à
        // l'autre, alors qu'un globe gris tient la colonne.
        return """
        <svg class="ico" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1">\
        <circle cx="8" cy="8" r="5.6"/><path d="M2.4 8h11.2M8 2.4c2.6 3 2.6 8.2 0 11.2\
        M8 2.4C5.4 5.4 5.4 10.6 8 13.6"/></svg>
        """
    }

    static let shared = """
    :root {
      --bg: #F5F5F7; --raised: #FFFFFF; --text: #1D1D1F; --muted: #6E6E73;
      --hairline: rgba(0,0,0,.10); --hover: rgba(0,0,0,.05); --danger: #C7302B;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #141416; --raised: #2C2C2E; --text: #FFFFFF; --muted: #8E8E93;
        --hairline: rgba(255,255,255,.14); --hover: rgba(255,255,255,.07); --danger: #E0554F;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--text);
      font: 13px -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased;
    }
    /* La mise en page — largeurs et marges — appartient à `InternalShell`, et à lui seul.
       Chaque page qui redéfinissait « header » décalait son titre de quelques points par
       rapport à la colonne de gauche : invisible page par page, criant en passant de
       l'une a l'autre. */
    header { display: flex; align-items: center; gap: 12px; }
    .titles { flex: 1; }
    h1 { margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -.4px; }
    header p { margin: 4px 0 0; color: var(--muted); font-size: 12px; }
    input[type=search] {
      appearance: none; width: 200px; height: 32px; padding: 0 12px;
      background: transparent; color: var(--text);
      border: 1px solid var(--hairline); border-radius: 8px; font: inherit; outline: none;
    }
    input[type=search]:focus { border-color: var(--muted); }
    .ghost {
      height: 32px; padding: 0 12px; background: transparent; color: var(--muted);
      border: 1px solid var(--hairline); border-radius: 8px; font: inherit; cursor: pointer;
    }
    .ghost:hover { color: var(--danger); border-color: var(--danger); }
    section { margin-top: 24px; }
    h2 {
      margin: 0 0 6px; padding: 0 12px; font-size: 10px; font-weight: 600;
      letter-spacing: 1.2px; text-transform: uppercase; color: var(--muted);
    }
    ul { list-style: none; margin: 0; padding: 0; }
    li { display: flex; align-items: center; gap: 12px; height: 40px; padding: 0 12px; border-radius: 8px; }
    /* Même gabarit pour l'icône d'un site et pour son repli : sans ça, les titres ne
       s'alignent plus d'une ligne à l'autre. */
    .ico { width: 16px; height: 16px; flex: none; border-radius: 3px; }
    svg.ico { color: var(--muted); }
    li:hover { background: var(--hover); }
    .empty { color: var(--muted); text-align: center; padding: 64px 0; line-height: 1.6; }
    """
}
