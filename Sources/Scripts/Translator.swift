import Foundation
import NaturalLanguage
import Translation

/// La traduction d'une page — **sur cet appareil, et nulle part ailleurs**.
///
/// C'est ce qui rend la fonction acceptable ici. Les traducteurs des autres navigateurs
/// envoient le texte de la page à un serveur : sur un article, cela révèle ce qu'on lit ; sur
/// une page privée — un courriel, un dossier médical, un intranet — cela envoie le contenu
/// lui-même à un tiers. `TranslationSession` fait le travail avec les modèles installés sur
/// la machine. Le réseau n'apprend rien de plus qu'à l'ouverture de la page.
///
/// **Rien n'est téléchargé en douce non plus.** Un couple de langues dont le modèle n'est
/// pas installé fait échouer la traduction, et Wuji le dit : c'est à macOS d'installer ses
/// modèles, dans ses réglages, où l'on voit ce qu'on installe. Un navigateur qui déclenche
/// un téléchargement d'un gigaoctet parce qu'on a cliqué « traduire » a menti sur ce que le
/// clic faisait.
@MainActor
enum Translator {

    /// Ce que la page rend à traduire, et ce qu'on lui rend traduit.
    ///
    /// Les nœuds sont numérotés côté page : le texte fait l'aller-retour sans son contexte,
    /// et c'est le numéro qui le remet à sa place. Renvoyer un HTML reconstruit aurait
    /// demandé de rejouer la mise en page, ce qui casse tout site un peu vivant.
    static let collect = """
    (() => {
      const ÉCARTÉS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'KBD', 'SAMP']);
      window.__wujiTextes = [];
      const marcheur = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode(noeud) {
          if (ÉCARTÉS.has(noeud.parentElement?.tagName)) return NodeFilter.FILTER_REJECT;
          const texte = noeud.nodeValue.trim();
          // Deux caractères ou moins : de la ponctuation, des espaces, un chiffre. Les
          // traduire coûterait autant que le reste et ne changerait rien à la lecture.
          if (texte.length < 3) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      for (let noeud = marcheur.nextNode(); noeud; noeud = marcheur.nextNode()) {
        window.__wujiTextes.push(noeud);
      }
      // Bornée : au-delà, la traduction dure plus longtemps que la lecture, et une page
      // d'application web contient des milliers de nœuds qui ne sont pas du texte suivi.
      window.__wujiTextes = window.__wujiTextes.slice(0, 800);
      return window.__wujiTextes.map((n) => n.nodeValue.trim());
    })();
    """

    /// Repose les traductions à leur place, dans l'ordre où elles ont été demandées.
    static func apply(_ translations: [String]) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: translations))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (() => {
          const traduits = \(encoded);
          const noeuds = window.__wujiTextes || [];
          for (let i = 0; i < traduits.length && i < noeuds.length; i++) {
            if (traduits[i]) noeuds[i].nodeValue = traduits[i];
          }
          document.documentElement.dataset.wujiTranslated = 'on';
          return traduits.length;
        })();
        """
    }

    /// La langue d'un texte, devinée sur place.
    ///
    /// `NLLanguageRecognizer` est le même outil que le système emploie ; il travaille hors
    /// ligne, et il faut lui donner assez de matière — d'où l'échantillon plutôt que la
    /// première phrase, qui sur une page française peut être un titre en anglais.
    static func language(of sample: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        return Locale.Language(identifier: code)
    }

    /// Traduit un lot, avec les modèles déjà installés.
    ///
    /// **`installedSource` et pas autre chose.** C'est la seule porte d'entrée qui n'exige
    /// pas d'interface SwiftUI, et c'est aussi celle qui dit la vérité : elle échoue quand
    /// le modèle manque, au lieu d'aller le chercher sans le demander.
    ///
    /// Le travail se fait **hors de l'acteur principal** : traduire huit cents fragments
    /// occupe le processeur, et le faire sur le fil de l'interface figerait la fenêtre le
    /// temps que ça dure. Seule la liste finie revient ici.
    nonisolated static func translate(_ texts: [String],
                                      from source: Locale.Language,
                                      to target: Locale.Language) async throws -> [String] {
        let session = TranslationSession(installedSource: source, target: target)
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }

        // Les réponses arrivent dans le désordre : c'est l'identifiant posé à la demande qui
        // les remet en place. Se fier à l'ordre d'arrivée décalerait la page d'un mot.
        var result = texts
        for response in try await session.translations(from: requests) {
            guard let index = response.clientIdentifier.flatMap(Int.init),
                  result.indices.contains(index) else { continue }
            result[index] = response.targetText
        }
        return result
    }

    /// Le couple de langues est-il utilisable **maintenant**, sans rien télécharger ?
    nonisolated static func isReady(from source: Locale.Language,
                                    to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }
}
