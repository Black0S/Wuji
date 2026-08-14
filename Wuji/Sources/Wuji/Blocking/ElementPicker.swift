import WebKit

/// Le sélecteur d'élément : on désigne ce qui gêne, Wuji en écrit la règle.
///
/// **C'est la seule façon honnête de laisser quelqu'un écrire une règle.** L'alternative
/// serait un champ de texte au format Adblock : il faut alors ouvrir l'inspecteur, lire un
/// arbre DOM et deviner un sélecteur stable. Ici on survole, on clique, et la règle qui
/// part dans « Mes règles » est lisible — on peut la relire et la corriger.
///
/// Le sélecteur produit vise le plus court qui soit encore spécifique : un identifiant s'il
/// y en a un, sinon les classes qui ne ressemblent pas à du code généré, sinon la place
/// dans le parent. Un sélecteur trop précis casse à la prochaine mise en page du site ;
/// trop large, il fait disparaître autre chose.
@MainActor
enum ElementPicker {

    static let handler = "wujiPicker"

    /// Injecté à la demande, pas au chargement : c'est un mode qu'on active, et une page
    /// normale n'a rien à porter tant qu'on ne l'a pas demandé.
    static let script = """
    (() => {
      if (window.__wujiPicker) return;

      const overlay = document.createElement('div');
      overlay.style.cssText = `position:fixed;z-index:2147483647;pointer-events:none;
        border:2px solid #0a84ff;background:rgba(10,132,255,.12);border-radius:2px;
        transition:all .05s linear;display:none`;
      const label = document.createElement('div');
      label.style.cssText = `position:fixed;z-index:2147483647;pointer-events:none;
        background:#0a84ff;color:#fff;font:12px -apple-system,system-ui,sans-serif;
        padding:3px 7px;border-radius:6px;display:none;max-width:60vw;overflow:hidden;
        text-overflow:ellipsis;white-space:nowrap`;
      const banner = document.createElement('div');
      banner.textContent = 'Cliquez l\\u2019élément à masquer · Échap pour annuler';
      banner.style.cssText = `position:fixed;z-index:2147483647;top:16px;left:50%;
        transform:translateX(-50%);background:rgba(0,0,0,.82);color:#fff;
        font:13px -apple-system,system-ui,sans-serif;padding:8px 14px;border-radius:10px;
        pointer-events:none`;
      document.documentElement.append(overlay, label, banner);

      let current = null;

      // Une classe qui ressemble à « css-1x7fyq3 » vient d'un outil de compilation : elle
      // change au prochain déploiement du site, donc une règle fondée dessus ne durera pas.
      const generated = (name) => /^[a-z]+[-_]?[0-9a-f]{4,}$/i.test(name) || /\\d{4,}/.test(name);

      // Un morceau de sélecteur pour un élément : le plus parlant qu'il porte.
      const partFor = (node) => {
        const tag = node.tagName.toLowerCase();
        if (node.id && !generated(node.id)) return '#' + CSS.escape(node.id);
        const classes = [...node.classList].filter((name) => !generated(name));
        if (classes.length) return tag + classes.map((name) => '.' + CSS.escape(name)).join('');
        const parent = node.parentElement;
        const index = parent ? [...parent.children].indexOf(node) + 1 : 1;
        return tag + `:nth-child(${index})`;
      };

      // On remonte jusqu'à ce que le sélecteur ne désigne plus qu'un élément.
      //
      // S'arrêter au premier morceau donnait des règles comme « a:nth-child(1) » : vrai
      // pour l'élément visé, et pour deux cents autres de la page. Une règle écrite en un
      // clic doit masquer ce qu'on a montré, pas ce qui lui ressemble.
      const selectorFor = (node) => {
        const parts = [];
        let current = node;
        for (let depth = 0; current && depth < 5; depth++) {
          const part = partFor(current);
          parts.unshift(part);
          if (part.startsWith('#')) break;
          if (document.querySelectorAll(parts.join(' > ')).length === 1) break;
          current = current.parentElement;
        }
        return parts.join(' > ');
      };

      const move = (event) => {
        const node = event.target;
        if (!node || node === document.documentElement || node === document.body) return;
        current = node;
        const box = node.getBoundingClientRect();
        overlay.style.display = 'block';
        overlay.style.left = box.left + 'px';
        overlay.style.top = box.top + 'px';
        overlay.style.width = box.width + 'px';
        overlay.style.height = box.height + 'px';
        label.style.display = 'block';
        label.textContent = selectorFor(node);
        label.style.left = box.left + 'px';
        label.style.top = (box.top > 26 ? box.top - 24 : box.bottom + 4) + 'px';
      };

      const stop = () => {
        document.removeEventListener('mousemove', move, true);
        document.removeEventListener('click', pick, true);
        document.removeEventListener('keydown', key, true);
        overlay.remove(); label.remove(); banner.remove();
        window.__wujiPicker = false;
      };

      const pick = (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (current) {
          window.webkit.messageHandlers.wujiPicker.postMessage({ selector: selectorFor(current) });
        }
        stop();
      };

      const key = (event) => {
        if (event.key !== 'Escape') return;
        event.preventDefault();
        stop();
      };

      window.__wujiPicker = true;
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', pick, true);
      document.addEventListener('keydown', key, true);
    })();
    """
}
