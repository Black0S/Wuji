import Foundation

/// La page `wuji://extensions`.
///
/// **Ce qu'elle montre en plus d'une liste : d'où vient chaque extension, et ce qu'elle
/// demande.** Une extension web lit et récrit les pages qu'elle vise ; les hôtes déclarés
/// dans son manifeste sont la seule information qui compte avant de l'activer, et ils sont
/// invisibles partout ailleurs.
///
/// Elle ne propose ni recherche ni installation. Wuji ne distribue rien : il lit ce que
/// l'App Store a posé pour Safari, et ce qu'on lui désigne à la main.
@MainActor
enum ExtensionsPage {

    static func html(entries: [ExtensionHost.Entry]) -> String {
        let rows = entries.map(row).joined()
        let active = entries.filter(\.isEnabled).count
        let tally = "\(entries.count) ajoutée\(entries.count > 1 ? "s" : "")"
            + " · \(active) active\(active > 1 ? "s" : "")"
        let empty = entries.isEmpty ? """
            <p class="empty">Aucune extension ajoutée.<br>
            « Ajouter une extension… » ouvre le sélecteur de fichiers : désignez l'application
            qui la porte, dans <code>/Applications</code>.</p>
            """ : ""

        return InternalShell.page(
            title: "Extensions", current: "wuji://extensions",
            body: """
              <header>
                <div class="titles">
                  <h1>Extensions</h1>
                  <p>\(tally)</p>
                </div>
                <button class="ghost" data-action="add">Ajouter une extension…</button>
              </header>
              <main>
                <ul>\(rows)</ul>\(empty)
                <p class="note">
                  Une extension pour Safari achetée sur l'App Store n'est pas un fichier à
                  installer : c'est une application, posée dans <code>/Applications</code>, qui
                  porte l'extension dans son paquet. C'est cette application qu'on désigne, et
                  Wuji lit l'extension là où elle est — elle suit donc ses mises à jour.
                  <br><br>
                  Wuji ne parcourt pas votre disque. Il proposait autrefois tout ce qu'il
                  trouvait dans <code>/Applications</code> : c'était commode, et cela dressait
                  sans qu'on l'ait demandée la liste de ce qui est installé sur l'ordinateur.
                  On désigne, il regarde ; il ne regarde rien d'autre.
                  <br><br>
                  Activer une extension lui accorde ce que son manifeste demande, affiché sur sa
                  ligne. Ce qu'elle demandera en plus, plus tard, passera par une question.
                  <br><br>
                  La punaise pose l'icône d'une extension chargée dans la barre du haut, avec sa
                  pastille. Un clic droit dessus la retire.
                  <br><br>
                  Une application se découpe souvent en plusieurs extensions — Noir en livre
                  deux pour Safari, « Noir » et « Noir for Web Apps » —, et toutes ne sont pas
                  des extensions <em>web</em> : une extension Safari native est du code compilé,
                  sans <code>manifest.json</code>, que WebKit ne sait pas charger hors de Safari.
                  <strong>La liste ne montre que ce qui s'active.</strong> Les segments hors
                  de portée sont nommés au moment de l'ajout, avec leur raison — c'est là que
                  la question se pose. Une ligne qui ne peut ni s'activer, ni s'épingler, ni
                  rien faire encombrerait le réglage sans rien y ajouter.
                  <br><br>
                  Chaque ligne porte l'icône déclarée par son manifeste : c'est ce qui distingue
                  deux extensions sorties du même paquet. Quand deux d'entre elles portent en
                  plus le même nom, le nom de leur paquet les départage.
                </p>
              </main>
              """,
            script: script, style: style)
    }

