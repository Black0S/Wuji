import Foundation

/// Ce qui s'exécute dans la page pour appliquer les règles à injection.
///
/// **Trois choses, et dans cet ordre de coût.** Une feuille de style d'abord — c'est le
/// moteur qui l'applique, elle ne coûte rien après l'insertion et couvre la grande majorité
/// des règles. Puis les sélecteurs que le CSS ne sait pas résoudre : ceux-là demandent de
/// lire le DOM, et c'est la seule partie qui tourne vraiment. Les primitives nommées vivent
/// à part, dans le monde de la page.
///
/// **Ce qui est injecté est minuscule.** Mesuré sur les quatre-vingt-quatre annexes du
/// dépôt : deux cent trente mille sites couverts, **deux règles par site en médiane**, six
/// au neuvième décile, cent soixante et onze au pire (google.com). Ce n'est pas un bloqueur
/// qui embarque soixante-dix mille règles dans chaque page : c'est une poignée de lignes,
/// choisies pour ce site-là, et rien du tout sur un site qu'aucune liste ne mentionne.
enum CosmeticEngine {

    /// Le script, avec sa charge. Rendu `nil` quand il n'y a rien à faire — c'est le cas de
    /// l'écrasante majorité des pages, et poser un script qui ne fera rien reste un script.
    static func script(for payload: ExtendedStore.Payload) -> String? {
        guard !payload.isEmpty else { return nil }
        // Trois niveaux, du moins cher au plus cher. Un retrait dont le sélecteur est natif
        // n'a pas besoin de l'évaluateur : il lui faut `querySelectorAll` et de quoi
        // recommencer quand le document change, ce qui tient en quinze lignes. C'est le cas
        // de la seule règle générique du dépôt qui retire un élément — sans cette marche
        // intermédiaire, elle imposait douze kilo-octets et un évaluateur à **toutes** les
        // pages, pour un sélecteur que le navigateur résout lui-même.
        let compliqué = !payload.procedural.isEmpty || !payload.styled.isEmpty
            || payload.removals.contains { !ExtendedRules.isNativeSelector($0) }
        let travail = compliqué || !payload.removals.isEmpty

        // **Le moteur ne part que s'il a du travail.** La plupart des pages ne reçoivent
        // qu'une feuille de style : y joindre l'évaluateur et son observateur de mutations
        // ferait payer à chacune le prix des quelques-unes qui en ont besoin. Douze
        // kilo-octets analysés et un observateur posé pour quatre lignes de CSS, c'est
        // exactement ce qu'on reproche à un bloqueur d'extension.
        guard travail else {
            guard !payload.css.isEmpty else { return nil }
            return "(() => {\n" + feuilleSeule(payload.css, payload.host) + "\n})();"
        }

        if !compliqué {
            let json = (try? JSONSerialization.data(withJSONObject: payload.removals))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return """
            (() => {
            \(feuilleSeule(payload.css, payload.host))
              const sélecteurs = \(json);
            \(remover)
            })();
            """
        }

        // La garde du moteur complet est déclarée avec sa charge : la même fonction que
        // les deux autres variantes, écrite une fois.
        let charge: [String: Any] = [
            "host": payload.host,
            "css": payload.css,
            "procedural": payload.procedural,
            "styled": payload.styled,
            "removals": payload.removals
        ]
        guard let json = (try? JSONSerialization.data(withJSONObject: charge))
            .flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return "(() => {\nconst charge = \(json);\n" + surLeSite + "\n" + engine + "\n})();"
    }

