import Foundation

/// La page `wuji://blocking/journal`.
///
/// **Elle ne compte pas les requêtes bloquées.** WebKit applique les règles dans son
/// processus réseau et n'en rend aucun compte : mesuré, aucun rappel de blocage n'existe
/// pour une application tierce. Un « 12 483 traqueurs arrêtés cette semaine » serait un
/// nombre inventé — le genre de chiffre qui rassure et qu'on ne peut pas vérifier. Ce
/// journal dit ce que Wuji a **fait**, ce qui est vrai et se recoupe : quelle liste est
/// entrée quand, en combien de temps, avec combien de règles ; quel échec, pour quelle
/// raison ; quel élément masqué, sur quel site, avec quel sélecteur.
///
/// C'est ce qu'on vient lire quand une page se comporte autrement qu'hier.
@MainActor
enum BlockingLogPage {

    static func html(entries: [BlockingLog.Entry], standalone: Bool = true) -> String {
        let failures = entries.filter(\.isFailure).count
        let tally = entries.isEmpty
            ? "rien à signaler"
            : "\(entries.count) entrée\(entries.count > 1 ? "s" : "")"
                + (failures > 0 ? " · \(failures) échec\(failures > 1 ? "s" : "")" : "")

        let rows = entries.isEmpty
            ? #"<p class="empty">Le journal est vide. Il se remplit dès qu'une liste entre en service ou qu'un élément est masqué.</p>"#
            : "<ul>" + entries.map(row).joined() + "</ul>"

        return InternalShell.page(
            title: "Journal du blocage", current: "wuji://blocking/journal",
            body: """
              <header>
                <div class="titles">
                  <h1>Journal du blocage</h1>
                  <p>\(tally)</p>
                </div>
                <button class="ghost danger" data-action="clear-log">Effacer</button>
              </header>
              <main>
                \(entries.isEmpty ? "" : search)
                \(rows)
                <p class="note">
                  <strong>Ce journal ne compte pas les requêtes bloquées.</strong> Les règles
                  sont appliquées par WebKit dans son processus réseau, et il n'en rend aucun
                  compte : aucun rappel de blocage n'existe pour une application tierce —
                  mesuré, pas supposé. Un « 12 483 traqueurs arrêtés » serait un nombre
                  inventé, et c'est exactement ce qu'un journal ne doit pas contenir.
                  <br><br>
                  Ce qu'il contient se recoupe : quelle liste est entrée quand, en combien de
                  temps, avec combien de règles ; quel échec et pour quelle raison ; quel
                  élément masqué, sur quel site, avec quel sélecteur.
                  <br><br>
                  Il reste sur cette machine et n'est envoyé nulle part. Il porte les sites
                  où vous avez posé des règles : c'est une information sur vous.
                  <br><br>
                  Les quatre cents dernières entrées sont gardées. Un journal qui grossit
                  sans fin finit par être le plus gros fichier de l'application, et personne
                  n'y remonte au-delà de quelques centaines de lignes.
                </p>
              </main>
              """,
            script: script, style: style, standalone: standalone)
    }

    private static let search = """
    <div class="search">
      <input type="search" class="filter" placeholder="Filtrer le journal"
             autocomplete="off" spellcheck="false">
      <span class="count"></span>
    </div>
    """

    private static func row(_ entry: BlockingLog.Entry) -> String {
        """
        <li\(entry.isFailure ? #" class="failure""# : "")>
          <span class="when">\(escape(moment(entry.date)))</span>
          <div class="body">
            <span class="name">\(escape(entry.label)) · \(escape(entry.subject))</span>
            \(entry.detail.isEmpty ? "" : #"<span class="detail mono">"# + escape(entry.detail) + "</span>")
          </div>
        </li>
        """
    }

    /// L'heure pour aujourd'hui, la date sinon : on cherche « ce qui vient de se passer »
    /// bien plus souvent que « ce qui s'est passé le 3 ».
    private static func moment(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
    header { display: flex; align-items: flex-start; gap: 12px; }
    header .titles { flex: 1; min-width: 0; }
    li { height: auto; padding: 8px 12px; align-items: flex-start; gap: 12px; }
    li[hidden] { display: none; }
    /* L'heure d'abord, en chasse fixe : c'est la colonne qu'on parcourt du regard, et des
       chiffres de largeurs différentes la rendraient illisible. */
    .when { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px;
            color: var(--muted); flex: none; min-width: 62px; padding-top: 2px; }
    .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail { color: var(--muted); font-size: 12px; overflow: hidden;
              text-overflow: ellipsis; white-space: nowrap; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; }
    li.failure .name { color: var(--danger); }
    .search { display: flex; align-items: center; gap: 10px; margin: 4px 0 8px; }
    .search input {
      flex: 1; min-width: 0; padding: 7px 10px; font: inherit; font-size: 13px;
      color: var(--text); background: var(--hover); border: 0; border-radius: 8px;
    }
    .search input:focus { outline: 1px solid var(--muted); }
    .search .count { color: var(--muted); font-size: 12px; white-space: nowrap; }
    .empty { color: var(--muted); font-size: 13px; }
    .note { margin-top: 16px; color: var(--muted); font-size: 12px; line-height: 1.6; }
    """

    private static let script = """
    const send = (payload) => window.webkit.messageHandlers.wujiBlocking.postMessage(payload);

    document.addEventListener('click', (event) => {
      const button = event.target.closest('[data-action]');
      if (button) send({ action: button.dataset.action });
    });

    const plier = (t) => t.toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g, '');
    document.addEventListener('input', (event) => {
      if (!event.target.classList.contains('filter')) return;
      const aiguille = plier(event.target.value.trim());
      const lignes = document.querySelectorAll('main li');
      let visibles = 0;
      for (const ligne of lignes) {
        const montrer = !aiguille || plier(ligne.textContent || '').includes(aiguille);
        ligne.hidden = !montrer;
        if (montrer) visibles++;
      }
      const compteur = document.querySelector('.search .count');
      if (compteur) compteur.textContent = aiguille ? `${visibles} sur ${lignes.length}` : '';
    });
    """
}
