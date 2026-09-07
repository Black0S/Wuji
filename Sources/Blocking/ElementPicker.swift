import Foundation
import WebKit

/// Désigner un élément d'une page pour le faire disparaître.
///
/// **Le geste manquait, et rien d'autre ne le remplace.** Une liste bloque ce que quelqu'un
/// d'autre a listé ; il reste toujours l'encart d'un site qu'on est seul à visiter, la
/// bannière qu'aucune liste ne connaît, le bloc qui gêne sans être une publicité. Sans
/// sélecteur, la seule réponse était « installez une extension » — c'est-à-dire donner à un
/// tiers la lecture de toutes les pages pour cacher un `<div>`.
///
/// **Ce qui en sort est une règle WebKit, pas un script.** Le sélecteur choisi devient une
/// règle `css-display-none` compilée avec les autres : elle s'applique dans le moteur, avant
/// que la page ne se dessine, et ne coûte rien à l'exécution. Un masquage posé par un script
/// arriverait après le premier rendu — on verrait l'élément apparaître puis disparaître.
@MainActor
enum ElementPicker {

    static let handler = "wujiPicker"

    /// Masque tout de suite, dans la page qu'on regarde.
    ///
    /// **La règle compilée ne vaut qu'à la navigation suivante.** WebKit applique un
    /// bloqueur de contenu au chargement du document : la règle qu'on vient de poser est
    /// juste, elle est en service, et pourtant l'élément reste à l'écran jusqu'au prochain
    /// rechargement. Demander de recharger pour voir l'effet d'un clic qu'on vient de faire
    /// est le genre de détour qu'on n'accepte d'aucun autre bouton.
    ///
    /// **Ce n'est pas un second mécanisme de blocage.** C'est une feuille de style d'une
    /// ligne, posée sur ce document-ci et qui meurt avec lui ; la règle compilée reste la
    /// seule chose durable, et c'est elle qui vaudra dès la prochaine visite. Rien ne
    /// s'exécute ensuite : une feuille insérée ne coûte pas de script.
    ///
    /// Le sélecteur est encodé en JSON plutôt que concaténé : il vient de la page, et une
    /// apostrophe y suffirait à casser l'expression — ou à y glisser autre chose.
    static func hide(_ selector: String) -> String {
        apply(selector, hiding: true)
    }

    /// Défait le masquage immédiat, pour une règle qu'on retire.
    static func unhide(_ selector: String) -> String {
        apply(selector, hiding: false)
    }

    private static func apply(_ selector: String, hiding: Bool) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [selector]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (() => {
          const sel = \(encoded);
          let feuille = document.getElementById('__wujiMasque');
          if (!feuille) {
            if (!\(hiding)) return 'rien';
            feuille = document.createElement('style');
            feuille.id = '__wujiMasque';
            // Sur `documentElement` et non `head` : une page peut n'en avoir aucun, et la
            // feuille doit survivre à un `head` que la page reconstruit.
            document.documentElement.appendChild(feuille);
          }
          const règle = sel + '{display:none!important}';
          const index = [...feuille.sheet.cssRules].findIndex((r) => r.selectorText === sel);
          if (\(hiding)) {
            if (index < 0) feuille.sheet.insertRule(règle, feuille.sheet.cssRules.length);
          } else if (index >= 0) {
            feuille.sheet.deleteRule(index);
          }
          return 'fait';
        })();
        """
    }

    /// Le survol met en évidence, le clic choisit, `esc` renonce.
    ///
    /// **Le calque ne capte pas la souris.** `pointer-events: none` sur tout ce qu'on
    /// ajoute : sans cela, le rectangle de mise en évidence deviendrait lui-même la cible
    /// sous le curseur, et l'on ne pourrait plus désigner que lui.
    static let script = """
    (() => {
      if (window.__wujiPicker) return 'déjà';

      const cadre = document.createElement('div');
      const étiquette = document.createElement('div');
      const style = 'position:fixed;z-index:2147483647;pointer-events:none;';
      cadre.style.cssText = style
        + 'border:2px solid #4a90d9;background:rgba(74,144,217,.18);border-radius:2px;';
      étiquette.style.cssText = style
        + 'font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:#fff;'
        + 'background:#1c1c1e;padding:3px 7px;border-radius:5px;max-width:60vw;'
        + 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';

      let visé = null;

      // **Un sélecteur court et stable.** Un identifiant suffit quand il est unique ; sinon
      // on remonte les parents en s'appuyant sur les classes, et l'on s'arrête dès que le
      // chemin ne désigne plus qu'un élément. Un chemin complet depuis `body` casserait au
      // premier remaniement de la page.
      const échapper = (v) => (window.CSS && CSS.escape) ? CSS.escape(v) : v;
      const utile = (c) => c && !/^[0-9]/.test(c) && c.length < 40
        && !/^(is-|has-|js-)?(active|open|hover|selected|focus)$/.test(c);

      const morceau = (el) => {
        if (el.id && document.querySelectorAll('#' + échapper(el.id)).length === 1) {
          return '#' + échapper(el.id);
        }
        const classes = [...el.classList].filter(utile).slice(0, 3)
          .map((c) => '.' + échapper(c)).join('');
        return el.tagName.toLowerCase() + classes;
      };

      const sélecteur = (el) => {
        let chemin = morceau(el);
        let parent = el.parentElement;
        let tours = 0;
        while (parent && parent !== document.body && tours < 5) {
          if (document.querySelectorAll(chemin).length === 1) return chemin;
          chemin = morceau(parent) + ' > ' + chemin;
          parent = parent.parentElement;
          tours++;
        }
        return chemin;
      };

      const dessiner = (el) => {
        const r = el.getBoundingClientRect();
        cadre.style.left = r.left + 'px';
        cadre.style.top = r.top + 'px';
        cadre.style.width = r.width + 'px';
        cadre.style.height = r.height + 'px';
        étiquette.textContent = sélecteur(el);
        // L'étiquette passe au-dessus quand il n'y a plus la place en dessous : elle doit
        // rester lisible sur un élément collé au bas de la fenêtre.
        const sousLeCadre = r.bottom + 24 < window.innerHeight;
        étiquette.style.top = (sousLeCadre ? r.bottom + 4 : Math.max(4, r.top - 24)) + 'px';
        étiquette.style.left = Math.max(4, r.left) + 'px';
      };

      const survol = (e) => {
        const el = e.target;
        if (!el || el === document.documentElement || el === document.body) return;
        visé = el;
        dessiner(el);
      };

      const arrêter = (choisi) => {
        document.removeEventListener('mousemove', survol, true);
        document.removeEventListener('click', clic, true);
        document.removeEventListener('keydown', touche, true);
        cadre.remove();
        étiquette.remove();
        window.__wujiPicker = false;
        try {
          window.webkit.messageHandlers.wujiPicker.postMessage(
            choisi ? { selector: choisi, host: location.hostname } : { cancelled: true });
        } catch (_) { /* la vue a été démontée */ }
      };

      const clic = (e) => {
        // En capture, et arrêté net : sans cela le clic partirait aussi au lien qui se
        // trouve dessous, et l'on quitterait la page qu'on est en train de régler.
        e.preventDefault();
        e.stopPropagation();
        arrêter(visé ? sélecteur(visé) : null);
      };

      const touche = (e) => {
        if (e.key === 'Escape') { e.preventDefault(); arrêter(null); }
      };

      document.addEventListener('mousemove', survol, true);
      document.addEventListener('click', clic, true);
      document.addEventListener('keydown', touche, true);
      document.body.append(cadre, étiquette);
      window.__wujiPicker = true;
      return 'ouvert';
    })();
    """
}
