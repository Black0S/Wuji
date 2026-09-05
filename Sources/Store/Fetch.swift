import Foundation

/// Ce que Wuji va chercher pour son propre compte — favicons, version publiée, script à
/// installer. **Pas les pages** : celles-là passent par WebKit et son propre réseau.
///
/// Une session à nous plutôt que `URLSession.shared`, pour trois raisons qui tiennent
/// toutes en une ligne de configuration chacune.
///
/// **HTTP/3.** `assumesHTTP3Capable` tente QUIC d'emblée au lieu d'ouvrir en HTTP/2 et
/// d'attendre l'en-tête `Alt-Svc` pour basculer *la fois suivante*. Sur une favicon — une
/// requête, une réponse, fin — la fois suivante n'arrive jamais : sans ce drapeau, Wuji
/// n'aurait jamais fait un seul échange en HTTP/3. Le drapeau se pose sur la requête et
/// non sur la session, d'où le passage obligé par `request(_:)`.
///
/// **Un cache dimensionné pour ce qu'on demande.** `URLSession.shared` partage le cache de
/// l'application ; ici quelques mégaoctets suffisent et servent presque uniquement aux
/// favicons, qui reviennent à chaque fois qu'on rouvre un onglet sur le même site.
///
/// **Une file bornée.** Restaurer trente onglets demande trente favicons d'un coup ; sans
/// borne, elles partent toutes ensemble et se disputent la connexion au moment précis où
/// la page qu'on regarde en aurait besoin.
enum Fetch {

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 32 << 20)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // Une favicon qui ne répond pas ne doit pas retenir une place pendant une minute :
        // il y en a une par onglet, et l'icône par défaut est une réponse acceptable.
        configuration.timeoutIntervalForRequest = 15
        // Ce que Wuji demande pour lui-même n'a aucune raison de porter des témoins.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// Une requête pour le compte de Wuji : HTTP/3 tenté d'emblée.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.assumesHTTP3Capable = true
        return request
    }

    static func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(for: request(url))
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.assumesHTTP3Capable = true
        return try await session.data(for: request)
    }
}
