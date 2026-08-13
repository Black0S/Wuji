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

        return """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <title>Téléchargements</title>
        <style>\(InternalStyle.shared)\(style)</style>
        </head>
        <body>
          <header>
            <div class="titles">
              <h1>Téléchargements</h1>
              <p>\(items.count) fichier\(items.count > 1 ? "s" : "") · cette session</p>
            </div>
            <button id="clear" class="ghost">Effacer la liste</button>
          </header>
          <main><ul>\(rows)</ul>\(empty)</main>
          <script>
            const send = (payload) => window.webkit.messageHandlers.wujiDownloads.postMessage(payload);
            document.getElementById('clear').addEventListener('click', () => send({ action: 'clear' }));
            document.addEventListener('click', (event) => {
              const button = event.target.closest('button[data-action]');
              if (!button) return;
              send({ action: button.dataset.action, id: button.closest('li').dataset.id });
            });
            // La page ne se rafraîchit pas toute seule : l'application la recharge quand
            // l'avancement change. Sans ça, une barre figée laisserait croire à un blocage.
          </script>
        </body>
        </html>
        """
    }

    private static func row(_ item: DownloadItem) -> String {
        let detail: String
        let action: String
        switch item.state {
        case .running:
            detail = "\(size(item.received)) sur \(item.expected > 0 ? size(item.expected) : "?") · en cours"
            action = #"<button data-action="cancel" title="Annuler">✕</button>"#
        case .finished:
            detail = "\(size(item.received)) · terminé"
            action = #"<button data-action="reveal" title="Afficher dans le Finder">⤴</button>"#
        case .failed(let reason):
            detail = "Échec · \(escape(reason))"
            action = #"<button data-action="retry" title="Réessayer">↻</button>"#
        }

        let bar = item.isRunning ? """
            <div class="bar"><i style="width: \(Int(item.fraction * 100))%"></i></div>
            """ : ""

        return """
        <li data-id="\(item.id.uuidString)" class="\(item.isRunning ? "running" : "")">
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
      background: transparent; color: var(--muted); cursor: pointer; font-size: 12px; opacity: 0;
    }
    li:hover > button { opacity: 1; }
    li > button:hover { background: var(--hover); color: var(--text); }
    """
}

/// Le style commun aux pages internes.
///
/// Il existe pour une raison simple : deux pages internes qui divergeraient d'un gris ou
/// d'un rayon donneraient l'impression de deux applications. Les valeurs sont celles des
/// tokens du chrome.
@MainActor
enum InternalStyle {
    static let shared = """
    :root {
      --bg: #FFFFFF; --raised: #F5F5F7; --text: #1D1D1F; --muted: #6E6E73;
      --hairline: rgba(0,0,0,.10); --hover: rgba(0,0,0,.05); --danger: #C7302B;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1C1C1E; --raised: #2C2C2E; --text: #FFFFFF; --muted: #8E8E93;
        --hairline: rgba(255,255,255,.14); --hover: rgba(255,255,255,.07); --danger: #E0554F;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--text);
      font: 13px -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased;
    }
    header {
      display: flex; align-items: center; gap: 12px;
      max-width: 760px; margin: 0 auto; padding: 48px 24px 16px;
    }
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
    main { max-width: 760px; margin: 0 auto; padding: 0 24px 64px; }
    section { margin-top: 24px; }
    h2 {
      margin: 0 0 6px; padding: 0 12px; font-size: 10px; font-weight: 600;
      letter-spacing: 1.2px; text-transform: uppercase; color: var(--muted);
    }
    ul { list-style: none; margin: 0; padding: 0; }
    li { display: flex; align-items: center; gap: 12px; height: 40px; padding: 0 12px; border-radius: 8px; }
    li:hover { background: var(--hover); }
    .empty { color: var(--muted); text-align: center; padding: 64px 0; line-height: 1.6; }
    """
}
