import Foundation
import PublicSuffixList

/// Ce qu'on appelle « ce site ».
///
/// **Un hôte n'est pas un site.** `www.youtube.com`, `m.youtube.com` et `youtube.com` sont
/// le même endroit pour qui navigue ; lever la protection sur l'un et pas sur les autres
/// donne une décision qui ne tient pas la première redirection.
///
/// **Et couper au deuxième point ne marche pas.** `foo.github.io` et `bar.github.io`
/// appartiennent à deux personnes différentes : une exception posée sur l'un ne doit
/// surtout pas valoir pour l'autre. Seule la liste des suffixes publics sait où se trouve
/// la frontière, et c'est exactement le genre de question où deviner est dangereux.
@MainActor
enum Site {

    /// La réponse est retenue : la question est posée à chaque navigation, à chaque
    /// synchronisation de la barre, et pour chaque exception de la liste. Elle ne change
    /// jamais pour un hôte donné.
    private static var known: [String: String] = [:]

    /// Le nom du site pour un hôte donné, ou l'hôte lui-même quand la liste ne tranche
    /// pas — une adresse IP, un nom de machine local.
    static func name(ofHost host: String) -> String {
        let host = punycode(host.lowercased())
        if let cached = known[host] { return cached }
        let name = isAddress(host) ? host : (PublicSuffixList.effectiveTLDPlusOne(host) ?? host)
        known[host] = name
        return name
    }

    /// **Un hôte accentué se range sous sa forme réseau, pas sous celle qu'on a tapée.**
    ///
    /// `URL.host()` rend `caf%C3%A9.fr` pour une adresse composée à partir de « café.fr » :
    /// la forme pourcent-encodée de la saisie, que le réseau ne connaît pas et que la liste
    /// des suffixes publics ne sait pas découper. Une exception de blocage rangée sous
    /// cette chaîne n'aurait jamais correspondu à la page, qui s'annonce en punycode.
    ///
    /// Les entrées d'URL normalisent déjà en amont ; ceci est la seconde barrière, posée là
    /// parce que c'est **ici que se fabriquent les clés de rangement**. Foundation fait la
    /// conversion : il suffit de lui faire composer une URL et de relire la chaîne.
    static func punycode(_ host: String) -> String {
        guard host.contains("%"),
              let decoded = host.removingPercentEncoding,
              let url = URL(string: "https://" + decoded),
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost
        else { return host }
        return encoded.lowercased()
    }

    /// Une adresse numérique n'a pas de suffixe public, et la liste ne le sait pas.
    ///
    /// Elle rendait `1.10` pour `192.168.1.10` — en traitant `10` comme une extension et
    /// `1` comme le nom. Deux machines du réseau local finissant par les mêmes chiffres
    /// devenaient alors « le même site » : lever la protection sur l'une la levait sur
    /// l'autre. C'est précisément le débordement que cette liste est censée empêcher.
    private static func isAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }          // IPv6
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func name(of url: URL?) -> String? {
        url?.host().map(name(ofHost:))
    }
}
