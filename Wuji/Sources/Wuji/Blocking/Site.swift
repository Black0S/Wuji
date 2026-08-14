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
        let host = host.lowercased()
        if let cached = known[host] { return cached }
        let name = PublicSuffixList.effectiveTLDPlusOne(host) ?? host
        known[host] = name
        return name
    }

    static func name(of url: URL?) -> String? {
        url?.host().map(name(ofHost:))
    }
}