    /// Le cadre est-il celui du site pour lequel ces règles ont été choisies ?
    ///
    /// Posée dans chaque variante du script, parce que chacune est injectée dans tous les
    /// cadres du document — y compris ceux d'un autre domaine, à qui ces règles n'appartiennent
    /// pas.
    private static func garde(_ host: String) -> String {
        guard !host.isEmpty else { return "" }
        let encodé = (try? JSONSerialization.data(withJSONObject: [host]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
          const __site = \(encodé);
        \(surLeSite)
          if (!__surLeSite(__site)) return;
        """
    }

    /// Le cadre appartient-il à ce site ?
    ///
    /// **Un cadre `about:blank` n'a pas de nom d'hôte**, et pourtant il appartient à la page
    /// qui l'a créé — il en partage l'origine. Beaucoup d'encarts vivent exactement là. La
    /// comparaison sur `location.hostname` seule les écartait tous : on remonte donc aux
    /// parents, ce que la même origine autorise, jusqu'à trouver un nom d'hôte.
    static let surLeSite = #"""
      const __surLeSite = (site) => {
        const correspond = (h) => {
          if (!h) return false;
          const bas = h.toLowerCase();
          return bas === site || bas.endsWith('.' + site);
        };
        if (correspond(location.hostname)) return true;
        if (location.hostname) return false;
        // `about:blank` et `srcdoc` : l'hôte est celui de l'ancêtre qui en a un.
        let fenêtre = window;
        for (let k = 0; k < 8; k++) {
          try {
            if (fenêtre.parent === fenêtre) break;
            fenêtre = fenêtre.parent;
            if (fenêtre.location.hostname) return correspond(fenêtre.location.hostname);
          } catch (_) { return false; }
        }
        return false;
      };
    """#

    /// La feuille, et rien d'autre : le cas de la plupart des pages.
    private static func feuilleSeule(_ css: String, _ host: String) -> String {
        guard !css.isEmpty else { return "" }
        let encodé = (try? JSONSerialization.data(withJSONObject: [css]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
          if (window.__wujiCosmetic) return;
          window.__wujiCosmetic = true;
        \(garde(host))
          const feuille = document.createElement('style');
          feuille.id = '__wujiCosmetic';
          feuille.textContent = \(encodé);
          (document.head || document.documentElement).appendChild(feuille);
        """
    }

    /// Retirer des éléments que le navigateur sait désigner tout seul.
    private static let remover = #"""
      if (sélecteurs.length) {
        const passer = () => {
          for (const sel of sélecteurs) {
            try { for (const el of document.querySelectorAll(sel)) el.remove(); } catch (_) {}
          }
        };
        let prévu = false;
        const démarrer = () => {
          passer();
          new MutationObserver(() => {
            if (prévu) return;
            prévu = true;
            requestAnimationFrame(() => { prévu = false; passer(); });
          }).observe(document.documentElement, { childList: true, subtree: true });
        };
        if (document.documentElement) démarrer();
        else document.addEventListener('DOMContentLoaded', démarrer, { once: true });
      }
    """#

    private static let engine = #"""
      if (window.__wujiCosmetic) return;
      window.__wujiCosmetic = true;

      // **Les règles d'un site ne s'appliquent pas dans le cadre d'un autre.** Le moteur est
      // posé dans tous les cadres — c'est ce qui permet d'atteindre les contenus d'un
      // `<iframe>` du même site, où la moitié des encarts vivent. Un cadre d'un tiers, lui,
      // reçoit le script mais pas les règles : elles ne sont pas les siennes.
      if (charge.host) {
        if (!__surLeSite(charge.host)) return;
      }

      // --- La feuille : ce qui n'a pas besoin d'être évalué ---
      if (charge.css) {
        const poser = () => {
          const feuille = document.createElement('style');
          feuille.id = '__wujiCosmetic';
          feuille.textContent = charge.css;
          // Sur `documentElement` : une page peut n'avoir pas encore de `head`, et la
          // feuille doit survivre à un `head` que la page reconstruit.
          (document.head || document.documentElement).appendChild(feuille);
        };
        if (document.documentElement) poser();
        else document.addEventListener('readystatechange', poser, { once: true });
      }

      // Les virgules de premier niveau — hors parenthèses, crochets et guillemets.
      const branches = (sel) => {
        const morceaux = [];
        let début = 0, prof = 0, crochet = 0, q = null;
        for (let i = 0; i < sel.length; i++) {
          const c = sel[i];
          if (q) { if (c === '\\') i++; else if (c === q) q = null; continue; }
          if (c === '"' || c === "'") q = c;
          else if (c === '(') prof++;
          else if (c === ')') prof--;
          else if (c === '[') crochet++;
          else if (c === ']') crochet--;
          else if (c === ',' && !prof && !crochet) {
            morceaux.push(sel.slice(début, i).trim());
            début = i + 1;
          }
        }
        morceaux.push(sel.slice(début).trim());
        return morceaux.filter(Boolean);
      };

      const règles = [];
      // **Découpé une fois, pas à chaque passe.** Le découpage est de l'analyse de chaîne :
      // le refaire pour chaque règle à chaque mutation, c'est mille quatre cents analyses
      // par seconde sur une page qui bouge, pour un résultat qui ne change jamais.
      const ajouter = (sel, action, décl) => {
        // **Une liste se scinde ici, une fois pour toutes.** `a:contains(x), b` est une
        // liste de deux sélecteurs ; l'évaluer d'un bloc faisait tomber la virgule dans le
        // CSS qui suit un opérateur, où `.matches(', b')` ne vaut rien — la règle entière
        // ne masquait plus rien, silencieusement. Mesuré sur le dépôt : 250 sélecteurs
        // étendus portent une virgule de premier niveau, soit un et demi pour cent.
        for (const branche of branches(sel)) {
          règles.push({ sel: branche, étapes: null, action, décl });
        }
      };
      for (const sel of charge.procedural) ajouter(sel, 'masquer');
      for (const [sel, décl] of charge.styled) ajouter(sel, 'style', décl);
      for (const sel of charge.removals) ajouter(sel, 'retirer');
      if (!règles.length) return;

      // --- Découper un sélecteur en étapes ---

      const ÉTENDUES = new Set(['contains', 'has-text', '-abp-contains', 'upward',
        'nth-ancestor', 'matches-css', 'matches-css-before', 'matches-css-after',
        'matches-attr', 'matches-property', 'xpath', 'min-text-length', 'matches-path',
        'remove', 'style', 'watch-attr', 'others', 'matches-media', '-abp-properties',
        'matches-prop', 'spath', 'shadow', 'remove-attr', 'remove-class']);
      // Natives quand leur argument l'est, opérateurs sinon : `:has(div)` est du CSS que
      // WebKit sait faire, `:has(div:contains(x))` ne l'est pas.
      const CONDITIONNELLES = new Set(['has', 'if', 'if-not', 'not', 'is', '-abp-has']);

      const finDe = (texte, début, ouvrant, fermant) => {
        let profondeur = 0;
        for (let i = début; i < texte.length; i++) {
          const c = texte[i];
          if (c === '\\') { i++; continue; }
          if (c === '"' || c === "'") {
            const guillemet = c;
            i++;
            while (i < texte.length && texte[i] !== guillemet) { if (texte[i] === '\\') i++; i++; }
            continue;
          }
          if (c === ouvrant) profondeur++;
          else if (c === fermant) { profondeur--; if (!profondeur) return i; }
        }
        return texte.length - 1;
      };

      const contientÉtendue = (texte) => {
        const re = /:(-abp-[a-z-]+|[a-z][a-z0-9-]*)\(/g;
        let m;
        while ((m = re.exec(texte))) {
          if (ÉTENDUES.has(m[1])) return true;
          if (CONDITIONNELLES.has(m[1])) {
            const fin = finDe(texte, m.index + m[0].length - 1, '(', ')');
            if (contientÉtendue(texte.slice(m.index + m[0].length, fin))) return true;
          }
        }
        return false;
      };

      const découper = (sel) => {
        const étapes = [];
        let css = '';
        let i = 0;
        while (i < sel.length) {
          const c = sel[i];
          if (c === '"' || c === "'") {
            const guillemet = c;
            let j = i + 1;
            while (j < sel.length && sel[j] !== guillemet) { if (sel[j] === '\\') j++; j++; }
            css += sel.slice(i, j + 1); i = j + 1; continue;
          }
          if (c === '[') { const fin = finDe(sel, i, '[', ']'); css += sel.slice(i, fin + 1); i = fin + 1; continue; }
          if (c === ':') {
            const m = /^:(-abp-[a-z-]+|[a-z][a-z0-9-]*)\(/.exec(sel.slice(i));
            if (m) {
              const nom = m[1];
              const ouvre = i + m[0].length - 1;
              const fin = finDe(sel, ouvre, '(', ')');
              const arg = sel.slice(ouvre + 1, fin);
              const opérateur = ÉTENDUES.has(nom)
                || (CONDITIONNELLES.has(nom) && contientÉtendue(arg));
              if (opérateur) {
                étapes.push({ css: css.trim(), op: nom, arg });
                css = ''; i = fin + 1; continue;
              }
            }
          }
          css += c; i++;
        }
        if (css.trim()) étapes.push({ css: css.trim(), op: null });
        return étapes;
      };

      // --- Évaluer ---

      const motif = (source) => {
        if (source === undefined || source === '') return () => true;
        const s = String(source).trim();
        if (s.length > 2 && s.startsWith('/') && s.lastIndexOf('/') > 0) {
          const fin = s.lastIndexOf('/');
          try {
            const re = new RegExp(s.slice(1, fin), s.slice(fin + 1));
            return (t) => re.test(t);
          } catch (_) { /* motif illisible : on retombe sur la recherche littérale */ }
        }
        const nu = s.replace(/\\(.)/g, '$1');
        return (t) => String(t).includes(nu);
      };

      const tous = () => [...document.querySelectorAll('*')];
      const sûr = (f, repli) => { try { return f(); } catch (_) { return repli; } };

      // Frères compris : `:scope` posé sur le parent atteint `+ .x` et `~ .y`, qu'une
      // requête sur le nœud lui-même ne peut pas voir.
      const cheminDepuis = (noeuds, css) => {
        if (!css) return noeuds;
        const sortie = [];
        for (const n of noeuds) {
          if (/^[+~]/.test(css)) {
            const parent = n.parentElement;
            if (!parent) continue;
            const frères = sûr(() => [...parent.querySelectorAll(':scope > *')], []);
            const rang = frères.indexOf(n);
            if (rang < 0) continue;
            const candidats = css.startsWith('+') ? frères.slice(rang + 1, rang + 2)
                                                  : frères.slice(rang + 1);
            const reste = css.replace(/^[+~]\s*/, '');
            for (const f of candidats) if (sûr(() => f.matches(reste), false)) sortie.push(f);
          } else if (/^>/.test(css)) {
            sortie.push(...sûr(() => [...n.querySelectorAll(':scope ' + css)], []));
          } else if (sûr(() => n.matches(css), false)) {
            sortie.push(n);
          } else {
            sortie.push(...sûr(() => [...n.querySelectorAll(css)], []));
          }
        }
        return sortie;
      };

      const descendre = (noeuds, css) => cheminDepuis(noeuds, css);

      const ancêtre = (n, arg) => {
        const nombre = Number(arg);
        if (Number.isInteger(nombre) && nombre > 0) {
          let el = n;
          for (let k = 0; k < nombre && el; k++) el = el.parentElement;
          return el;
        }
        return sûr(() => n.closest(arg), null);
      };

      const styleDe = (n, arg, pseudo) => {
        const idx = arg.indexOf(':');
        if (idx < 0) return false;
        const propriété = arg.slice(0, idx).trim();
        const teste = motif(arg.slice(idx + 1));
        const calculé = sûr(() => getComputedStyle(n, pseudo || null), null);
        return calculé ? teste(calculé.getPropertyValue(propriété)) : false;
      };

      const attributCorrespond = (n, arg) => {
        const idx = arg.indexOf('=');
        const nom = (idx < 0 ? arg : arg.slice(0, idx)).trim().replace(/^["']|["']$/g, '');
        if (idx < 0) return n.hasAttribute(nom);
        const teste = motif(arg.slice(idx + 1).replace(/^["']|["']$/g, ''));
        return n.hasAttribute(nom) && teste(n.getAttribute(nom));
      };

      const propriétéCorrespond = (n, arg) => {
        const idx = arg.indexOf('=');
        const chemin = (idx < 0 ? arg : arg.slice(0, idx)).trim();
        const val = chemin.split('.').reduce((o, c) => (o == null ? o : o[c]), n);
        if (idx < 0) return val !== undefined;
        return motif(arg.slice(idx + 1))(val);
      };

      const appliquerOp = (op, arg, noeuds) => {
        switch (op) {
          case 'contains': case 'has-text': case '-abp-contains': {
            const teste = motif(arg);
            return noeuds.filter((n) => teste(n.textContent || ''));
          }
          case 'min-text-length': {
            const n0 = Number(arg) || 0;
            return noeuds.filter((n) => (n.textContent || '').length >= n0);
          }
          case 'upward': case 'nth-ancestor':
            return noeuds.map((n) => ancêtre(n, arg)).filter(Boolean);
          case 'matches-css': case '-abp-properties':
            return noeuds.filter((n) => styleDe(n, arg, null));
          case 'matches-css-before':
            return noeuds.filter((n) => styleDe(n, arg, '::before'));
          case 'matches-css-after':
            return noeuds.filter((n) => styleDe(n, arg, '::after'));
          case 'matches-attr':
            return noeuds.filter((n) => sûr(() => attributCorrespond(n, arg), false));
          case 'matches-property': case 'matches-prop':
            return noeuds.filter((n) => sûr(() => propriétéCorrespond(n, arg), false));
          // **`:spath()` — le chemin qui suit le sujet.** Un sélecteur placé après un
          // opérateur désigne autre chose que le sujet : un descendant, mais aussi un frère.
          // Le repli sur `matches` couvrait le premier cas et laissait tomber le second, en
          // silence. `:scope` sur le parent rend les frères atteignables.
          case 'spath':
            return cheminDepuis(noeuds, arg);
          // Descendre dans les racines fantômes ouvertes : `querySelectorAll` n'y entre pas,
          // et une régie qui pose son encart dans un composant y serait hors d'atteinte.
          case 'shadow': {
            const sortie = [];
            const vus = new Set();
            const descendre = (racine) => {
              if (!racine || vus.has(racine)) return;
              vus.add(racine);
              sûr(() => sortie.push(...racine.querySelectorAll(arg)), null);
              const enfants = sûr(() => [...racine.querySelectorAll('*')], []);
              for (const el of enfants) if (el.shadowRoot) descendre(el.shadowRoot);
            };
            for (const n of (noeuds.length ? noeuds : [document])) {
              descendre(n.shadowRoot || n);
            }
            return sortie;
          }
          // Deux opérateurs qui agissent au lieu de filtrer, comme `:style()` et `:remove()`.
          case 'remove-attr': case 'remove-class': {
            const noms = String(arg || '').split(/[|,\s]+/).filter(Boolean);
            for (const n of noeuds) {
              for (const nom of noms) {
                sûr(() => op === 'remove-attr' ? n.removeAttribute(nom) : n.classList.remove(nom),
                    null);
              }
            }
            // Ils ne masquent pas : l'ensemble rendu est vide, sinon le sujet disparaîtrait
            // en plus d'avoir perdu son attribut.
            return [];
          }
          case 'matches-path':
            return motif(arg)(location.pathname + location.search) ? noeuds : [];
          case 'matches-media': {
            // Une garde, comme `:matches-path()` : la règle vaut ou ne vaut pas, elle ne
            // filtre rien.
            const ok = sûr(() => matchMedia(arg.trim()).matches, false);
            return ok ? noeuds : [];
          }
          // **`:others()` garde ce qui n'a rien à voir avec le sujet.** C'est le geste
          // « masque tout le reste » : ni le sujet, ni ses ancêtres, ni ses descendants.
          // Il était absent de la table tout en étant déclaré étendu : il retombait sur le
          // cas par défaut, qui rend l'ensemble tel quel — autrement dit `div:others()`
          // masquait **tous** les `div`, sujet compris. Soixante-cinq règles du dépôt
          // l'emploient.
          case 'others': {
            // **Un sujet absent ne fait pas disparaître la page.** C'est le seul opérateur
            // qui rend *plus* d'éléments qu'il n'en reçoit : avec un ensemble vide, « tout
            // ce qui n'est pas le sujet » est la page entière. La garde générale ne pouvait
            // rien — elle regarde le résultat, qui n'est pas vide, justement.
            if (!noeuds.length) return [];
            const sujets = new Set(noeuds);
            const parents = new Set();
            for (const n of noeuds) {
              let p = n.parentElement;
              while (p) { parents.add(p); p = p.parentElement; }
            }
            // Sous `body` seulement : `html`, `head` et les scripts ne sont « le reste »
            // de rien, et les masquer n'aurait aucun sens.
            return [...(document.body || document).querySelectorAll('*')].filter((el) => {
              if (sujets.has(el) || parents.has(el)) return false;
              for (const n of sujets) if (n.contains(el)) return false;
              return true;
            });
          }
          // Un modificateur, pas un filtre : il demande de réévaluer quand un attribut
          // change, ce que l'observateur fait déjà pour toutes les règles.
          case 'watch-attr':
            return noeuds;
          case 'xpath': {
            const sortie = [];
            const contextes = noeuds.length ? noeuds : [document];
            for (const c of contextes) {
              sûr(() => {
                const r = document.evaluate(arg, c, null,
                  XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                for (let k = 0; k < r.snapshotLength; k++) {
                  const n = r.snapshotItem(k);
                  if (n && n.nodeType === 1) sortie.push(n);
                }
              }, null);
            }
            return sortie;
          }
          case 'has': case 'if': case '-abp-has':
            return noeuds.filter((n) => évaluerDans(n, arg).length > 0);
          case 'if-not':
            return noeuds.filter((n) => évaluerDans(n, arg).length === 0);
          // **`:not()` porte sur l'élément, pas sur ses descendants.** C'est ce qui le
          // distingue de `:if-not()`, qui est bien la négation de `:has()`. Les confondre
          // faisait passer `div:contains(garder):not(:contains(zzz))` sur les deux `div`,
          // puisqu'aucun n'a de *descendant* contenant « zzz » — ils le contiennent
          // eux-mêmes.
          case 'not':
            return noeuds.filter((n) => !évaluerSur(n, arg));
          // **Ce qu'on ne sait pas faire ne masque rien.** Rendre l'ensemble intact
          // reviendrait à ignorer la condition : une règle qu'on ne comprend qu'à moitié
          // masquerait alors bien plus que son auteur ne l'a écrit. Mieux vaut une règle
          // sans effet qu'une règle qui emporte la page.
          default:
            return [];
        }
      };

      // `:has(...)` étendu : on évalue le sous-sélecteur **dans** le nœud.
      //
      // `:scope` quand le sous-sélecteur commence par un combinateur : `> span` n'est pas
      // un sélecteur valide pour `querySelectorAll`, et `:has(> span:contains(x))` ne
      // trouvait donc jamais rien — silencieusement, comme toute erreur de sélecteur.
      const évaluerDans = (racine, sous) => {
        const liste = branches(sous);
        if (liste.length > 1) {
          for (const branche of liste) {
            const trouvé = évaluerDans(racine, branche);
            if (trouvé.length) return trouvé;
          }
          return [];
        }
        const étapes = découper(sous);
        let noeuds = null;
        for (const étape of étapes) {
          if (étape.css) {
            const css = /^[>+~]/.test(étape.css) ? ':scope ' + étape.css : étape.css;
            noeuds = noeuds === null
              ? sûr(() => [...racine.querySelectorAll(css)], [])
              : descendre(noeuds, étape.css);
          } else if (noeuds === null) {
            noeuds = sûr(() => [...racine.querySelectorAll('*')], []);
          }
          if (étape.op) noeuds = appliquerOp(étape.op, étape.arg, noeuds);
          if (!noeuds.length) return [];
        }
        return noeuds || [];
      };

      // Le sous-sélecteur porte sur **cet élément-ci** : c'est ce que veut dire `:not()`.
      const évaluerSur = (racine, sous) => {
        const liste = branches(sous);
        if (liste.length > 1) return liste.some((b) => évaluerSur(racine, b));
        const étapes = découper(sous);
        let noeuds = [racine];
        for (const étape of étapes) {
          if (étape.css) {
            noeuds = noeuds.filter((n) => sûr(() => n.matches(étape.css), false));
          }
          if (étape.op) noeuds = appliquerOp(étape.op, étape.arg, noeuds);
          if (!noeuds.length) return false;
        }
        return noeuds.length > 0;
      };

      const évaluer = (règle) => {
        if (!règle.étapes) règle.étapes = découper(règle.sel);
        const étapes = règle.étapes;
        let noeuds = null;
        let action = null;
        for (const étape of étapes) {
          if (étape.css) {
            noeuds = noeuds === null
              ? sûr(() => [...document.querySelectorAll(étape.css)], [])
              : descendre(noeuds, étape.css);
          } else if (noeuds === null && étape.op !== 'xpath') {
            noeuds = tous();
          }
          if (!étape.op) continue;
          // `:remove()` et `:style()` ne filtrent pas : ils disent quoi faire du résultat.
          if (étape.op === 'remove') { action = { type: 'retirer' }; continue; }
          if (étape.op === 'style') { action = { type: 'style', décl: étape.arg }; continue; }
          noeuds = appliquerOp(étape.op, étape.arg, noeuds || []);
          if (!noeuds.length) return { noeuds: [], action };
        }
        return { noeuds: noeuds || [], action };
      };

      // --- Appliquer ---

      const marqués = new WeakSet();

      const appliquerStyle = (n, décl) => {
        for (const morceau of String(décl).split(';')) {
          const idx = morceau.indexOf(':');
          if (idx < 0) continue;
          const propriété = morceau.slice(0, idx).trim();
          let val = morceau.slice(idx + 1).trim();
          const important = /!important$/i.test(val);
          if (important) val = val.replace(/!important$/i, '').trim();
          if (propriété) sûr(() => n.style.setProperty(propriété, val, important ? 'important' : ''), null);
        }
      };

      // Le coût de la dernière passe et le nombre de passes, lisibles pour qui mesure.
      // Deux affectations, dans le monde de Wuji : la page ne les voit pas, et elles
      // évitent d'avoir à instrumenter le moteur pour savoir ce qu'il coûte.
      let passes = 0;
      const passer = () => {
        const départ = performance.now();
        passes++;
        for (const règle of règles) {
          const { noeuds, action } = sûr(() => évaluer(règle), { noeuds: [], action: null });
          const quoi = action ? action.type : règle.action;
          const décl = action && action.décl ? action.décl : règle.décl;
          for (const n of noeuds) {
            if (!n || n.nodeType !== 1) continue;
            if (quoi === 'retirer') { sûr(() => n.remove(), null); continue; }
            if (quoi === 'style') { appliquerStyle(n, décl); continue; }
            // Masquer : en ligne et `!important`, parce qu'une feuille de style d'auteur
            // arrivée après nous gagnerait autrement.
            if (marqués.has(n) && n.style.display === 'none') continue;
            marqués.add(n);
            sûr(() => n.style.setProperty('display', 'none', 'important'), null);
          }
        }
        window.__wujiCosmetic = { passes, ms: Math.round((performance.now() - départ) * 100) / 100,
                                  règles: règles.length };
      };

      // **Une seule passe par image, pas une par mutation.** Une page qui écrit son DOM en
      // boucle — un fil d'actualité, une publicité qui se recharge — produit des centaines
      // de mutations par seconde ; les suivre une à une ferait du moteur le poste le plus
      // cher de la page, pour un résultat identique à l'œil.
      // Une image **ou** un délai : une page masquée — onglet d'arrière-plan, fenêtre
      // réduite — n'a pas d'images, et le moteur n'y aurait jamais repassé après sa
      // première lecture. Les deux sont donc armés.
      //
      // **Et un jeton, parce qu'un drapeau ne suffisait pas.** Il était baissé par le
      // premier arrivé, si bien que le second trouvait la voie libre et refaisait la passe :
      // chaque lot de mutations en coûtait deux, mesuré. Le jeton n'est valable qu'une fois.
      let jeton = 0;
      let coûteuse = false;
      const planifier = () => {
        if (jeton) return;
        const mien = ++jeton;
        const relâcher = () => {
          if (jeton !== mien) return;
          jeton = 0;
          const début = performance.now();
          passer();
          // **Le moteur ne prend jamais la page en otage.** Une page qui réécrit son DOM en
          // boucle — un fil d'actualité, un lecteur vidéo — produit des mutations sans fin ;
          // si une passe coûte plus qu'une image, les enchaîner ferait du masquage cosmétique
          // le poste le plus cher du document. Au-delà du budget, on espace : le résultat est
          // le même à l'œil, et la page garde son fil.
          coûteuse = performance.now() - début > 12;
        };
        if (coûteuse) {
          setTimeout(relâcher, 250);
        } else {
          requestAnimationFrame(relâcher);
          setTimeout(relâcher, 50);
        }
      };

      const démarrer = () => {
        passer();
        new MutationObserver(planifier).observe(document.documentElement,
          { childList: true, subtree: true, attributes: true,
            attributeFilter: ['class', 'id', 'style'] });
        document.addEventListener('DOMContentLoaded', planifier, { once: true });
      };

      if (document.documentElement) démarrer();
      else document.addEventListener('DOMContentLoaded', démarrer, { once: true });
    """#
}
