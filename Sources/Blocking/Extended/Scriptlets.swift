import Foundation

/// Les primitives nommées que Wuji sait exécuter.
///
/// **Nommées, écrites ici, et rien d'autre.** Le dépôt consigne le nom d'une primitive et
/// ses arguments — jamais du JavaScript libre : cinq cent trente-neuf occurrences comptées
/// dans les listes, aucune retenue. C'est la différence qui rend la chose acceptable. Une
/// liste ne nous fait pas exécuter son code ; elle demande un geste que nous avons écrit,
/// qu'on peut relire, et qui ne fait que ce que son nom dit. Un nom inconnu n'exécute rien.
///
/// **Les listes écrivent le même geste sous cinq noms.** `aopr`, `abort-on-property-read`,
/// `ubo-aopr` sont une seule chose ; AdGuard préfixe `ubo-` ce qu'elle emprunte à uBlock, et
/// les deux projets abrègent différemment. On ramène donc tout à un nom canonique avant de
/// chercher : sans cela, la moitié des règles tomberait comme « inconnue » alors qu'on sait
/// parfaitement les appliquer.
enum Scriptlets {

    /// Les abréviations et les emprunts, ramenés au nom qu'on implémente.
    private static let aliases: [String: String] = [
        "aopr": "abort-on-property-read",
        "aopw": "abort-on-property-write",
        "acs": "abort-current-inline-script",
        "acis": "abort-current-inline-script",
        "aost": "abort-on-stack-trace",
        "aeld": "prevent-addEventListener",
        "addEventListener-defuser": "prevent-addEventListener",
        "nostif": "prevent-setTimeout",
        "no-setTimeout-if": "prevent-setTimeout",
        "setTimeout-defuser": "prevent-setTimeout",
        "nosiif": "prevent-setInterval",
        "no-setInterval-if": "prevent-setInterval",
        "setInterval-defuser": "prevent-setInterval",
        "nano-stb": "adjust-setTimeout",
        "nano-setTimeout-booster": "adjust-setTimeout",
        "nano-sib": "adjust-setInterval",
        "nano-setInterval-booster": "adjust-setInterval",
        "nowoif": "prevent-window-open",
        "window.open-defuser": "prevent-window-open",
        "no-fetch-if": "prevent-fetch",
        "no-xhr-if": "prevent-xhr",
        "ra": "remove-attr",
        "rc": "remove-class",
        "rmnt": "remove-node-text",
        "rpnt": "replace-node-text",
        "trusted-replace-node-text": "replace-node-text",
        "set": "set-constant",
        "trusted-set-constant": "set-constant",
        "trusted-set-cookie": "set-cookie",
        "trusted-set-cookie-reload": "set-cookie-reload",
        "trusted-set-local-storage-item": "set-local-storage-item",
        "trusted-set-session-storage-item": "set-session-storage-item",
        "trusted-click-element": "click-element",
        "noeval": "prevent-eval-if",
        "noeval-if": "prevent-eval-if",
        "prevent-bab": "prevent-bab",
        "nobab": "prevent-bab",
        "cookie-remover": "remove-cookie",
        "trusted-set-attr": "set-attr",
        "abp-contains": "contains"
    ]

    /// Ce que la bibliothèque sait faire. Un nom absent d'ici n'est pas envoyé à la page :
    /// mieux vaut ne rien faire que poser un appel que rien ne recevra.
    static let supported: Set<String> = [
        "set-constant", "set-cookie", "set-cookie-reload", "remove-cookie",
        "set-local-storage-item", "set-session-storage-item",
        "abort-on-property-read", "abort-on-property-write",
        "abort-current-inline-script", "abort-on-stack-trace",
        "prevent-addEventListener", "prevent-setTimeout", "prevent-setInterval",
        "adjust-setTimeout", "adjust-setInterval",
        "prevent-window-open", "prevent-fetch", "prevent-xhr", "prevent-eval-if",
        "prevent-element-src-loading", "prevent-bab",
        "remove-attr", "remove-class", "remove-node-text", "replace-node-text",
        "json-prune", "href-sanitizer", "click-element", "nowebrtc", "log",
        "set-attr", "hide-in-shadow-dom", "trusted-suppress-native-method"
    ]

    /// `ubo-aopr.js` → `abort-on-property-read`.
    static func canonical(_ name: String) -> String {
        var nom = name
        if nom.hasPrefix("ubo-") { nom = String(nom.dropFirst(4)) }
        if nom.hasPrefix("abp-") { nom = String(nom.dropFirst(4)) }
        if nom.hasSuffix(".js") { nom = String(nom.dropLast(3)) }
        return aliases[nom] ?? nom
    }

    static func isSupported(_ canonicalName: String) -> Bool { supported.contains(canonicalName) }

    /// Ce que la page reçoit : la bibliothèque, puis les appels.
    ///
    /// Le tout dans une fermeture, et sous un drapeau : un document qui rejoue ses scripts
    /// — un `history.pushState` suivi d'un retour — ne doit pas reposer deux fois les mêmes
    /// pièges, ce qui doublerait les compteurs et casserait les restaurations.
    static func script(for calls: [[String]], host: String = "") -> String {
        // **Le nom est ramené au canonique ici aussi.** Le magasin le fait déjà en
        // choisissant les règles ; le refaire coûte trois mots et retire une classe entière
        // d'erreurs — un appelant qui passerait `cookie-remover` obtenait sinon un geste
        // introuvable, en silence, et l'on cherchait le défaut dans la primitive.
        let canoniques = calls.compactMap { appel -> [String]? in
            guard let nom = appel.first else { return nil }
            return [canonical(nom)] + appel.dropFirst()
        }
        let json = (try? JSONSerialization.data(withJSONObject: canoniques))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let site = (try? JSONSerialization.data(withJSONObject: [host]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (() => {
          if (window.__wujiScriptlets) return;
          window.__wujiScriptlets = true;
          // **Les primitives d'un site ne s'exécutent pas dans le cadre d'un autre.** Elles
          // sont posées dans chaque cadre — c'est ce qui permet d'atteindre un lecteur ou un
          // mur anti-bloqueur enfermé dans un `<iframe>` du même site. Remplacer une
          // propriété dans le cadre d'un tiers, en revanche, serait agir chez quelqu'un
          // qu'aucune règle ne désigne.
          const __site = \(site);
          if (__site) {
            const __ici = location.hostname.toLowerCase();
            if (__ici !== __site && !__ici.endsWith('.' + __site)) return;
          }
        \(library)
          const appels = \(json);
          for (const appel of appels) {
            const nom = appel[0], args = appel.slice(1);
            const geste = bibliothèque[nom];
            if (!geste) continue;
            try { geste(...args); } catch (_) { /* une primitive ne casse jamais la page */ }
          }
        })();
        """
    }
}
