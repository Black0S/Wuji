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
/// et d'extensions dont WebKit n'a pas l'équivalent : `$redirect`, `$csp`, les scriptlets
/// `##+js(…)`, les sélecteurs étendus `:has()`. Les règles concernées sont écartées et
/// comptées, jamais approximées — une règle traduite « à peu près » casse des pages, et on
/// ne saurait pas pourquoi. Sur les listes de référence, l'écart tourne autour de 5 %.
enum FilterConverter {

    /// Les règles d'une liste, rangées par nature. Elles ne sont pas encore mises bout à
    /// bout : c'est l'assemblage final, toutes listes confondues, qui décide de l'ordre et
    /// de ce qui tient dans le budget.
    struct Output {
        var blocking: [[String: Any]] = []
        var cosmetic: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var accepted = 0
        var rejected = 0
    }

    /// Options qu'on ne sait pas rendre. Une règle qui en porte une est écartée en entier :
    /// l'appliquer sans son option ferait autre chose que ce que son auteur a écrit.
    private static let unsupported: Set<String> = [
        "redirect", "redirect-rule", "csp", "removeparam", "queryprune", "rewrite",
        "badfilter", "replace", "cookie", "empty", "mp4", "inline-script", "inline-font",
        "genericblock", "generichide", "specifichide", "elemhide", "header", "stealth",
        "permissions", "urltransform", "popup", "popunder", "webrtc", "important",
        "denyallow", "to", "method", "strict1p", "strict3p", "ipaddress", "from",
        "app", "network", "extension", "content", "jsinject", "urlblock",
        "document-blocked", "referrerpolicy", "cname", "object-subrequest"
    ]

