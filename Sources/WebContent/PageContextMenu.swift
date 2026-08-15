import WebKit

/// Le clic droit dans une page.
///
/// **Il remplace celui de WebKit**, pour deux raisons qui se cumulent. Le menu système
/// arrive avec son matériau translucide, ses métriques et sa langue — le reste de
/// l'application a renoncé à tout ça, et il restait sur le geste le plus fréquent après le
/// clic. Et il n'offrait presque rien : ouvrir un lien dans un nouvel onglet, copier son
/// adresse, enregistrer une image n'y étaient pas.
///
/// L'application n'a aucun moyen public de savoir ce qui se trouve sous le curseur : c'est
/// la page qui le lui dit, depuis l'événement `contextmenu` où l'information est exacte,
/// cadres imbriqués compris.
@MainActor
enum PageContextMenu {

    static let handler = "wujiContext"

    /// Ce qui se trouvait sous le curseur.
    struct Target {
        var link: URL?
        var image: URL?
        var selection = ""
        var isEditable = false

        init(payload: [String: Any]) {
            link = Self.url(payload["link"])
            image = Self.url(payload["image"])
            selection = (payload["selection"] as? String) ?? ""
            isEditable = (payload["editable"] as? Bool) ?? false
        }

        private static func url(_ raw: Any?) -> URL? {
            guard let text = raw as? String, !text.isEmpty else { return nil }
            return URL(string: text)
        }
    }

    /// Une image n'est proposée que si elle a une adresse qui vit hors de la page.
    /// `data:` et `blob:` n'en ont pas : rien à copier, rien à télécharger, et un onglet
    /// ouvert dessus s'ouvrirait sur du vide.
    static func isAddressable(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    /// Injecté dans chaque page, cadres compris — sans quoi le clic droit dans une vidéo
    /// intégrée ou un commentaire en `iframe` retomberait sur le menu système.
    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let source = """
    (() => {
      // Champs de saisie seulement : une case à cocher ou un bouton ne se coupe ni ne se
      // colle, et proposer les deux dessus serait proposer du vide.
      const FIELDS = 'textarea, [contenteditable=""], [contenteditable="true"], ' +
        'input:not([type=button]):not([type=submit]):not([type=reset]):not([type=checkbox])' +
        ':not([type=radio]):not([type=range]):not([type=color]):not([type=file])' +
        ':not([type=image]):not([readonly]):not([disabled])';

      document.addEventListener('contextmenu', (event) => {
        // La page a son propre menu : on ne s'y superpose pas. Deux menus ouverts sur le
        // même clic vaudraient moins que celui du système qu'on vient de retirer.
        if (event.defaultPrevented) return;
        event.preventDefault();

        const node = event.target instanceof Element ? event.target : null;
        const closest = (selector) => (node ? node.closest(selector) : null);
        const link = closest('a[href]');
        const image = closest('img[src]');
        const selection = String(window.getSelection() || '').trim();

        window.webkit.messageHandlers.wujiContext.postMessage({
          link: link ? link.href : '',
          image: image ? (image.currentSrc || image.src) : '',
          // Bornée : au-delà, ce n'est plus une étiquette de menu, et l'application n'en
          // fait rien de plus.
          selection: selection.slice(0, 200),
          editable: !!closest(FIELDS)
        });
      });
    })();
    """
}
