import Foundation

/// À quelle liste attribuer ce qui n'est pas arrivé.
///
/// **WebKit ne dit pas ce qu'il bloque.** Aucune API ne remonte « j'ai refusé cette
/// requête » : le journal ne connaît que des ressources absentes, rapportées par la page.
/// Il ne pouvait donc pas distinguer une régie que Wuji a arrêtée d'un serveur en panne, et
/// disait honnêtement qu'il ne savait pas.
///
/// Il peut mieux faire sans rien inventer : **les règles sont à nous, donc on peut les
/// relire.** Cette classe rejoue les motifs des règles de blocage sur l'adresse observée et
/// répond à la seule question qui manquait — *une de nos règles vise-t-elle cette
/// adresse, et laquelle ?*
///
/// Ce que ça vaut, et ce que ça ne vaut pas :
///
/// - une correspondance est une **attribution forte** : la règle existe, elle est active,
///   elle vise cette adresse, et la ressource n'est pas arrivée ;
/// - une absence de correspondance est **encore plus utile** : aucune de nos règles ne
///   vise cette adresse, donc son absence ne vient probablement pas de nous. C'est
///   exactement l'ambiguïté dont le journal s'excusait en bas de fenêtre.
///
/// Ce n'est pas ce que WebKit a fait, c'est ce que nos règles disent. La fenêtre l'écrit
/// ainsi plutôt que de laisser croire à un rapport du moteur.
@MainActor
final class RuleMatcher {

    struct Match {
        /// Le nom lisible de la liste — « Mouchards », « Mes règles ».
        let list: String
        /// La règle exacte, pour qui veut vérifier plutôt que croire.
        let rule: String
    }

    private struct Compiled {
        let list: String
        let rule: String
        let pattern: NSRegularExpression
        /// `if-domain` : la règle ne vaut que sur certaines pages. Les valeurs viennent du
        /// format de WebKit, où `*exemple.com` couvre le domaine et ses sous-domaines.
        let ifDomain: [String]
    }

    /// Ce que le bloqueur a assemblé, gardé tel quel. La compilation des motifs attend
    /// qu'on pose une question : le journal ne s'ouvre pas à chaque lancement, et deux
    /// cent soixante expressions régulières construites pour personne seraient deux cent
    /// soixante de trop.
    private var source: [(list: String, rules: [String])] = []
    private var compiled: [Compiled]?

    func load(_ source: [(list: String, rules: [String])]) {
        self.source = source
        compiled = nil
    }

    /// La règle active qui vise cette adresse, s'il y en a une.
    ///
    /// La première trouvée suffit : on cherche à qui attribuer, pas à énumérer. L'ordre est
    /// celui du catalogue, donc l'attribution est stable d'un appel à l'autre.
    func match(_ url: URL, on page: String?) -> Match? {
        let table = compiled ?? build()
        let address = url.absoluteString
        let range = NSRange(address.startIndex..., in: address)

        for entry in table {
            guard entry.pattern.firstMatch(in: address, range: range) != nil else { continue }
            guard entry.ifDomain.isEmpty || Self.covers(entry.ifDomain, page) else { continue }
            return Match(list: entry.list, rule: entry.rule)
        }
        return nil
    }

    /// `*exemple.com` couvre `exemple.com` et tout ce qui finit par `.exemple.com` — et pas
    /// `fauxexemple.com`, que le point sépare.
    static func covers(_ domains: [String], _ page: String?) -> Bool {
        guard let page = page?.lowercased(), !page.isEmpty else { return false }
        return domains.contains { entry in
            let domain = (entry.hasPrefix("*") ? String(entry.dropFirst()) : entry).lowercased()
            return page == domain || page.hasSuffix("." + domain)
        }
    }

    private func build() -> [Compiled] {
        var table: [Compiled] = []
        for group in source {
            for rule in group.rules {
                guard let data = rule.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let action = object["action"] as? [String: Any],
                      // Seuls les blocages font disparaître une ressource. Un masquage
                      // n'empêche rien d'arriver — l'attribuer serait accuser à tort.
                      action["type"] as? String == "block",
                      let trigger = object["trigger"] as? [String: Any],
                      let filter = trigger["url-filter"] as? String,
                      // WebKit ignore la casse sauf mention contraire : on fait pareil,
                      // sinon un domaine en majuscules dans la page échapperait au relevé.
                      let pattern = try? NSRegularExpression(pattern: filter,
                                                             options: [.caseInsensitive])
                else { continue }
                table.append(Compiled(list: group.list, rule: rule, pattern: pattern,
                                      ifDomain: trigger["if-domain"] as? [String] ?? []))
            }
        }
        compiled = table
        return table
    }
}
