import AppKit
import WebKit

/// Ce qu'on fait quand un serveur demande à savoir qui vous êtes — ou quand on ne peut pas
/// savoir qui il est.
///
/// **Sans ce fichier, deux familles entières de sites étaient hors d'atteinte.** Mesuré
/// avant d'être écrit, sur deux serveurs locaux :
///
/// - un site en authentification HTTP Basic n'affichait **aucune invite** : WebKit rendait
///   simplement la page du 401, et l'on ne pouvait jamais entrer. Tableaux de bord,
///   préproductions derrière un `.htpasswd`, imprimantes, NAS : des culs-de-sac ;
/// - un site en HTTPS auto-signé échouait sec, code -1202, sans issue proposée. C'est le
///   cas ordinaire d'un service qu'on héberge soi-même.
///
/// Aucun mot de passe n'est retenu. Wuji n'a pas de trousseau, et un navigateur qui
/// garderait des identifiants sans en avoir un serait le pire des deux mondes.
extension AppDelegate {

    /// **La forme à complétion, et pas la forme `async`.** Mesuré : écrite en `async`, cette
    /// méthode n'est jamais appelée — WebKit ne la voit pas, le défi part en traitement par
    /// défaut, et tout se passe comme s'il n'y avait aucun délégué. C'est la seule du
    /// projet dans ce cas, et la seule dont la complétion prend **deux** valeurs ; les
    /// délégués asynchrones à retour simple — politique de navigation, capture média — sont
    /// bien appelés, vérifié dans le même essai.
    ///
    /// Un défaut silencieux : rien ne compile en erreur, rien ne s'affiche, la fonction
    /// n'existe simplement pas. D'où cette note plutôt qu'une réécriture « plus moderne »
    /// un jour de ménage.
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                               URLCredential?) -> Void) {
        let space = challenge.protectionSpace

        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            let (disposition, credential) = trust(for: space)
            completionHandler(disposition, credential)

        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            // Trois refus de suite, on arrête de demander : une boucle d'invites sur un
            // mot de passe faux se termine par la fermeture de l'onglet, pas par une
            // réussite.
            guard challenge.previousFailureCount < 3 else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            credentials(for: space, again: challenge.previousFailureCount > 0,
                        answer: completionHandler)

        default:
            // Les certificats clients et le reste : au système, qui sait faire.
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Identifiants

    private func credentials(for space: URLProtectionSpace, again: Bool,
                             answer: @escaping (URLSession.AuthChallengeDisposition,
                                                URLCredential?) -> Void) {
        // Une carte à la fois. Deux onglets qui demandent en même temps laisseraient la
        // seconde question invisible, et sa page attendrait une réponse qui ne viendrait
        // jamais : mieux vaut la renvoyer à son 401, où « Réessayer » redemandera.
        guard !layout.toast.isAsking else { return answer(.performDefaultHandling, nil) }

        let host = space.host
        // Le domaine d'authentification est le nom que le serveur donne à sa zone
        // protégée. Il vient du serveur, donc il peut dire n'importe quoi : on le montre
        // entre guillemets, après le nom du site, jamais à sa place.
        let realm = (space.realm ?? "").trimmingCharacters(in: .whitespaces)
        let zone = realm.isEmpty ? "" : " · « \(realm) »"
        let message = again
            ? "Identifiant ou mot de passe refusé. Wuji n'enregistre rien : ce que vous tapez part au serveur et disparaît."
            : "Ce serveur demande une authentification\(zone). Wuji n'enregistre rien : ce que vous tapez part au serveur et disparaît."

        layout.toast.askCredentials(
            title: "Se connecter à \(host)",
            message: message,
            onCancel: { answer(.cancelAuthenticationChallenge, nil) },
            onSubmit: { user, password in
                // `.forSession` : l'identifiant vaut pour les requêtes suivantes de cette
                // session — sinon chaque image d'une page protégée redemanderait le mot de
                // passe. Rien n'est écrit sur le disque.
                answer(.useCredential,
                       URLCredential(user: user, password: password, persistence: .forSession))
            })
    }

    // MARK: - Certificats

    /// Un certificat que le système refuse.
    ///
    /// **Par défaut, on ne passe pas.** L'exception n'existe que si elle a été accordée
    /// pour cet hôte, dans cette session, depuis la page d'erreur — après avoir lu ce qu'on
    /// accepte. Elle n'est jamais écrite sur le disque : une exception TLS permanente est
    /// un trou qu'on oublie avoir creusé, et qui protège l'intercepteur suivant.
    private func trust(for space: URLProtectionSpace)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }

        var problem: CFError?
        if SecTrustEvaluateWithError(trust, &problem) {
            return (.performDefaultHandling, nil)
        }

        // Refusé : on garde le certificat pour la page d'erreur. Elle doit pouvoir montrer
        // ce qu'elle propose d'accepter — demander une exception sans dire sur quoi, c'est
        // demander un blanc-seing.
        rejectedCertificates[space.host] = trust

        guard trustedHosts.contains(space.host) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Accorde l'exception, puis recharge : sans le second geste, on resterait devant
    /// l'échec en croyant que le bouton n'a rien fait.
    func trustHost(of url: URL) {
        guard let host = url.host() else { return }
        trustedHosts.insert(host)
        layout.toast.show("Certificat accepté pour \(host) · cette session seulement")
    }
}
