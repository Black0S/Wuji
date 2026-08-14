import Foundation

/// La page affichée quand une adresse ne répond pas.
///
/// **Elle dit qui a échoué.** Une page blanche ne distingue pas « le site est mort » de
/// « le navigateur est cassé », et c'est la confusion la plus coûteuse qu'un navigateur
/// puisse produire : elle fait douter de l'outil au lieu du réseau.
///
/// Elle est servie à l'adresse demandée, pas sous `wuji://` : l'URL reste dans la barre,
/// le bouton précédent fonctionne, et réessayer a un sens.
@MainActor
enum ErrorPage {

    /// Ce qu'on montre, selon ce qui a lâché. Le message dit **ce qui s'est passé** et
    /// **ce qu'on peut faire** — un code d'erreur ne fait ni l'un ni l'autre.
    static func html(url: URL, error: NSError) -> String {
        let (title, message, hint) = explain(url: url, error: error)

        return """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        \(InternalStyle.meta)
        <title>\(escape(title))</title>
        <style>\(InternalStyle.shared)\(style)</style>
        </head>
        <body>
          <main>
            <div class="card">
              <h1>\(escape(title))</h1>
              <p class="message">\(escape(message))</p>
              <p class="host">\(escape(url.host() ?? url.absoluteString))</p>
              <button id="retry">Réessayer</button>
              <p class="hint">\(escape(hint))</p>
            </div>
          </main>
          <script>
            const retry = document.getElementById('retry');
            retry.addEventListener('click', () => {
              retry.disabled = true;
              window.webkit.messageHandlers.wujiError.postMessage({ url: "\(escape(url.absoluteString))" });
            });
            retry.focus();
          </script>
        </body>
        </html>
        """
    }

    private static func explain(url: URL, error: NSError) -> (String, String, String) {
        let host = url.host() ?? "ce site"
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return ("Pas de connexion",
                    "Cet ordinateur n'est connecté à aucun réseau.",
                    "Vérifiez le Wi-Fi ou le câble, puis réessayez.")
        case NSURLErrorCannotFindHost:
            return ("Ce domaine n'existe pas",
                    "Aucun serveur ne répond au nom « \(host) ».",
                    "L'adresse contient peut-être une faute de frappe.")
        case NSURLErrorCannotConnectToHost:
            return ("Le serveur ne répond pas",
                    "« \(host) » a refusé la connexion.",
                    "Le site est peut-être hors service. Rien à corriger de votre côté.")
        case NSURLErrorTimedOut:
            return ("Le serveur met trop de temps",
                    "« \(host) » n'a pas répondu à temps.",
                    "La connexion est peut-être lente, ou le site surchargé.")
        case NSURLErrorNetworkConnectionLost:
            return ("Connexion interrompue",
                    "La connexion s'est coupée pendant le chargement.",
                    "Réessayer suffit généralement.")
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorSecureConnectionFailed:
            // Aucun contournement proposé, et c'est délibéré : un bouton « continuer quand
            // même » transforme un avertissement en formalité, et c'est exactement ce qu'un
            // interception de connexion attend de nous.
            return ("Connexion non sécurisée",
                    "L'identité de « \(host) » n'a pas pu être vérifiée.",
                    "Wuji n'ouvre pas cette page. Quelqu'un pourrait s'être placé entre ce site et vous.")
        default:
            return ("La page n'a pas pu être chargée",
                    error.localizedDescription,
                    "Réessayez, ou vérifiez l'adresse.")
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
    main { display: flex; align-items: center; justify-content: center;
           min-height: 100vh; max-width: none; padding: 24px; }
    .card { max-width: 380px; text-align: center; }
    h1 { font-size: 20px; margin-bottom: 10px; }
    .message { margin: 0; color: var(--text); line-height: 1.5; }
    .host { margin: 6px 0 22px; color: var(--muted); font-size: 12px;
            font-variant-numeric: tabular-nums; }
    button {
      height: 32px; padding: 0 18px; border-radius: 8px; cursor: pointer;
      background: transparent; color: var(--text); font: inherit;
      border: 1px solid var(--hairline);
    }
    button:hover { background: var(--hover); }
    button:disabled { opacity: .4; cursor: default; }
    /* La cause probable en dernier et en gris : on lit d'abord ce qui s'est passé. */
    .hint { margin: 22px 0 0; color: var(--muted); font-size: 12px; line-height: 1.5; }
    """
}
