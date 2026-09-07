import Foundation

/// La coquille commune à toutes les pages `wuji://` : un sommaire à gauche, le contenu à
/// droite.
///
/// **Une seule façon de se déplacer.** Avant, chaque page interne était une île — on
/// arrivait sur l'historique par un raccourci, sur les scripts par un menu, sur
/// les réglages par une fenêtre séparée, et rien ne disait qu'il en existait d'autres. Le
/// sommaire les rassemble : ce que l'application sait montrer tient dans une colonne.
///
/// Cette colonne reprend celle du navigateur — même largeur, même fond en retrait, mêmes
/// lignes de 34 points. Deux colonnes de navigation qui ne se ressembleraient pas feraient
/// deux applications.
@MainActor
enum InternalShell {

    /// Une destination du sommaire.
    struct Item {
        let title: String
        let address: String
        let symbol: String
    }

    /// Les sections, groupées comme on les pense : ce qu'on consulte, puis ce qu'on règle.
    static let groups: [(String, [Item])] = [
        ("Navigation", [
            Item(title: "Favoris", address: "wuji://favorites", symbol: "star"),
            Item(title: "Historique", address: "wuji://history", symbol: "clock"),
            Item(title: "Téléchargements", address: "wuji://downloads", symbol: "arrow.down")
        ]),
        ("Modules", [
            Item(title: "Blocage", address: "wuji://blocking", symbol: "shield.lefthalf.filled"),
            Item(title: "Scripts", address: "wuji://scripts", symbol: "curlybraces")
        ]),
        ("Réglages", [
            Item(title: "Fonctions", address: "wuji://settings/features", symbol: "switch.2"),
            Item(title: "Apparence", address: "wuji://settings", symbol: "circle.lefthalf"),
            Item(title: "Confidentialité", address: "wuji://settings/privacy", symbol: "hand.raised"),
            Item(title: "Recherche", address: "wuji://settings/search", symbol: "magnifyingglass"),
            Item(title: "Sites web", address: "wuji://settings/websites", symbol: "globe"),
            Item(title: "Mots de passe", address: "wuji://settings/passwords", symbol: "key"),
            Item(title: "Zoom par site", address: "wuji://settings/zoom",
                 symbol: "plus.magnifyingglass"),
            Item(title: "Autorisations", address: "wuji://settings/permissions",
                 symbol: "hand.raised.square")
        ])
    ]

    /// Enveloppe un contenu dans la coquille. `current` est l'adresse de la page affichée,
    /// pour que le sommaire sache quelle ligne marquer.
    /// `standalone` : la page sans son sommaire.
    ///
    /// **Une fenêtre à part n'a pas de colonne de navigation.** Le journal du blocage a la
    /// sienne ; y afficher les entrées « Favoris », « Historique », « Réglages » inviterait
    /// à une navigation qui n'a pas de sens dans une fenêtre d'une seule page — et qui
    /// remplacerait le journal par autre chose sans moyen d'y revenir.
    static func page(title: String, current: String, body: String, script: String = "",
                     style: String = "", standalone: Bool = false) -> String {
        let nav = groups.map { group, items in
            let rows = items.map { item in
                let isCurrent = item.address == current
                return """
                <a class="entry\(isCurrent ? " current" : "")" href="\(item.address)">\(escape(item.title))</a>
                """
            }.joined()
            // Un `div` et non un `section` : les pages masquent leurs sections vides
            // quand on filtre, et le sommaire disparaissait avec elles. La coquille ne
            // doit rien porter qu'une page puisse viser sans le vouloir.
            return "<div class=\"group\"><h4>\(escape(group))</h4>\(rows)</div>"
        }.joined()

        return """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        \(InternalStyle.meta)
        <title>\(escape(title))</title>
        <style>\(InternalStyle.shared)\(shellStyle)\(style)</style>
        </head>
        <body>
          <div class="frame">
            \(standalone ? "" : "<nav>" + nav + "</nav>")
            <div class="pane">\(body)</div>
          </div>
          <script>\(script)</script>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let shellStyle = """
    body { height: 100vh; overflow: hidden; }
    /* Sans sommaire, le contenu reprend la marge que la colonne portait pour lui. */
    .frame:not(:has(nav)) .pane { padding-left: 32px; }
    .frame { display: flex; height: 100vh; }
    /* Pas de filet entre le sommaire et le contenu : les deux sont sur le même fond, et
       une ligne verticale y dessinerait une frontière qui n'existe pas. C'est l'écart qui
       sépare, comme dans la colonne du navigateur. */
    nav {
      width: 202px; flex: none; padding: 44px 12px 12px; overflow-y: auto;
    }
    nav .group { margin: 0 0 18px; }
    nav h4 {
      margin: 0 0 4px; padding: 0 12px; font-size: 10px; font-weight: 600;
      letter-spacing: 1.2px; text-transform: uppercase; color: var(--muted);
    }
    .entry {
      display: block; height: 34px; line-height: 34px; padding: 0 12px; margin-bottom: 3px;
      border-radius: 8px; color: var(--text); text-decoration: none; font-size: 13px;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .entry:hover { background: var(--hover); }
    .entry.current { background: var(--raised); }
    .pane { flex: 1; overflow-y: auto; padding: 0 0 64px; }
    .pane header { max-width: 720px; margin: 0 auto; padding: 44px 24px 16px; }
    .pane main { max-width: 720px; margin: 0 auto; padding: 0 24px; }
    """
}
