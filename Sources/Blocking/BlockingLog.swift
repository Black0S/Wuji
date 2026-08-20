import Foundation

/// Le journal de ce que le blocage a fait.
///
/// **Ce n'est pas un compteur, et surtout pas un compteur de requêtes bloquées.** Les
/// règles de contenu s'exécutent dans WebKit, qui ne remonte rien : personne ne peut dire
/// combien de requêtes il a arrêtées. Ce journal ne prétend donc pas à l'exhaustivité — il
/// note ce que Wuji a **vraiment** observé, et rien d'autre :
///
/// - une adresse principale refusée, parce que l'échec nous revient ;
/// - une ressource qui n'est jamais arrivée, parce que la page nous le signale.
///
/// Un journal partiel et honnête vaut mieux qu'un total inventé : on sait ce qu'on lit.
///
/// **Ce qu'il ne pouvait pas dire, il le dit maintenant.** Chaque ligne porte la liste dont
/// une règle vise l'adresse — relue par `RuleMatcher`, pas rapportée par le moteur — et
/// dit franchement quand aucune ne la vise : dans ce cas l'absence ne vient pas de nous,
/// et c'était précisément l'ambiguïté dont la fenêtre s'excusait.
@MainActor
final class BlockingLog {

    enum Kind: String, Codable {
        /// Une adresse principale que WebKit a refusée — le seul refus dont il nous informe.
        case blocked
        /// Une ressource qui n'est jamais arrivée, rapportée par la page.
        case refused
    }

    /// La nature de ce qui manquait. Elle vient de la balise qui a signalé l'échec, donc
    /// elle est observée et non déduite : savoir qu'un *script* n'est pas arrivé ne dit pas
    /// la même chose qu'une *image* — l'un explique une page inerte, l'autre un trou.
    enum Resource: String {
        case script, image, frame, style, media, other

        var label: String {
            switch self {
            case .script: return "script"
            case .image:  return "image"
            case .frame:  return "cadre"
            case .style:  return "feuille de style"
            case .media:  return "média"
            case .other:  return "ressource"
            }
        }

        /// La balise telle que la page nous la donne.
        init(tag: String?) {
            switch (tag ?? "").uppercased() {
            case "SCRIPT":                  self = .script
            case "IMG", "IMAGE", "PICTURE": self = .image
            case "IFRAME", "FRAME", "EMBED", "OBJECT": self = .frame
            case "LINK":                    self = .style
            case "VIDEO", "AUDIO", "SOURCE", "TRACK": self = .media
            default:                        self = .other
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let kind: Kind
        /// L'hôte de la page où c'est arrivé.
        let host: String
        /// L'hôte et le chemin de ce qui manque — de quoi le reconnaître d'un coup d'œil.
        let detail: String
        /// L'adresse entière, gardée pour qui veut la lire ou la copier. Le chemin seul
        /// suffit à reconnaître, pas à vérifier.
        let url: String
        let resource: Resource
        /// La liste dont une règle vise cette adresse, si l'on en a trouvé une.
        let list: String?
        /// La règle exacte. **On montre ce sur quoi l'attribution repose** : un journal qui
        /// nomme une liste sans montrer la règle demande d'être cru.
        let rule: String?

        /// Ce que la ligne dit d'elle-même, en une phrase.
        ///
        /// La nature d'abord — ce qui manque —, puis à qui l'attribuer. Une page refusée
        /// ne dit pas sa balise : c'est la page elle-même, et « cadre » l'aurait rangée
        /// parmi ses propres ressources.
        var attribution: String {
            let nature = kind == .blocked ? "page bloquée" : resource.label
            if let list { return "\(nature) · visé par \(list)" }
            // **Le cas le plus utile du journal.** Une ressource absente qu'aucune de nos
            // règles ne vise ne vient probablement pas de nous : c'est le site.
            return "\(nature) · aucune règle ne vise cette adresse"
        }
    }

    private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?

    /// Borné, et en mémoire seulement. Un journal de blocage écrit sur le disque serait un
    /// second historique — celui des sites visités, sous un autre nom.
    private static let limit = 500

    func record(_ kind: Kind, host: String, detail: String, url: String,
                resource: Resource = .other, match: RuleMatcher.Match? = nil) {
        entries.insert(Entry(date: Date(), kind: kind, host: host, detail: detail, url: url,
                             resource: resource, list: match?.list, rule: match?.rule), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        onChange?()
    }

    /// Combien de lignes portent le nom d'une liste. La fenêtre l'affiche : c'est la part
    /// du journal dont on sait d'où elle vient.
    var attributed: Int { entries.count { $0.list != nil } }

    func clear() {
        entries = []
        onChange?()
    }
}
