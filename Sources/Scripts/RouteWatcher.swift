import WebKit

/// Le guetteur d'adresse : il prévient quand la page change de page sans changer de document.
///
/// **Les sites d'aujourd'hui ne rechargent plus rien.** YouTube passe d'une vidéo à la
/// suivante par `history.pushState` : le document reste le même, aucune navigation n'a
/// lieu, et `decidePolicyFor` n'est jamais appelé. Un script utilisateur posé pour la page
/// précédente ne se rejoue donc pas — on regarde la vidéo suivante sans lui, et recharger à
/// la main était le seul remède.
///
/// C'était le défaut signalé, et il n'était pas intermittent : il tenait à la façon dont on
/// arrivait sur la page. Ouvrir une vidéo depuis une autre vidéo n'est pas une navigation ;
/// la coller dans l'adresse en est une. Le même script marchait donc une fois sur deux, ce
/// qui ressemble à un aléa et n'en est pas un.
///
/// **Il ne devine rien.** L'historique est instrumenté à la source — `pushState`,
/// `replaceState`, `popstate`, `hashchange` sont les quatre seules façons de changer
/// d'adresse sans recharger — plutôt que d'interroger `location` par un minuteur, qui
/// arriverait toujours en retard et tournerait pour rien le reste du temps.
@MainActor
enum RouteWatcher {

    static let handler = "wujiRoute"

    /// Cadre principal seulement : c'est là que vit l'adresse dont parle l'utilisateur, et
    /// une publicité en `iframe` qui pousse son propre historique ne doit pas faire rejouer
    /// les scripts de la page qui la contient.
    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static let source = """
    (() => {
      const tell = () => {
        try {
          window.webkit.messageHandlers.wujiRoute.postMessage({ url: location.href });
        } catch (error) { /* la page a été démontée : il n'y a plus rien à prévenir */ }
      };

      // On enveloppe plutôt que de remplacer : un site qui a lui-même enveloppé
      // `pushState` doit continuer de recevoir son appel, et rendre ce qu'il rendait.
      for (const name of ['pushState', 'replaceState']) {
        const original = history[name];
        if (typeof original !== 'function') continue;
        history[name] = function (...args) {
          const result = original.apply(this, args);
          tell();
          return result;
        };
      }

      // Le bouton précédent d'un site en une seule page, et l'ancre qui change.
      window.addEventListener('popstate', tell);
      window.addEventListener('hashchange', tell);
    })();
    """
}
