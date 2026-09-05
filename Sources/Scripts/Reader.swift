import WebKit

/// Le mode lecture : l'article, et rien d'autre.
///
/// **Il ne télécharge rien et n'envoie rien.** Tout se passe dans la page : un script
/// cherche le bloc qui porte le texte, le sort, et remplace le document par lui. Les
/// services de lecture différée qui existent ailleurs envoient l'adresse — parfois la page
/// entière — chez quelqu'un pour la nettoyer ; ici la machine qui affiche est celle qui
/// nettoie, et le réseau n'apprend rien de plus qu'à l'ouverture.
///
/// **La façon de choisir le bloc n'est pas une heuristique de plus.** Elle est celle que
/// tout le monde utilise depuis Readability, et pour une raison qui tient en une phrase :
/// dans une page d'article, le texte se reconnaît à sa **densité de liens**. Un menu, un
/// pied de page, une colonne de recommandations sont faits de liens ; un paragraphe n'en a
/// presque pas. Compter les mots seuls désignerait la colonne latérale d'un journal ;
/// compter les liens la disqualifie immédiatement.
///
/// Rien n'est deviné sur la mise en page, et c'est délibéré : les sélecteurs à la mode —
/// `.article-body`, `#content` — changent à chaque refonte de site, et une liste de
/// sélecteurs est une liste à tenir à jour pour toujours.
@MainActor
enum Reader {

    /// Analyse la page et la remplace par sa version lisible.
    ///
    /// Rend `true` quand un article a été trouvé. Le faux est une réponse utile : sur une
    /// page d'accueil ou une application web, il n'y a pas d'article, et le dire vaut mieux
    /// que d'afficher un cadre vide en prétendant avoir travaillé.
    static let enter = """
    (() => {
      if (document.documentElement.dataset.wujiReader === 'on') return true;

      // Ce qui ne contient jamais l'article, écarté d'emblée : les compter fausserait
      // chaque score, et l'un d'eux finirait par gagner sur un site pauvre en texte.
      const ÉCARTÉS = new Set(['NAV', 'HEADER', 'FOOTER', 'ASIDE', 'FORM', 'BUTTON',
                               'SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME']);

      const densitéDeLiens = (bloc) => {
        const texte = (bloc.innerText || '').trim().length;
        if (!texte) return 1;
        let liens = 0;
        for (const a of bloc.querySelectorAll('a')) liens += (a.innerText || '').length;
        return liens / texte;
      };

      const score = (bloc) => {
        if (ÉCARTÉS.has(bloc.tagName)) return -1;
        const texte = (bloc.innerText || '').trim();
        if (texte.length < 400) return -1;
        const paragraphes = bloc.querySelectorAll('p').length;
        if (paragraphes < 2) return -1;
        // La densité de liens **divise** : c'est elle qui écarte les colonnes de
        // recommandations, qui sont longues et pleines de texte.
        return (texte.length * Math.sqrt(paragraphes)) / (1 + densitéDeLiens(bloc) * 12);
      };

      let meilleur = null, meilleurScore = 0;
      for (const bloc of document.querySelectorAll('article, main, section, div')) {
        const s = score(bloc);
        if (s > meilleurScore) { meilleurScore = s; meilleur = bloc; }
      }
      if (!meilleur) return false;

      // **Le plus petit qui contient encore tout.** Le meilleur score revient souvent à un
      // conteneur qui enveloppe l'article *et* la barre latérale ; descendre tant qu'un
      // enfant garde l'essentiel du texte rend l'article seul.
      let noeud = meilleur;
      for (;;) {
        const entier = (noeud.innerText || '').length;
        const enfant = [...noeud.children]
          .filter((e) => !ÉCARTÉS.has(e.tagName))
          .find((e) => (e.innerText || '').length > entier * 0.9);
        if (!enfant) break;
        noeud = enfant;
      }

      const titre = (document.querySelector('h1') || {}).innerText
        || document.title || '';
      const contenu = noeud.cloneNode(true);
      for (const inutile of contenu.querySelectorAll(
            'script, style, iframe, form, button, nav, aside, noscript, svg')) {
        inutile.remove();
      }
      // Les attributs de mise en page du site n'ont plus rien à piloter : les garder
      // laisserait des marges, des colonnes et des couleurs qui ne veulent plus rien dire.
      for (const élément of contenu.querySelectorAll('*')) {
        élément.removeAttribute('class');
        élément.removeAttribute('style');
        élément.removeAttribute('id');
      }

      document.documentElement.dataset.wujiReader = 'on';
      document.head.innerHTML = '<meta charset="utf-8">';
      const feuille = document.createElement('style');
      feuille.textContent = `
        :root { color-scheme: light dark; }
        body { margin: 0 auto; padding: 56px 24px 120px; max-width: 42em;
               font: 19px/1.7 ui-serif, Georgia, 'Times New Roman', serif;
               -webkit-text-size-adjust: 100%; }
        h1 { font-size: 1.9em; line-height: 1.2; margin: 0 0 .2em;
             font-family: ui-sans-serif, system-ui, sans-serif; }
        .wuji-source { font: 13px/1.5 ui-sans-serif, system-ui, sans-serif;
                       opacity: .55; margin: 0 0 2.5em; }
        p, li { margin: 0 0 1.1em; }
        h2, h3, h4 { font-family: ui-sans-serif, system-ui, sans-serif; line-height: 1.3;
                     margin: 2em 0 .5em; }
        img, video, figure { max-width: 100%; height: auto; margin: 1.5em 0; display: block; }
        figcaption { font: 13px/1.5 ui-sans-serif, system-ui, sans-serif; opacity: .6; }
        pre { overflow-x: auto; font-size: .85em; }
        blockquote { margin: 1.5em 0; padding-left: 1em;
                     border-left: 3px solid currentColor; opacity: .85; }
        a { color: inherit; text-underline-offset: 2px; }
        hr { border: 0; border-top: 1px solid currentColor; opacity: .2; margin: 2.5em 0; }
      `;
      document.head.appendChild(feuille);

      document.body.innerHTML = '';
      const entete = document.createElement('h1');
      entete.textContent = titre;
      const source = document.createElement('p');
      source.className = 'wuji-source';
      source.textContent = location.host;
      document.body.append(entete, source, contenu);
      return true;
    })();
    """

    /// Y a-t-il un article ici ? Posé avant d'offrir le mode lecture, pour qu'une entrée
    /// qui ne mènerait à rien ne s'affiche pas.
    static let detect = """
    (() => {
      if (document.documentElement.dataset.wujiReader === 'on') return true;
      let paragraphes = 0, texte = 0;
      for (const p of document.querySelectorAll('p')) {
        const n = (p.innerText || '').trim().length;
        if (n > 60) { paragraphes++; texte += n; }
      }
      return paragraphes >= 4 && texte >= 900;
    })();
    """
}
