import WebKit

/// Sait dire si une page joue quelque chose.
///
/// **La page le déclare, on ne l'interroge pas.** `requestMediaPlaybackState` existe, mais
/// il faut le demander : savoir lequel des trente onglets chante imposerait de tous les
/// scruter en boucle, ce qui coûte précisément ce qu'on cherche à économiser.
///
/// Ce que ça sert : un onglet qui joue se signale dans la colonne, et surtout il n'est
/// jamais mis en veille — couper la musique d'un onglet laissé exprès en fond serait pire
/// que la mémoire rendue.
@MainActor
enum MediaWatcher {

    static let handler = "wujiMedia"

    static let script = WKUserScript(source: """
    (() => {
      const send = (playing) => {
        try { window.webkit.messageHandlers.wujiMedia.postMessage({ playing }); } catch (e) {}
      };
      // La capture attrape les évènements des éléments ajoutés après coup — un lecteur
      // vidéo n'existe presque jamais au chargement du document.
      const check = () => {
        const media = [...document.querySelectorAll('video, audio')];
        send(media.some((element) => !element.paused && !element.muted && element.currentTime > 0));
      };
      ['play', 'pause', 'ended', 'volumechange'].forEach((name) => {
        document.addEventListener(name, check, true);
      });
      // Une page peut partir sans jamais rien jouer : on ne dit rien tant que rien ne
      // bouge, et le dernier état connu est effacé au déchargement.
      window.addEventListener('pagehide', () => send(false));
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
}
