import Foundation

/// Ce qu'on accepte de confier au compilateur de WebKit — et ce qu'on écarte avant.
///
/// **Une condition qu'on ne comprend pas doit rendre la règle inerte, jamais l'élargir.**
/// Mesuré sur ce système : `WKContentRuleListStore` accepte une clé de déclencheur qu'il ne
/// connaît pas, et l'ignore. Une règle écrite
/// `{"url-filter": ".*", "resource-type": ["script"], "load-type": ["third-party"],
/// "si-jamais-vu": […]}` — où c'est la dernière clé qui restreint — devient donc
/// « bloquer tous les scripts tiers du web ». C'est le comportement le plus dangereux qui
/// soit, et il se déclenchera à chaque capacité que WebKit ajoutera sans que Wuji le sache.
///
/// **Et une valeur qu'il ne comprend pas fait tomber la liste entière.** Mesuré aussi :
/// `resource-type: ["xmlhttprequest"]` est refusé, et c'est le fichier complet qui ne
/// compile pas — des dizaines de milliers de règles perdues pour une.
///
/// D'où deux gardes de natures opposées. Un balayage d'octets avant de compiler, qui relève
/// les noms de clés : il coûte six millisecondes par mégaoctet et ne construit rien. Puis,
/// **seulement si la compilation échoue**, une relecture complète qui écarte les règles
/// fautives et retente — le chemin cher ne sert que quand quelque chose a vraiment cassé.
enum RuleGuard {

    /// Les clés d'un déclencheur. Tout le reste écarte la règle.
    static let triggerKeys: Set<String> = [
        "url-filter", "url-filter-is-case-sensitive",
        "if-domain", "unless-domain", "if-top-url", "unless-top-url",
        "if-frame-url", "unless-frame-url",
        "resource-type", "load-type", "load-context", "request-method"
    ]

    /// Les clés d'une action, `redirect` et `modify-headers` compris — ce dernier est refusé
    /// par ce WebKit, mais un fichier peut en porter et il vaut mieux écarter la règle que
    /// le fichier.
    static let actionKeys: Set<String> = [
        "type", "selector", "redirect", "url", "extension-path",
        "request-headers", "response-headers", "operation", "header", "value"
    ]

    static let structuralKeys: Set<String> = ["trigger", "action"]

    // Les vocabulaires, relevés sur le compilateur de ce système et non dans une
    // documentation — `xmlhttprequest` et `object` y sont refusés, `raw` et `csp-report`
    // acceptés, ce qu'aucune page de documentation ne dit toutes les deux.
    static let resourceTypes: Set<String> = [
        "document", "image", "style-sheet", "script", "font", "svg-document",
        "media", "popup", "ping", "fetch", "websocket", "other", "raw", "csp-report"
    ]
    static let loadTypes: Set<String> = ["first-party", "third-party"]
    static let loadContexts: Set<String> = ["top-frame", "child-frame"]
    static let requestMethods: Set<String> = [
        "get", "head", "options", "trace", "put", "delete", "post", "patch", "connect"
    ]
    static let actionTypes: Set<String> = [
        "block", "block-cookies", "css-display-none", "ignore-previous-rules",
        "ignore-following-rules", "make-https", "notify", "redirect", "modify-headers"
    ]

    /// **Un seul passage d'octets, sans rien construire.** Relève les noms de clés : toute
    /// chaîne suivie de deux-points. Six millisecondes par mégaoctet, mesuré, là où une
    /// lecture complète du JSON en coûte des centaines.
    static func keys(in json: String) -> Set<String> {
        let o = Array(json.utf8)
        var vues = Set<String>()
        var nom: [UInt8] = []
        var i = 0
        while i < o.count {
            guard o[i] == 0x22 else { i += 1; continue }
            nom.removeAll(keepingCapacity: true)
            i += 1
            while i < o.count, o[i] != 0x22 {
                if o[i] == 0x5C { i += 2; continue }
                nom.append(o[i]); i += 1
            }
            i += 1
            var j = i
            while j < o.count, o[j] == 0x20 || o[j] == 0x0A || o[j] == 0x09 || o[j] == 0x0D {
                j += 1
            }
            if j < o.count, o[j] == 0x3A { vues.insert(String(decoding: nom, as: UTF8.self)) }
        }
        return vues
    }

    /// Le fichier ne porte-t-il que des clés connues ?
    static func onlyKnownKeys(_ json: String) -> Bool {
        keys(in: json).isSubset(of: triggerKeys.union(actionKeys).union(structuralKeys))
    }

    /// Relit le fichier et n'en garde que les règles entièrement comprises.
    ///
    /// Rend `nil` quand il n'y a rien à faire — le fichier est illisible, ou aucune règle
    /// n'est fautive et le reprendre ne servirait à rien.
    static func filtered(_ json: String) -> (json: String, dropped: Int)? {
        guard let data = json.data(using: .utf8),
              let règles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let gardées = règles.filter { estComprise($0) }
        let écartées = règles.count - gardées.count
        guard écartées > 0,
              let refait = try? JSONSerialization.data(withJSONObject: gardées),
              let texte = String(data: refait, encoding: .utf8) else { return nil }
        return (texte, écartées)
    }

    private static func estComprise(_ règle: [String: Any]) -> Bool {
        guard Set(règle.keys).isSubset(of: structuralKeys),
              let trigger = règle["trigger"] as? [String: Any],
              let action = règle["action"] as? [String: Any],
              Set(trigger.keys).isSubset(of: triggerKeys),
              Set(action.keys).isSubset(of: actionKeys),
              let type = action["type"] as? String, actionTypes.contains(type)
        else { return false }

        // Une seule condition de domaine par déclencheur : WebKit refuse au-delà, et le
        // refus emporte le fichier entier.
        let conditions = ["if-domain", "unless-domain", "if-top-url", "unless-top-url",
                          "if-frame-url", "unless-frame-url"].filter { trigger[$0] != nil }
        guard conditions.count <= 1 else { return false }

        if let v = trigger["resource-type"] as? [String],
           !Set(v).isSubset(of: resourceTypes) { return false }
        if let v = trigger["load-type"] as? [String],
           !Set(v).isSubset(of: loadTypes) { return false }
        if let v = trigger["load-context"] as? [String],
           !Set(v).isSubset(of: loadContexts) { return false }
        if let m = trigger["request-method"] {
            // Une chaîne, jamais un tableau — mesuré : le tableau est refusé.
            guard let m = m as? String, requestMethods.contains(m) else { return false }
        }
        return true
    }
}
