import Foundation

/// Les sections de la page des réglages — une fonction par entrée de la colonne.
///
/// **Séparées du socle et de la feuille de style**, qui ne changent presque jamais, alors
/// qu'une section bouge à chaque réglage ajouté. Six cents lignes dans un fichier
/// obligeaient à traverser le HTML de la mise en page pour atteindre le libellé qu'on
/// voulait corriger.
@MainActor
extension SettingsPage {

    /// qui ne pilote plus rien — exactement le contrôle mort que le projet s'interdit.
    static func features(_ state: State) -> String {
        // Quand c'est déjà le cas, la ligne le dit au lieu d'offrir un bouton qui ne
        // ferait rien : un contrôle mort est pire qu'un contrôle absent.
        row(title: "Navigateur par défaut",
            subtitle: state.isDefaultBrowser
                ? "Les liens ouverts ailleurs sur ce Mac arrivent dans Wuji."
                : "macOS demandera confirmation — c'est lui qui tranche, pas nous.",
            control: state.isDefaultBrowser
                ? #"<span class="readout">C'est le cas</span>"#
                : #"<button class="button" data-action="make-default">Définir</button>"#)
        + row(title: "Mises à jour",
              subtitle: "Version \(escape(state.version)). La vérification demande la dernière "
                  + "version publiée à GitHub — sans identifiant, et sans dire laquelle vous "
                  + "utilisez : la comparaison se fait ici. Rien n'est téléchargé ni installé "
                  + "tout seul ; on ouvre la page, vous décidez.",
              control: #"<button class="button" data-action="check-updates">Vérifier</button>"#
                  + toggle(name: "updates", isOn: state.checkUpdates))
    }

    static func appearance(_ state: State) -> String {
        row(title: "Thème",
            subtitle: "« Auto » suit le réglage du système.",
            control: radios(name: "theme",
                            options: [("light", "Clair"), ("dark", "Sombre"), ("auto", "Auto")],
                            selected: state.theme))
    }

    static func privacy(_ state: State) -> String {
        row(title: "Conserver l'historique",
              subtitle: "Au-delà, les pages sont effacées au lancement suivant.",
              control: """
              <input type="range" name="retention" min="7" max="365" value="\(state.retention)">
              <span class="readout" id="retention-value">\(state.retention) j</span>
              """)
        + row(title: "Effacer l'historique",
              subtitle: "\(state.historyCount) page\(state.historyCount > 1 ? "s" : "") enregistrée\(state.historyCount > 1 ? "s" : ""). L'effacement est immédiat et définitif.",
              control: #"<button class="button danger" data-action="clear-history">Effacer</button>"#)
        // **Ce qui vous garde connecté n'était effaçable nulle part.** L'historique dit où
        // l'on est allé ; les cookies et le stockage local sont ce que les sites ont laissé
        // pour vous reconnaître. Effacer le premier sans pouvoir effacer le second donnait
        // l'illusion d'un nettoyage.
        + row(title: "Effacer les données de sites",
              subtitle: (state.siteDataCount.map {
                  "\($0) site\($0 > 1 ? "s" : "") ont laissé des cookies ou du stockage local. "
              } ?? "Cookies, stockage local et caches. ")
                  + "Les effacer vous déconnecte partout, y compris des sites où vous "
                  + "restez connecté depuis longtemps.",
              control: #"<button class="button danger" data-action="clear-site-data">Effacer tout</button>"#)
        + siteDataList(state)
    }

    /// **Effacer site par site, et non tout ou rien.**
    ///
    /// Le seul geste possible était le grand ménage : effacer les données d'un site qui se
    /// tient mal obligeait à se déconnecter de tous les autres. On voit donc ici qui a
    /// laissé quelque chose, ce que c'est, et chaque ligne s'efface seule.
    static func siteDataList(_ state: State) -> String {
        guard !state.siteData.isEmpty else { return "" }
        let rows = state.siteData.map { entry in
            """
            <div class="permission" data-host="\(escape(entry.host))">
              <span class="mono">\(escape(entry.host))</span>
              <span class="verdict yes">\(escape(entry.kinds))</span>
              <button class="button danger" data-action="forget-site-data">Effacer</button>
            </div>
            """
        }.joined()

        return """
        <div class="row block">
          <div class="labels">
            <span class="title">Site par site</span>
            <span class="subtitle">Effacer une ligne vous déconnecte de ce site-là, et de
              lui seul. Les autres ne bougent pas.</span>
          </div>
        </div>
        \(search(placeholder: "Filtrer les sites", scope: "sitedata"))
        <div class="permissions" data-filterable="sitedata">\(rows)</div>
        """
    }

    static func search(_ state: State) -> String {
        row(title: "Moteur de recherche",
            subtitle: "Utilisé quand ce que vous tapez n'est pas une adresse.",
            control: select(name: "engine",
                            options: [("duckduckgo", "DuckDuckGo"), ("qwant", "Qwant"),
                                      ("google", "Google"), ("bing", "Bing")],
                            selected: state.searchEngine))
    }

    /// Ce qui vaut pour toutes les pages. Le reste — zoom par site, autorisations,
    /// identifiants — a sa propre section : trois listes empilées sous deux réglages
    /// faisaient une page qu'on parcourait au lieu de la lire.
    static func websites(_ state: State) -> String {
        row(title: "Zoom par défaut",
            subtitle: "Appliqué à toutes les pages.",
            control: """
            <input type="range" name="zoom" min="50" max="200" step="5" value="\(Int(state.pageZoom * 100))">
            <span class="readout" id="zoom-value">\(Int(state.pageZoom * 100)) %</span>
            """)
        + row(title: "Se présenter comme",
              subtitle: "Des sites refusent ce qu'ils ne reconnaissent pas. Le moteur reste "
                  + "WebKit quoi qu'on déclare.",
              control: select(name: "agent",
                              options: [("safari", "Safari"), ("chrome", "Chrome"),
                                        ("firefox", "Firefox")],
                              selected: state.agent))
    }

    /// Le zoom retenu site par site.
    static func zoom(_ state: State) -> String {
        let rows = state.siteZoom.isEmpty
            ? #"<p class="none">Aucun site n'a de zoom qui lui soit propre.</p>"#
            : state.siteZoom.map { entry in
                """
                <div class="permission" data-site="\(escape(entry.site))">
                  <span class="mono">\(escape(entry.site))</span>
                  <span class="verdict yes">\(entry.zoom) %</span>
                  <button class="button" data-action="forget-zoom">Oublier</button>
                </div>
                """
            }.joined()

        return """
        <div class="row block">
          <div class="labels">
            <span class="title">Zoom par site</span>
            <span class="subtitle">⌘+ et ⌘− règlent le site qu'on regarde, et il s'en
              souvient. ⌘0 lui rend le zoom par défaut.</span>
          </div>
        </div>
        \(search(placeholder: "Filtrer les sites", scope: "zoom"))
        <div class="permissions" data-filterable="zoom">\(rows)</div>
        """
    }

    /// Ce que les sites ont demandé, et ce qu'on leur a répondu.
    static func permissions(_ state: State) -> String {
        let rows = state.permissions.isEmpty
            ? #"<p class="none">Aucun site n'a demandé la caméra ou le micro.</p>"#
            : state.permissions.map { entry in
                """
                <div class="permission" data-host="\(escape(entry.host))" data-kind="\(entry.kind)">
                  <span class="mono">\(escape(entry.host))</span>
                  <span class="verdict \(entry.isAllowed ? "yes" : "no")">
                    \(entry.isAllowed ? "autorisé" : "refusé") · \(label(entry.kind))
                  </span>
                  <button class="button" data-action="forget-permission">Oublier</button>
                </div>
                """
            }.joined()

        return """
        <div class="row block">
          <div class="labels">
            <span class="title">Autorisations des sites</span>
            <span class="subtitle">Une réponse est retenue par site. L'oublier, c'est
              redemander à la prochaine visite — jamais autoriser en silence.</span>
          </div>
        </div>
        \(search(placeholder: "Filtrer les sites", scope: "permissions"))
        <div class="permissions" data-filterable="permissions">\(rows)</div>
        """
    }

    /// Le coffre, et ce qu'il contient.
    static func passwords(_ state: State) -> String {
        let logins = state.logins.isEmpty
            ? #"<p class="none">Aucun identifiant enregistré.</p>"#
            : state.logins.map { entry in
                """
                <div class="permission" data-host="\(escape(entry.host))" data-user="\(escape(entry.user))">
                  <span class="mono">\(escape(entry.host))</span>
                  <span class="verdict yes">\(escape(entry.user))</span>
                  <button class="button" data-action="copy-password">Copier</button>
                  <button class="button danger" data-action="forget-password">Oublier</button>
                </div>
                """
            }.joined()

        // L'état du coffre commande tout le reste de la page : sans lui, les boutons
        // « Importer » et « Exporter » ouvriraient un sélecteur de fichiers pour rien.
        let vault: String
        if !state.vaultExists {
            vault = row(title: "Coffre",
                        subtitle: "Wuji garde ses identifiants dans son propre coffre, chiffré "
                            + "avec un mot de passe maître — AES-256-GCM, clé dérivée par "
                            + "PBKDF2-HMAC-SHA512. Rien ne va dans le trousseau de macOS, et "
                            + "le mot de passe maître n'est écrit nulle part. "
                            + "<strong>Il n'y a pas de récupération</strong> : oublié, le "
                            + "coffre est perdu.",
                        control: #"<button class="button" data-action="unlock-vault">Créer le coffre</button>"#)
        } else if !state.vaultUnlocked {
            vault = row(title: "Coffre verrouillé",
                        subtitle: "Les identifiants sont chiffrés sur le disque. Rien n'est "
                            + "proposé ni rempli tant qu'il est fermé.",
                        control: #"<button class="button" data-action="unlock-vault">Déverrouiller</button>"#)
        } else {
            vault = row(title: "Coffre ouvert",
                        subtitle: "\(state.logins.count) identifiant"
                            + "\(state.logins.count > 1 ? "s" : "") chiffré"
                            + "\(state.logins.count > 1 ? "s" : "") dans "
                            + "<code>coffre.json</code>. La clé vit en mémoire et disparaît "
                            + "au verrouillage.",
                        control: #"<button class="button" data-action="lock-vault">Verrouiller</button>"#
                            + #"<button class="button" data-action="change-master">Changer le mot de passe maître</button>"#)
        }

        // L'ouverture par empreinte n'a de sens qu'avec un coffre : proposée avant, elle
        // serait un interrupteur qui ne commande rien.
        let biometry = state.vaultExists && state.biometryAvailable
            ? row(title: "Déverrouiller avec \(escape(state.biometryName))",
                  subtitle: "Le mot de passe maître reste valable — c'est un raccourci, pas "
                      + "un remplacement. Ce qui est confié au système, c'est la clé du "
                      + "coffre : trente-deux octets, gardés par l'Enclave sécurisée. Aucun "
                      + "identifiant, aucun mot de passe de site n'y va, et seuls ils "
                      + "n'ouvrent rien sans <code>coffre.json</code>. Ajouter ou retirer une "
                      + "empreinte au Mac invalide la clé : le coffre redemande alors le mot "
                      + "de passe maître."
                      + (state.biometryEnabled && !state.biometrySealed
                         ? " <strong>Protection logicielle sur cette version.</strong> "
                           + "L'empreinte est bien vérifiée par le système, mais la clé n'y "
                           + "est pas liée : un élément à contrôle biométrique demande un "
                           + "droit que seule une signature Developer ID porte, et cette "
                           + "copie est signée ad-hoc. La clé dort alors dans un fichier de "
                           + "Wuji, lisible par votre seul compte — <strong>pas dans le "
                           + "trousseau du Mac</strong>, qui redemandait son mot de passe à "
                           + "chaque déverrouillage parce que la signature d'une copie "
                           + "compilée change à chaque compilation. La version publiée "
                           + "utilise l'Enclave et ne demande rien."
                         : "")
                      + (state.biometryLeftover
                         ? " <strong>Un ancien élément reste dans votre trousseau</strong>, "
                           + "sous « Wuji — clé du coffre » : Wuji n'y lit plus, et ne peut "
                           + "pas l'effacer — le trousseau refuse la suppression à une "
                           + "signature qu'il ne reconnaît plus. Il s'enlève depuis "
                           + "« Trousseaux d'accès »."
                         : ""),
                  control: toggle(name: "biometry", isOn: state.biometryEnabled))
            : ""

        return vault + biometry
            + row(title: "Proposer et remplir",
                  subtitle: "Éteint, plus rien n'est proposé ni rempli — ce qui est dans le "
                      + "coffre y reste.",
                  control: toggle(name: "passwords", isOn: state.passwordsEnabled))
            + """
            <div class="row block">
              <div class="labels">
                <span class="title">Importer, exporter</span>
                <span class="subtitle">Wuji ne peut pas lire l'app <strong>Mots de passe</strong>
                  de macOS : ses identifiants vivent dans le trousseau iCloud, sous des groupes
                  d'accès qui appartiennent à Apple — aucun navigateur tiers n'y entre, pas plus
                  Chrome ou Firefox que Wuji. La porte que le système ouvre est l'export : dans
                  l'app Mots de passe, <em>Fichier ▸ Exporter tous les mots de passe…</em>, puis
                  « Importer » ici. Les deux fichiers, celui qu'on lit et celui qu'on écrit, sont
                  <strong>en clair</strong> : supprimez-les après.</span>
              </div>
              <button class="button" data-action="import-passwords">Importer…</button>
              <button class="button" data-action="export-passwords">Exporter…</button>
            </div>
            <div class="row block">
              <div class="labels">
                <span class="title">Identifiants enregistrés</span>
                <span class="subtitle">Le mot de passe n'est pas affiché ici. « Copier » le prend
                  dans le coffre et le met dans le presse-papiers, sans passer par cette
                  page.</span>
              </div>
            </div>
            \(search(placeholder: "Filtrer par site ou par compte", scope: "logins"))
            <div class="permissions" data-filterable="logins">\(logins)</div>
            """
            + (state.vaultExists ? """
            <div class="row block">
              <div class="labels">
                <span class="title">Supprimer le coffre</span>
                <span class="subtitle">Tous les identifiants disparaissent, définitivement.
                  Exportez-les d'abord si vous les voulez.</span>
              </div>
              <button class="button danger" data-action="destroy-vault">Supprimer</button>
            </div>
            """ : "")
    }

    /// Un champ de filtrage au-dessus d'une liste.
    ///
    /// **Il filtre dans la page, sans rien renvoyer à Wuji.** Une recherche qui ferait un
    /// aller-retour redessinerait la liste à chaque frappe — et ferait transiter par un
    /// message ce que la page a déjà sous la main.
    static func search(placeholder: String, scope: String) -> String {
        """
        <div class="search">
          <input type="search" class="filter" data-filter="\(scope)"
                 placeholder="\(escape(placeholder))" autocomplete="off" spellcheck="false">
          <span class="count" data-count="\(scope)"></span>
        </div>
        """
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case "camera":     return "caméra"
        case "microphone": return "micro"
        case "location":   return "position"
        default:           return "caméra et micro"
        }
    }
}
