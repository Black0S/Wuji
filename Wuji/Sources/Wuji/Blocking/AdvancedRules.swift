import Foundation
import JavaScriptCore

/// Les règles que WebKit ne sait pas exécuter, prêtes à être injectées dans une page.
///
/// Le convertisseur d'AdGuard met de côté deux familles : les **scriptlets** — du code qui
/// neutralise un traqueur avant que la page ne s'en serve — et les **sélecteurs étendus**,
/// ceux qui regardent le texte d'un élément ou remontent son arbre, hors de portée du CSS.
/// Ensemble, elles représentent près du tiers de ce que les listes savent faire.
///
/// **Les scriptlets sont développés ici, pas dans la page.** La bibliothèque d'AdGuard pèse
/// 860 ko ; l'injecter dans chaque page pour n'en appeler que trois fonctions serait payer
/// mille fois le prix. On la charge une seule fois dans JavaScriptCore, au moment de la
/// compilation des règles, et on ne garde que le code produit — quelques centaines d'octets
/// par site. C'est aussi ce qui évite d'introduire Node dans le dépôt.
@MainActor
final class AdvancedRules {

    /// Ce qu'il faut injecter pour un domaine donné.
    struct Payload: Codable {
        var scriptlets: [String] = []
        var extendedSelectors: [String] = []
        var isEmpty: Bool { scriptlets.isEmpty && extendedSelectors.isEmpty }
    }

    /// Index par domaine. La recherche remonte les domaines parents : une règle posée sur
    /// `youtube.com` doit s'appliquer à `www.youtube.com`.
    private var byDomain: [String: Payload] = [:]
    /// Règles sans domaine, qui valent partout. Rares et volontairement séparées : les
    /// mélanger à l'index obligerait à parcourir tout le dictionnaire.
    private var global = Payload()

    private(set) var ruleCount = 0

