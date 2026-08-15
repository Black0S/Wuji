import Foundation

/// La page d'un onglet vierge, sous `wuji://`.
///
/// **Elle prend le fond de la sidebar, pas celui du contenu.** Quand il n'y a pas de page,
/// il ne doit pas y avoir de zone de contenu : la fenêtre redevient une seule surface, et
/// l'arrondi qui marque la jonction disparaît faute de deux couleurs à séparer. Montrer un
/// rectangle vide d'une autre teinte reviendrait à dessiner le contour d'une chose absente.
///
/// Ce qui reste est le minimum qui dise de quoi il s'agit : l'anneau, le nom, la phrase.
/// Rien à lire, rien à cliquer, rien à ignorer — c'est le seul endroit de l'application où
/// l'identité a le droit de se montrer, précisément parce qu'il n'y a rien d'autre.
enum NewTabPage {

    static var html: String {
        """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <!-- Le titre sert d'étiquette dans la liste des onglets : « Wuji » n'y dirait
             rien, « Nouvel onglet » dit ce que c'est. -->
        <title>Nouvel onglet</title>
        <style>
        :root { --bg: #F5F5F7; --mark: rgba(0,0,0,.28); --text: rgba(0,0,0,.34); }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #141416; --mark: rgba(255,255,255,.30); --text: rgba(255,255,255,.26); }
        }
        html, body { height: 100%; margin: 0; background: var(--bg); }
        body {
          display: flex; flex-direction: column;
          align-items: center; justify-content: center; gap: 22px;
          font: 11px -apple-system, system-ui, sans-serif;
          -webkit-font-smoothing: antialiased;
          /* Aucune sélection possible : ce n'est pas du contenu, c'est un fond. */
          -webkit-user-select: none; cursor: default;
        }
        svg { display: block; }
        circle { fill: none; stroke: var(--mark); stroke-width: 1.25; }
        .name {
          color: var(--text); font-size: 11px; font-weight: 500;
          letter-spacing: .62em; text-indent: .62em;
        }
        .line { color: var(--text); font-size: 10.5px; letter-spacing: .16em; opacity: .72; }
        </style>
        </head>
        <body>
          <svg width="62" height="62" viewBox="0 0 62 62" aria-hidden="true">
            <circle cx="31" cy="31" r="29"/>
          </svg>
          <div>
            <div class="name">WUJI</div>
          </div>
          <div class="line">DESIGNED TO DISAPPEAR</div>
        </body>
        </html>
        """
    }
}
