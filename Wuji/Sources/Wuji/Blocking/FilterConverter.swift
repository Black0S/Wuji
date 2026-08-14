import Foundation

/// Traduit une liste au format Adblock en règles de contenu WebKit.
///
/// **Pourquoi traduire plutôt qu'intercepter.** Un navigateur peut aussi filtrer en Swift,
/// requête par requête, depuis le délégué de navigation : c'est plus simple à écrire et
/// c'est un piège. Le délégué ne voit pas les sous-ressources — images, scripts, pixels —
/// qui sont justement tout ce qu'on veut bloquer, et chaque décision ferait un aller-retour
/// vers le fil principal. `WKContentRuleList` est compilé une fois puis appliqué dans le
/// moteur, avant même que la requête parte.
///
/// **Ce que la traduction perd, elle le compte.** Le format Adblock a vingt ans d'options
/// dont WebKit n'a pas l'équivalent : `$redirect`, `$csp`, `$removeparam`, le masquage
/// d'exception `#@#`. Les règles concernées sont écartées et comptées, jamais approximées :
/// une règle traduite « à peu près » casse des pages, et on ne saurait pas pourquoi.
enum FilterConverter {

    struct Output {
        var rules: [[String: Any]] = []
        /// Règles traduites, règles écartées faute d'équivalent.
        var accepted = 0
        var rejected = 0
    }

    /// Options qu'on ne sait pas rendre. Une règle qui en porte une est écartée en entier :
    /// l'appliquer sans son option ferait autre chose que ce que son auteur a écrit.
    private static let unsupported: Set<String> = [
        "redirect", "redirect-rule", "csp", "removeparam", "rewrite", "badfilter",
        "replace", "cookie", "empty", "mp4", "inline-script", "inline-font",
        "genericblock", "generichide", "elemhide", "specifichide", "header", "stealth",
        "permissions", "urltransform", "all", "popup", "popunder", "webrtc"
    ]

