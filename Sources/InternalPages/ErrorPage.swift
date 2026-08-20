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

    /// Une adresse arrêtée par le bloqueur. WebKit la signale par ce couple précis, et le
    /// message qu'il fournit est en anglais et technique — on écrit le nôtre.
    static func isBlocked(_ error: NSError) -> Bool {
        error.domain == "WebKitErrorDomain" && error.code == 104
    }

    /// Une connexion dont l'identité n'a pas pu être vérifiée. Ces cinq codes couvrent le
    /// certificat auto-signé, expiré, pas encore valide, d'autorité inconnue, et l'échec
    /// TLS général.
    static func isUntrusted(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain
            && [NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorSecureConnectionFailed].contains(error.code)
    }

    /// Ce qu'on montre, selon ce qui a lâché. Le message dit **ce qui s'est passé** et
    /// **ce qu'on peut faire** — un code d'erreur ne fait ni l'un ni l'autre.
    ///
    /// `certificate` est ce que Wuji a pu lire du certificat refusé, empreinte comprise. Il
    /// n'est pas décoratif : c'est ce sur quoi porte la décision qu'on demande.
    static func html(url: URL, error: NSError, certificate: [String] = []) -> String {
        let (title, message, hint) = explain(url: url, error: error)
        let blocked = isBlocked(error)
        let untrusted = isUntrusted(error)
        // « Réessayer » sur une adresse bloquée échouerait à tous les coups : ce serait un
        // bouton mort. À sa place, la seule action qui change quelque chose.
        let button = blocked ? "Ne pas bloquer ce site"
                   : untrusted ? "Continuer quand même" : "Réessayer"
        let action = blocked ? #", action: "allow""#
                   : untrusted ? #", action: "trust""# : ""

        // Le détail du certificat, entre le message et le bouton : on lit ce qu'on accepte
        // avant d'avoir le moyen de l'accepter.
        let details = certificate.isEmpty ? "" : """
        <div class="certificate">\(certificate.map {
            let print = $0.hasPrefix("SHA-256") ? #" class="print""# : ""
            return "<p\(print)>" + escape($0) + "</p>"
        }.joined())</div>
        """

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
              \(details)
              <button id="retry">\(escape(button))</button>
              <p class="hint">\(escape(hint))</p>
            </div>
          </main>
          <script>
            const retry = document.getElementById('retry');
            retry.addEventListener('click', () => {
              retry.disabled = true;
              window.webkit.messageHandlers.wujiError.postMessage(
                { url: "\(escape(url.absoluteString))"\(action) });
            });
            retry.focus();
          </script>
        </body>
        </html>
        """
    }

    private static func explain(url: URL, error: NSError) -> (String, String, String) {
        let host = url.host() ?? "ce site"

        if isBlocked(error) {
            return ("Bloqué par Wuji",
                    "« \(host) » est dans la liste des régies et des traceurs.",
                    "La requête a été arrêtée avant de partir. Si une page en dépend pour fonctionner, la protection peut être levée pour ce site seulement.")
        }

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
        case NSURLErrorServerCertificateHasBadDate:
            return ("Certificat expiré",
                    "Le certificat de « \(host) » n'est plus valable.",
                    "C'est souvent un oubli de l'administrateur — mais c'est aussi ce qu'on voit quand un ancien certificat est rejoué. Comparez l'empreinte avant de continuer.")
        case NSURLErrorServerCertificateNotYetValid:
            return ("Certificat pas encore valable",
                    "Le certificat de « \(host) » ne commence que plus tard.",
                    "L'horloge de cet ordinateur est peut-être fausse : c'est la cause la plus fréquente.")
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorSecureConnectionFailed:
            // **Un contournement est proposé, et il a un coût.** Il n'y en avait aucun, au
            // motif qu'un bouton « continuer quand même » transforme un avertissement en
            // formalité. C'est vrai — et ça rendait inatteignable tout service qu'on héberge
            // soi-même : un certificat auto-signé n'est pas une attaque, c'est l'ordinaire
            // d'un serveur local ou d'une machine distante à soi.
            //
            // Ce qui rend l'exception acceptable : elle vaut **pour cet hôte**, **pour cette
            // session seulement**, elle n'est jamais écrite sur le disque, et la page montre
            // le certificat — empreinte comprise — avant de proposer de l'accepter.
            return ("Identité non vérifiée",
                    "Personne n'atteste que « \(host) » est bien qui il prétend être.",
                    "C'est l'ordinaire d'un serveur qu'on héberge soi-même, avec un certificat qu'aucune autorité n'a signé. Sur un site public, c'est un avertissement sérieux : quelqu'un peut s'être placé entre ce site et vous. Comparez l'empreinte ci-dessus avec celle de votre serveur. L'exception ne vaut que pour cette session.")
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
    /* Le certificat se lit comme une pièce d'identité qu'on nous tend : encadré, à part du
       propos, et l'empreinte en chasse fixe — deux empreintes ne se comparent pas si leurs
       caractères ne s'alignent pas. */
    .certificate {
      margin: 0 0 22px; padding: 12px 14px; text-align: left;
      border: 1px solid var(--hairline); border-radius: 10px;
    }
    .certificate p { margin: 0 0 4px; color: var(--muted); font-size: 12px; line-height: 1.5;
                     overflow-wrap: anywhere; }
    .certificate p:last-child { margin-bottom: 0; }
    .certificate .print { margin-top: 8px; color: var(--text);
                          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                          font-size: 11px; }
    """
}
