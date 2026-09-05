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
      let last = null;
      const send = (playing) => {
        // On ne parle que quand l'état change : `timeupdate` bat quatre fois par seconde,
        // et prévenir à chaque battement inonderait le fil principal pour rien.
        if (playing === last) return;
        last = playing;
        try { window.webkit.messageHandlers.wujiMedia.postMessage({ playing }); } catch (e) {}
      };

      // Un lecteur muet ne fait pas de bruit, et l'icône annonce du son : on ne la pose
      // pas pour une vidéo de fond qui tourne sans qu'on l'entende.
      const check = () => {
        const media = [...document.querySelectorAll('video, audio')];
        send(media.some((e) => !e.paused && !e.ended && !e.muted && e.currentTime > 0));
      };

      // En capture, parce qu'un lecteur n'existe presque jamais au chargement du document
      // et que ses évènements ne remontent pas toujours jusqu'ici autrement.
      ['play', 'pause', 'ended', 'volumechange', 'timeupdate', 'loadedmetadata']
        .forEach((name) => document.addEventListener(name, check, true));

      // Le filet : une lecture peut commencer sans qu'aucun de ces évènements ne nous
      // parvienne — un lecteur qui remplace son élément vidéo, une page qui démarre avant
      // que le script soit posé. Deux secondes suffisent à le rattraper, et le relevé ne
      // coûte qu'une interrogation de quelques éléments.
      setInterval(check, 2000);
      document.addEventListener('DOMContentLoaded', check);

      window.addEventListener('pagehide', () => send(false));
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// Met la vidéo la plus grande en incrustation, ou l'en retire.
    ///
    /// **La plus grande, et non la première.** Une page d'article porte souvent une vidéo
    /// d'en-tête muette de deux cents pixels avant celle qu'on regarde ; prendre la
    /// première incrusterait le décor.
}
