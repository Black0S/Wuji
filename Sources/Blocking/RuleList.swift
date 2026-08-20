import Foundation

/// Les listes livrées avec Wuji.
///
/// **Une liste est une décision qu'on peut prendre, pas un rangement.** Découper les
/// règles en familles n'aurait aucun intérêt si les familles ne correspondaient à rien :
/// chacune de celles-ci existe parce qu'on peut vouloir la garder en éteignant les
/// autres — les mouchards sans l'habillage, la publicité sans les réseaux sociaux, tout
/// sauf la télémétrie d'appareils qu'on ne possède pas.
///
/// Le catalogue est écrit ici et non lu d'un dossier : un fichier posé à côté des autres
/// n'a ni nom lisible ni description, et une liste sans phrase qui la nomme n'est pas un
/// réglage — c'est une case à cocher qu'on n'ose pas décocher.
struct RuleList: Sendable, Identifiable, Hashable {

    /// Ce qui est enregistré dans les réglages, et ce qui nomme la liste compilée.
    let id: String
    /// Le fichier, sans extension, dans `Blocking/Assets`.
    var file: String { "wuji-\(id)" }
    /// L'identifiant de la liste compilée dans le magasin de WebKit.
    var identifier: String { "wuji.\(id)" }

    let name: String
    /// Une phrase, au présent, qui dit ce que la liste retire — et ce qu'on perd à
    /// l'éteindre quand ce n'est pas évident.
    let summary: String

    static let all: [RuleList] = [
        RuleList(id: "tracking", name: "Mouchards",
                 summary: "Mesure d'audience, analyse de comportement, attribution, "
                     + "courtiers d'identité, empreinte de navigateur. Rien ici ne sert "
                     + "à afficher la page : c'est la liste qui casse le moins."),
        RuleList(id: "ads", name: "Publicité",
                 summary: "Régies, places de marché en temps réel, articles sponsorisés. "
                     + "Celle dont l'absence se voit le plus."),
        RuleList(id: "cosmetic", name: "Habillage publicitaire",
                 summary: "Masque les éléments dont la classe annonce une publicité "
                     + "(.ad-slot, #adsbox). La seule qui juge sur le nom et non sur "
                     + "l'origine — donc la seule qui puisse se tromper de cible."),
        RuleList(id: "session-replay", name: "Rejeu de session",
                 summary: "L'enregistrement de vos mouvements et de vos frappes, rejoué "
                     + "ensuite comme une vidéo par l'éditeur du site."),
        RuleList(id: "social", name: "Réseaux sociaux",
                 summary: "Les boutons et pixels qui rapportent votre visite à un réseau "
                     + "depuis un site qui n'est pas le sien. Un partage ou un contenu "
                     + "intégré peut en dépendre."),
        RuleList(id: "telemetry", name: "Télémétrie des appareils",
                 summary: "Ce que les téléviseurs, consoles et systèmes renvoient à leur "
                     + "fabricant. Sans ces appareils sur le réseau, elle ne bloque rien.")
    ]

    static func named(_ id: String) -> RuleList? { all.first { $0.id == id } }
}