    /// Le moteur qui développe un appel de scriptlet en code exécutable.
    private lazy var context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "scriptlets", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(source)
        return context
    }()

    /// Le code de la bibliothèque de sélecteurs étendus, injecté seulement quand un site
    /// en a besoin.
    static var extendedCssLibrary: String {
        guard let url = Bundle.main.url(forResource: "extended-css", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }

    // MARK: - Cache

    /// L'index développé, sur le disque.
    ///
    /// **C'est ce qui règle la course au démarrage.** Analyser trente-deux mille règles et
    /// développer chaque scriptlet par JavaScriptCore prend quelques secondes ; pendant ce
    /// temps la première page part sans protection — une publicité passait au lancement,
    /// et une seule fois. Le résultat est donc gardé tel quel : au démarrage suivant, c'est
    /// une lecture de fichier, et l'index est prêt avant la première navigation.
    /// **Le code développé n'est écrit qu'une fois.**
    ///
    /// Un scriptlet développé pèse plusieurs kilo-octets, et le même sert souvent à des
    /// centaines de domaines. Recopié dans chaque entrée, l'index faisait 276 Mo sur le
    /// disque — et le relire aurait coûté plus cher que de tout recalculer. Rangé dans une
    /// table et désigné par son rang, il tient en quelques mégaoctets.
    private struct Cache: Codable {
        var signature: String
        var codes: [String]
        var global: [Int]
        var scriptlets: [String: [Int]]
        var selectors: [String: [String]]
    }

    private var cacheFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Wuji/advanced.json")
    }

    private var signature = ""

    /// Reprend l'index du dernier lancement, avant que quoi que ce soit ne se charge.
    func restore() {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        signature = cache.signature
        global = Payload(scriptlets: cache.global.compactMap { cache.codes[safe: $0] },
                         extendedSelectors: [])
        byDomain = [:]
        for (domain, indexes) in cache.scriptlets {
            byDomain[domain, default: Payload()].scriptlets = indexes.compactMap { cache.codes[safe: $0] }
        }
        for (domain, selectors) in cache.selectors {
            byDomain[domain, default: Payload()].extendedSelectors = selectors
        }
        ruleCount = byDomain.values.reduce(global.scriptlets.count) {
            $0 + $1.scriptlets.count + $1.extendedSelectors.count
        }
    }

    private func persist() {
        var table: [String: Int] = [:]
        var codes: [String] = []
        func index(_ code: String) -> Int {
            if let known = table[code] { return known }
            codes.append(code)
            table[code] = codes.count - 1
            return codes.count - 1
        }

        let globalIndexes = global.scriptlets.map(index)
        var scriptlets: [String: [Int]] = [:]
        var selectors: [String: [String]] = [:]
        for (domain, payload) in byDomain {
            if !payload.scriptlets.isEmpty { scriptlets[domain] = payload.scriptlets.map(index) }
            if !payload.extendedSelectors.isEmpty { selectors[domain] = payload.extendedSelectors }
        }

        let cache = Cache(signature: signature, codes: codes, global: globalIndexes,
                          scriptlets: scriptlets, selectors: selectors)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheFile, options: .atomic)
        }
    }

    // MARK: - Construction

    /// Lit le texte rendu par le convertisseur : une règle par ligne, au format Adblock.
    func load(_ text: String) {
        // Même contenu qu'au dernier lancement : l'index en mémoire est déjà le bon.
        let fingerprint = "\(text.count)-\(text.hashValue)"
        guard fingerprint != signature else { return }
        signature = fingerprint
        loadRules(text)
        persist()
    }

    private func loadRules(_ text: String) {
        byDomain = [:]
        global = Payload()
        ruleCount = 0
        var expanded: [String: String] = [:]   // appel → code, pour ne développer qu'une fois

        text.enumerateLines { line, _ in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!") else { return }

            // `domaines#%#//scriptlet(...)` pour AdGuard, `domaines##+js(...)` pour uBlock.
            // Le convertisseur normalise vers la première forme.
            guard let (scope, marker, body) = Self.split(line) else { return }

            let payloads = scope.isEmpty ? [""] : scope.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }

            if marker.contains("%") || body.hasPrefix("+js") || body.hasPrefix("//scriptlet") {
                guard let code = expanded[body] ?? self.expand(body) else { return }
                expanded[body] = code
                payloads.forEach { self.add(scriptlet: code, to: $0) }
            } else {
                payloads.forEach { self.add(selector: body, to: $0) }
            }
            self.ruleCount += 1
        }
    }

    /// Sépare `domaines` `marqueur` `corps`. Les marqueurs sont ceux du format Adblock,
    /// et leur longueur varie — d'où la recherche du plus long qui corresponde.
    private static func split(_ line: String) -> (String, String, String)? {
        for marker in ["#%#//scriptlet", "#@%#", "#%#", "#@?#", "#?#", "#@$?#", "#$?#", "##+js", "##"] {
            guard let range = line.range(of: marker) else { continue }
            // Une exception (`#@`) retire une règle : sans registre des règles positives à
            // annuler, on l'écarte plutôt que d'appliquer son contraire.
            guard !marker.contains("@") else { return nil }
            let body = marker == "#%#//scriptlet"
                ? "//scriptlet" + line[range.upperBound...]
                : String(line[range.upperBound...])
            return (String(line[..<range.lowerBound]), marker, body)
        }
        return nil
    }

    private func add(scriptlet code: String, to domain: String) {
        if domain.isEmpty { global.scriptlets.append(code) }
        else { byDomain[domain, default: Payload()].scriptlets.append(code) }
    }

    private func add(selector: String, to domain: String) {
        // Un sélecteur étendu sans domaine s'appliquerait au web entier à chaque mutation
        // du DOM : le coût serait partout, le bénéfice nulle part.
        guard !domain.isEmpty else { return }
        byDomain[domain, default: Payload()].extendedSelectors.append(selector)
    }

    /// Développe un appel — `//scriptlet('set-constant', 'x', 'true')` — en code prêt à
    /// être exécuté, par la bibliothèque d'AdGuard elle-même.
    private func expand(_ call: String) -> String? {
        guard let context else { return nil }
        return Self.invoke(call, in: context)
    }

    /// L'appel proprement dit. Isolé pour que la construction de la chaîne reste lisible.
    private static func invoke(_ call: String, in context: JSContext) -> String? {
        let trimmed = call.hasPrefix("//scriptlet") ? String(call.dropFirst("//scriptlet".count)) : call
        let arguments = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "()+js"))
        let literal = arguments.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        let script = """
        (function () {
          try {
            var raw = `\(literal)`;
            var parts = [], current = '', quote = null, depth = 0;
            for (var i = 0; i < raw.length; i++) {
              var c = raw[i];
              if (quote) {
                if (c === quote && raw[i - 1] !== '\\\\') { quote = null; } else { current += c; }
              } else if (c === '"' || c === "'") { quote = c; }
              else if (c === '/' && depth === 0 && current === '') { depth = 1; current += c; }
              else if (c === '/' && depth === 1) { depth = 0; current += c; }
              else if (c === ',' && depth === 0) { parts.push(current.trim()); current = ''; }
              else { current += c; }
            }
            if (current.trim()) parts.push(current.trim());
            var name = parts.shift();
            if (!name) return null;
            return scriptlets.invoke({
              name: name, args: parts, engine: 'safari', version: '1.0',
              verbose: false, ruleText: ''
            });
          } catch (e) { return null; }
        })()
        """
        let value = context.evaluateScript(script)
        guard let code = value?.toString(), code != "undefined", code != "null", !code.isEmpty else {
            return nil
        }
        return code
    }

    // MARK: - Lecture

    /// Ce qu'il faut injecter pour cette adresse : les règles du domaine, celles de ses
    /// parents, et les globales.
    func payload(for url: URL?) -> Payload {
        guard let host = url?.host()?.lowercased() else { return Payload() }
        var result = global

        // `a.b.example.com` interroge `a.b.example.com`, `b.example.com`, `example.com`.
        var parts = host.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let found = byDomain[parts.joined(separator: ".")] {
                result.scriptlets += found.scriptlets
                result.extendedSelectors += found.extendedSelectors
            }
            parts.removeFirst()
        }
        return result
    }
}


private extension Array {
    /// Une table de rangs venue du disque peut désigner un code qui n'existe plus.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
