import WebKit

/// Ce que la page peut nous dire de ce qui n'est pas arrivé.
///
/// **On ne peut pas demander à WebKit ce qu'il a bloqué.** Les règles de contenu vivent
/// dans le moteur et n'émettent rien : aucune API ne dit « j'ai refusé cette requête ».
/// Le seul témoin est la page elle-même — un élément dont la ressource n'est jamais venue
/// reçoit un `error`, et c'est tout ce qu'on a.
///
/// Ce témoin est honnête mais imprécis : il voit aussi les erreurs qui n'ont rien à voir
/// avec le blocage, un serveur en panne, un fichier retiré. Le journal le dit plutôt que
/// de faire passer un échec réseau pour une victoire — un compteur qui gonfle sur les 404
/// d'un site, c'est exactement le genre de chiffre flatteur qu'on ne veut pas.
///
/// L'écoute est passive : un écouteur en capture qui ne coûte rien tant que rien n'échoue.
@MainActor
enum BlockLogWatcher {

    static let handler = "wujiBlockLog"

    static let script = WKUserScript(source: """
    (() => {
      const seen = new Set();
      let queue = [];
      let timer = null;

      const flush = () => {
        timer = null;
        if (!queue.length) return;
        try { window.webkit.messageHandlers.wujiBlockLog.postMessage({ refused: queue }); } catch (e) {}
        queue = [];
      };

      // Groupé : une page qui rate trente ressources d'un coup ne doit pas déclencher
      // trente allers-retours vers l'application.
      const report = (url) => {
        if (!url || seen.has(url) || seen.size > 400) return;
        seen.add(url);
        queue.push(url);
        if (!timer) timer = setTimeout(flush, 250);
      };

      window.addEventListener('error', (event) => {
        const target = event.target;
        if (!target || target === window || !target.tagName) return;
        const url = target.src || target.href || (target.currentSrc || '');
        if (typeof url === 'string' && url.startsWith('http')) report(url);
      }, true);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
}