    /// Correspondance des types de ressource.
    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet",
        "css": "style-sheet", "font": "font", "media": "media", "object": "media",
        "xmlhttprequest": "raw", "xhr": "raw", "websocket": "raw", "ping": "raw",
        "beacon": "raw", "other": "raw", "subdocument": "document", "frame": "document",
        "document": "document", "doc": "document"
    ]

    /// Marqueurs de sélecteurs étendus : uBlock et AdGuard les comprennent, pas WebKit.
    private static let extendedSelectors = [
        ":has(", ":has-text(", ":matches-css", ":xpath(", ":upward(", ":nth-ancestor(",
        ":remove(", ":style(", ":watch-attr(", ":min-text-length(", ":matches-attr(",
        ":matches-path(", ":others(", ":contains("
    ]

    static func rules(from text: String) -> Output {
        var output = Output()

        text.enumerateLines { line, _ in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["),
                  !line.hasPrefix("#") || line.hasPrefix("##") else { return }

            guard let (rule, kind) = convert(line) else {
                output.rejected += 1
                return
            }
            output.accepted += 1
            switch kind {
            case .block:     output.blocking.append(rule)
            case .cosmetic:  output.cosmetic.append(rule)
            case .exception: output.exceptions.append(rule)
            }
        }
        return output
    }

    // MARK: - Une ligne

    private enum Kind { case block, cosmetic, exception }

    private static func convert(_ line: String) -> ([String: Any], Kind)? {
        if let rule = hosts(line) { return (rule, .block) }
        if let index = line.range(of: "#") {
            // Séparer un masquage d'une règle réseau qui contiendrait un `#` : seuls les
            // marqueurs de masquage comptent, et ils font deux caractères.
            let rest = line[index.lowerBound...]
            for marker in ["##", "#@#", "#?#", "#$#", "#%#", "#@?#", "#@$#"] where rest.hasPrefix(marker) {
                guard marker == "##", let rule = cosmetic(line, at: index.lowerBound) else { return nil }
                return (rule, .cosmetic)
            }
        }
        guard let (rule, isException) = network(line) else { return nil }
        return (rule, isException ? .exception : .block)
    }

    /// Format « hosts » : `0.0.0.0 domaine`.
    ///
    /// Plusieurs listes de référence sont publiées ainsi — celle de Peter Lowe, celle de
    /// Dan Pollock. Sans cette lecture, chaque ligne devenait un motif littéral contenant
    /// une adresse IP et une espace : trois mille cinq cents règles qui ne correspondaient
    /// à rien et qui étaient comptées comme actives. Un compteur qui ment sur ce qu'il
    /// protège est pire qu'un compteur absent.
    private static func hosts(_ line: String) -> [String: Any]? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2,
              ["0.0.0.0", "127.0.0.1", "::1", "::"].contains(String(parts[0])) else { return nil }

        let host = String(parts[1]).lowercased()
        // La ligne qui redirige la machine vers elle-même n'est pas un blocage.
        guard host != "localhost", host != "localhost.localdomain", host != "broadcasthost",
              host.contains("."), host.allSatisfy(\.isASCII),
              let filter = urlFilter("||\(host)^") else { return nil }

        return ["trigger": ["url-filter": filter], "action": ["type": "block"]]
    }

    /// Masquage d'éléments : `domaine##sélecteur`.
    private static func cosmetic(_ line: String, at marker: String.Index) -> [String: Any]? {
        let selector = String(line[line.index(marker, offsetBy: 2)...])
        guard !selector.isEmpty,
              // Les scriptlets injectent du code, ce que les règles de contenu ne font pas.
              !selector.hasPrefix("+js("), !selector.hasPrefix("script:"),
              !extendedSelectors.contains(where: selector.contains),
              selector.allSatisfy(\.isASCII) else { return nil }

        var trigger: [String: Any] = ["url-filter": ".*"]
        let scope = String(line[..<marker])
        if !scope.isEmpty {
            let (included, excluded) = domains(scope)
            // WebKit refuse les deux à la fois. On garde l'inclusion, qui restreint ;
            // l'exclusion seule ferait une règle plus large que ce qui est écrit.
            if !included.isEmpty {
                trigger["if-domain"] = included
            } else if !excluded.isEmpty {
                trigger["unless-domain"] = excluded
            } else {
                return nil
            }
        }

        return ["trigger": trigger,
                "action": ["type": "css-display-none", "selector": selector]]
    }

    /// Règle réseau : un motif, puis d'éventuelles options après `$`.
    private static func network(_ line: String) -> ([String: Any], Bool)? {
        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body.removeFirst(2) }

        var options: [String] = []
        // Le `$` d'options est le dernier, et seulement s'il ressemble à des options :
        // un motif peut contenir un `$` de fin d'ancrage dans une expression régulière.
        if let index = body.lastIndex(of: "$") {
            let tail = String(body[body.index(after: index)...])
            if !tail.isEmpty,
               tail.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789,~=|.:/_-*".contains($0) }) {
                options = tail.split(separator: ",").map(String.init)
                body = String(body[..<index])
            }
        }

        // Un `$` qui reste, c'est une option qu'on n'a pas su lire — `$header=server:/…/`
        // par exemple. Traiter la ligne entière comme une adresse produisait un motif
        // absurde que WebKit refusait, et cette règle-là faisait tomber toute la tranche.
        guard !body.contains("$") else { return nil }

        guard !body.isEmpty, body.allSatisfy(\.isASCII), let filter = urlFilter(body) else { return nil }

        var trigger: [String: Any] = ["url-filter": filter]
        var types: [String] = []
        var excludedTypes: [String] = []

        for option in options {
            let negated = option.hasPrefix("~")
            let name = String(negated ? option.dropFirst() : Substring(option))

            if name.hasPrefix("domain=") {
                let (included, excluded) = domains(String(name.dropFirst("domain=".count)))
                if !included.isEmpty {
                    trigger["if-domain"] = included
                } else if !excluded.isEmpty {
                    trigger["unless-domain"] = excluded
                }
                continue
            }
            switch name {
            case "third-party", "3p":
                trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "first-party", "1p":
                trigger["load-type"] = [negated ? "third-party" : "first-party"]
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "all":
                continue
            case _ where unsupported.contains(name):
                return nil
            case _ where resourceTypes[name] != nil:
                if negated { excludedTypes.append(resourceTypes[name]!) }
                else { types.append(resourceTypes[name]!) }
            default:
                return nil
            }
        }

        if !types.isEmpty {
            trigger["resource-type"] = Array(Set(types)).sorted()
        } else if !excludedTypes.isEmpty {
            // Une négation de type se rend en listant les autres. C'est verbeux mais
            // exact, alors qu'ignorer l'option élargirait la règle.
            let all = Set(resourceTypes.values)
            let kept = all.subtracting(excludedTypes)
            guard !kept.isEmpty else { return nil }
            trigger["resource-type"] = kept.sorted()
        }

        return (["trigger": trigger,
                 "action": ["type": isException ? "ignore-previous-rules" : "block"]],
                isException)
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
            return valid(regex) && webKitCompatible(regex) ? regex : nil
        }

        var source = Substring(pattern)
        var result = ""

        // Un motif littéral qui contient de la syntaxe d'expression régulière est un motif
        // qu'on ne sait pas lire : `||/^kiryuu\\d+\\.com/` mélange les deux notations. Les
        // échapper caractère par caractère fabriquait des expressions déséquilibrées que
        // WebKit refusait — et un refus coûte la tranche entière, pas la règle.
        if source.dropFirst(2).contains(where: { "\\(){}".contains($0) }) { return nil }

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

        // Pas de validation par `NSRegularExpression` ici : le motif est construit
        // caractère par caractère, chaque métacaractère y est soit traduit soit échappé.
        // La compiler quand même coûtait la moitié du temps de conversion — trois cent
        // mille expressions régulières fabriquées pour être aussitôt jetées.
        //
        // `.*` seul ferait une règle qui bloque le web entier si une option manque.
        guard result.count > 2, result != ".*" else { return nil }
        return result
    }

    /// `domaine|~autre` → inclus, exclus. Le `*` en tête est la façon dont WebKit dit
    /// « ce domaine et ses sous-domaines ».
    private static func domains(_ list: String) -> ([String], [String]) {
        var included: [String] = []
        var excluded: [String] = []
        for entry in list.split(separator: "|") {
            let value = entry.trimmingCharacters(in: .whitespaces).lowercased()
            // Les domaines non ASCII devraient être convertis en punycode ; on les écarte
            // plutôt que d'écrire une règle que WebKit refusera.
            guard !value.isEmpty, value.allSatisfy(\.isASCII), !value.contains("*") else { continue }
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

    /// `NSRegularExpression` est un juge trop indulgent.
    ///
    /// WebKit n'implémente qu'un **sous-ensemble** des expressions régulières : le point,
    /// les classes, les groupes, l'alternance, et les quantificateurs `* + ?`. Une seule
    /// règle qui dépasse ce sous-ensemble — un `{4,22}` venu d'une liste publique — fait
    /// échouer la compilation de la liste entière, donc zéro protection. Ces règles-là
    /// passaient la validation de Foundation sans problème : c'est exactement le genre de
    /// vérification qui rassure sans rien vérifier.
    private static func webKitCompatible(_ regex: String) -> Bool {
        // Paresseux, groupes non capturants, assertions : hors sous-ensemble.
        for pattern in ["*?", "+?", "??", "(?"] where regex.contains(pattern) { return false }

        var escaped = false
        for character in regex {
            if escaped {
                // Les raccourcis de classe (\w, \d, \s…) et les références arrière
                // n'existent pas non plus. Un caractère spécial échappé, si.
                if "wWdDsSbBAZzGnrtfv0123456789".contains(character) { return false }
                escaped = false
                continue
            }
            switch character {
            case "\\": escaped = true
            // Répétition bornée : « arbitrary atom repetitions are not supported ».
            case "{", "}": return false
            // Alternance : « disjunctions are not supported yet ». Le sous-ensemble est
            // plus étroit qu'il n'y paraît, et chaque écart coûte la liste entière.
            case "|": return false
            default: break
            }
        }
        return true
    }
}