    /// Correspondance des types de ressource. WebKit en connaît une poignée ; ce qui n'y
    /// entre pas est rangé dans `raw`, qui couvre le reste des requêtes réseau.
    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet",
        "font": "font", "media": "media", "object": "media",
        "xmlhttprequest": "raw", "websocket": "raw", "ping": "raw", "other": "raw",
        "subdocument": "document", "document": "document"
    ]

    static func rules(from text: String) -> Output {
        var output = Output()
        // Les exceptions passent après : `ignore-previous-rules` n'annule que ce qui le
        // précède. Traduites dans l'ordre du fichier, elles ne serviraient à rien.
        var blocking: [[String: Any]] = []
        var exceptions: [[String: Any]] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }

            guard let rule = convert(line) else {
                output.rejected += 1
                continue
            }
            output.accepted += 1
            if (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" {
                exceptions.append(rule)
            } else {
                blocking.append(rule)
            }
        }

        output.rules = blocking + exceptions
        return output
    }

    // MARK: - Une ligne

    private static func convert(_ line: String) -> [String: Any]? {
        if line.contains("##") || line.contains("#@#") || line.contains("#?#") {
            return cosmetic(line)
        }
        return network(line)
    }

    /// Masquage d'éléments : `domaine##sélecteur`.
    private static func cosmetic(_ line: String) -> [String: Any]? {
        // `#@#` retire un masquage sur un domaine et `#?#` s'appuie sur des sélecteurs
        // étendus : WebKit n'a ni l'un ni l'autre.
        guard !line.contains("#@#"), !line.contains("#?#"),
              let range = line.range(of: "##") else { return nil }

        let selector = String(line[range.upperBound...])
        guard !selector.isEmpty else { return nil }

        var trigger: [String: Any] = ["url-filter": ".*"]
        let scope = String(line[..<range.lowerBound])
        if !scope.isEmpty {
            let (included, excluded) = domains(scope)
            // Un sélecteur sans domaine s'applique partout ; c'est voulu par le format,
            // mais on refuse ceux qui excluent seulement — la règle serait ingérable.
            if !included.isEmpty { trigger["if-domain"] = included }
            if !excluded.isEmpty { trigger["unless-domain"] = excluded }
            if included.isEmpty && excluded.isEmpty { return nil }
        }

        return ["trigger": trigger,
                "action": ["type": "css-display-none", "selector": selector]]
    }

    /// Règle réseau : un motif, puis d'éventuelles options après `$`.
    private static func network(_ line: String) -> [String: Any]? {
        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body.removeFirst(2) }

        var options: [String] = []
        // Le `$` d'options est le dernier, et seulement s'il ressemble à des options :
        // un motif peut contenir un `$` de fin d'ancrage dans une expression régulière.
        if let index = body.lastIndex(of: "$") {
            let tail = String(body[body.index(after: index)...])
            if !tail.isEmpty, tail.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789,~=|.:/_-".contains($0) }) {
                options = tail.split(separator: ",").map(String.init)
                body = String(body[..<index])
            }
        }

        guard !body.isEmpty, let filter = urlFilter(body) else { return nil }

        var trigger: [String: Any] = ["url-filter": filter]
        var types: [String] = []

        for option in options {
            let negated = option.hasPrefix("~")
            let name = String(negated ? option.dropFirst() : Substring(option))

            if name.hasPrefix("domain=") {
                let (included, excluded) = domains(String(name.dropFirst("domain=".count)))
                if !included.isEmpty { trigger["if-domain"] = included }
                if !excluded.isEmpty { trigger["unless-domain"] = excluded }
                continue
            }
            switch name {
            case "third-party":
                trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case _ where unsupported.contains(name):
                return nil
            case _ where resourceTypes[name] != nil:
                // Une négation de type demanderait de lister tous les autres : on écarte
                // plutôt que d'inventer une liste qui vieillira mal.
                if negated { return nil }
                types.append(resourceTypes[name]!)
            default:
                return nil
            }
        }

        if !types.isEmpty { trigger["resource-type"] = Array(Set(types)) }

        return ["trigger": trigger,
                "action": ["type": isException ? "ignore-previous-rules" : "block"]]
    }

    // MARK: - Traduction du motif

    /// Le motif Adblock en expression régulière WebKit.
    ///
    /// Les correspondances qui comptent : `||` ancre un début d'hôte sous-domaines
    /// compris, `^` est un séparateur, `*` accepte n'importe quoi, et tout le reste est
    /// littéral — donc échappé.
    private static func urlFilter(_ pattern: String) -> String? {
        if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count > 2 {
            let regex = String(pattern.dropFirst().dropLast())
            return valid(regex) ? regex : nil
        }

        var source = Substring(pattern)
        var result = ""

        if source.hasPrefix("||") {
            source = source.dropFirst(2)
            // Après le schéma, en laissant passer les sous-domaines — c'est tout le sens
            // de `||` : viser un domaine et ce qui pend dessous.
            result += "^[^:]+://+([^:/?#]+\\.)?"
        } else if source.hasPrefix("|") {
            source = source.dropFirst()
            result += "^"
        }

        var anchorEnd = false
        if source.hasSuffix("|") {
            source = source.dropLast()
            anchorEnd = true
        }

        for character in source {
            switch character {
            case "*":
                result += ".*"
            case "^":
                // Le séparateur d'Adblock : tout ce qui n'appartient pas à un nom.
                result += "[^a-zA-Z0-9._%-]"
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "$", "|", "\\":
                result += "\\\(character)"
            default:
                result.append(character)
            }
        }
        if anchorEnd { result += "$" }

        guard !result.isEmpty, valid(result) else { return nil }
        return result
    }

    /// `domaine|~autre` → inclus, exclus. Le `*` en tête est la façon dont WebKit dit
    /// « ce domaine et ses sous-domaines ».
    private static func domains(_ list: String) -> ([String], [String]) {
        var included: [String] = []
        var excluded: [String] = []
        for entry in list.split(separator: "|") {
            let value = entry.trimmingCharacters(in: .whitespaces).lowercased()
            guard !value.isEmpty else { continue }
            if value.hasPrefix("~") {
                excluded.append("*" + value.dropFirst())
            } else {
                included.append("*" + value)
            }
        }
        return (included, excluded)
    }

    /// Une expression que le moteur refuserait ferait échouer la compilation de **toute**
    /// la liste : on écarte la règle plutôt que de perdre les autres.
    private static func valid(_ regex: String) -> Bool {
        (try? NSRegularExpression(pattern: regex)) != nil
    }
}