    private static func row(_ entry: ExtensionHost.Entry) -> String {
        let version = entry.version.map { " · v" + escape($0) } ?? ""

        // Ce que l'extension demande, une ligne pour les pouvoirs et une pour les hôtes.
        // Rien n'est affiché tant qu'elle n'est pas chargée : le manifeste n'est lu que par
        // WebKit, et inventer une liste avant serait annoncer ce qu'on ne sait pas.
        var scope = ""
        if !entry.hosts.isEmpty {
            let shown = entry.hosts.prefix(4).joined(separator: " · ")
            let more = entry.hosts.count > 4 ? " · +\(entry.hosts.count - 4)" : ""
            scope += #"<span class="detail mono">"# + escape(shown + more) + "</span>"
        }
        if !entry.permissions.isEmpty {
            scope += #"<span class="detail mono">"#
                + escape(entry.permissions.joined(separator: " · ")) + "</span>"
        }

        let failure = entry.failure.map {
            #"<span class="detail failure">"# + escape($0) + "</span>"
        } ?? ""

        // Le retrait vaut pour toutes les lignes : chacune vient de quelque chose qu'on a
        // désigné, donc chacune se retire. Il retire la **source** — l'application jetée de
        // la liste emporte les extensions qu'elle portait, et l'application elle-même reste
        // sur le disque.
        let remove = """
        <button data-action="remove" title="Retirer de la liste" aria-label="Retirer de la liste">\(cross)</button>
        """

        // **La punaise n'apparaît que sur une extension chargée.** Une icône posée dans la
        // barre pour quelque chose qui ne tourne pas serait un bouton mort — et on n'a même
        // pas son icône tant que son paquet n'a pas été lu.
        let pin = entry.isLoaded ? """
        <button class="pin\(entry.isPinned ? " on" : "")" data-action="pin" \
        data-value="\(entry.isPinned ? "false" : "true")" \
        title="\(entry.isPinned ? "Retirer de la barre" : "Épingler dans la barre")" \
        aria-label="\(entry.isPinned ? "Retirer de la barre" : "Épingler dans la barre")">\(pinGlyph)</button>
        """ : ""

        // **L'icône, parce que c'est elle qui distingue deux morceaux du même paquet.**
        // « Noir » et « Noir for Web Apps » sortent de la même application et portent
        // presque le même nom : dans les réglages de Safari, on les reconnaît à l'image et
        // à rien d'autre. Une extension qui n'en déclare pas reçoit son initiale — un cadre
        // vide se lit comme une image qui n'a pas chargé.
        let initial = escape(String(entry.name.prefix(1)).uppercased())
        let icon = entry.icon.map { "<img class=\"icon\" src=\"" + $0 + "\" alt=\"\">" }
            ?? "<span class=\"icon letter\" aria-hidden=\"true\">" + initial + "</span>"

        return """
        <li data-id="\(escape(entry.id))">
          <input type="checkbox" class="toggle"\(entry.isEnabled ? " checked" : "")>
          \(icon)
          <div class="body">
            <span class="name">\(escape(entry.name))\(version)</span>
            <span class="detail">\(escape(entry.summary ?? entry.origin))</span>
            \(entry.summary != nil ? #"<span class="detail">"# + escape(entry.origin) + "</span>" : "")
            \(scope)\(failure)
          </div>
          \(pin)\(remove)
        </li>
        """
    }

    /// Une punaise, dessinée plutôt qu'empruntée : la page est du HTML, elle n'a pas
    /// accès aux symboles du système.
    private static let pinGlyph = """
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" \
    stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">\
    <path d="M9.6 1.8l4.6 4.6-2 .6-.8 2.6-4.9-4.9 2.5-.9z"/><path d="M6.5 9.5L2.4 13.6"/></svg>
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
    header { display: flex; align-items: flex-start; gap: 12px; }
    header .titles { flex: 1; min-width: 0; }
    li { height: auto; padding: 10px 12px; align-items: flex-start; gap: 12px; }
    li input[type=checkbox] { margin-top: 3px; }
    /* L'icône est posée sur un fond neutre : beaucoup d'extensions livrent un PNG
       transparent pensé pour un fond clair, et il disparaît en thème sombre. */
    .icon {
      width: 22px; height: 22px; flex: none; border-radius: 5px; object-fit: contain;
      background: var(--hover); margin-top: 1px;
    }
    .letter {
      display: flex; align-items: center; justify-content: center;
      font-size: 12px; font-weight: 600; color: var(--muted);
    }
    .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail { color: var(--muted); font-size: 12px;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; opacity: .8; }
    .failure { color: var(--danger); white-space: normal; }
    input[type=checkbox] { accent-color: var(--text); width: 15px; height: 15px; flex: none; }
    li > button {
      width: 22px; height: 22px; flex: none; padding: 0; border: 0; border-radius: 6px;
      background: transparent; color: var(--muted); cursor: pointer; opacity: 0;
      display: flex; align-items: center; justify-content: center;
    }
    li:hover > button { opacity: 1; }
    li > button:hover { background: var(--danger); color: #fff; }
    /* Une punaise plantée reste visible sans le survol : c'est un état, pas une action
       qu'on découvre. */
    li > button.pin.on { opacity: 1; color: var(--text); }
    li > button.pin:hover { background: var(--hover); color: var(--text); }
    .note { margin-top: 16px; color: var(--muted); font-size: 12px; line-height: 1.6; }
    .note code { font-size: 11px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    .empty code { font-size: 12px; background: var(--hover); padding: 1px 5px; border-radius: 4px; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiExtensions.postMessage(payload);

    document.addEventListener('change', (event) => {
      if (!event.target.classList.contains('toggle')) return;
      send({ action: 'enable', id: event.target.closest('li').dataset.id,
             value: event.target.checked });
    });

    document.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-action]');
      if (!button) return;
      const row = button.closest('li');
      send({ action: button.dataset.action, id: row ? row.dataset.id : null,
             value: button.dataset.value === 'true' });
    });
    """
}
