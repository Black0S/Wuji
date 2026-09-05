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

    /// **La complétion est annotée `@MainActor`, et ce n'est pas décoratif.**
    ///
    /// WebKit demande à l'objet s'il répond au sélecteur ; Swift n'expose une méthode à
    /// Objective-C que si elle satisfait *exactement* l'exigence du protocole. Une
    /// signature qui s'en écarte compile sans une erreur ni un avertissement, et la méthode
    /// n'existe simplement pas pour le moteur. Mesuré dans le mode de langage du projet :
    ///
    ///     forme `async` .............................. ne répond pas
    ///     complétion sans `@MainActor` ............... ne répond pas
    ///     complétion avec `@MainActor` ............... répond, la page se charge
    ///
    /// C'est ce qui a fait vivre une première version de ce fichier entièrement morte :
    /// aucune invite, aucun certificat lu, aucun message — exactement comme s'il n'existait
    /// pas. `DelegateSelectorTests` demande maintenant à la classe ce que WebKit lui
    /// demande, pour que le prochain silence de ce genre soit un test rouge.
    @objc
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition,
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

        // L'exception d'abord : c'est le seul cas où notre réponse diffère de celle du
        // système, et il ne demande aucune évaluation.
        if trustedHosts.contains(space.host) {
            return (.useCredential, URLCredential(trust: trust))
        }

        // **Un hôte déjà vérifié ne l'est pas deux fois.**
        //
        // `SecTrustEvaluateWithError` valide la chaîne entière, sur le fil principal, et il
        // était appelé à **chaque** poignée de main : une page ordinaire en ouvre des
        // dizaines vers la même poignée d'hôtes. C'est le seul symbole à nous qu'un profil
        // pris pendant un chargement ait fait ressortir — vingt-six échantillons, tous ici.
        //
        // Rien n'est perdu côté sûreté, et c'est ce qui rend le cache légitime : notre
        // évaluation ne décide de rien. Nous répondons `performDefaultHandling`, donc c'est
        // **WebKit qui tranche**, à chaque fois, avec sa propre évaluation. La nôtre ne sert
        // qu'à savoir s'il faut garder le certificat pour la page d'erreur.
        if verifiedHosts.contains(space.host) { return (.performDefaultHandling, nil) }

        var problem: CFError?
        if SecTrustEvaluateWithError(trust, &problem) {
            verifiedHosts.insert(space.host)
            return (.performDefaultHandling, nil)
        }

        // Refusé : on garde le certificat pour la page d'erreur. Elle doit pouvoir montrer
        // ce qu'elle propose d'accepter — demander une exception sans dire sur quoi, c'est
        // demander un blanc-seing.
        rejectedCertificates[space.host] = trust
        return (.performDefaultHandling, nil)
    }

    /// Accorde l'exception, puis recharge : sans le second geste, on resterait devant
    /// l'échec en croyant que le bouton n'a rien fait.
    func trustHost(of url: URL) {
        guard let host = url.host() else { return }
        trustedHosts.insert(host)
        layout.toast.show("Certificat accepté pour \(host) · cette session seulement")
    }
}
