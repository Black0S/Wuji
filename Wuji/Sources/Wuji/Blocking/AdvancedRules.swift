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

    /// Ce que l'index retient pour un domaine : des **rangs** de scriptlets, pas leur
    /// code. Le code vit dans le fichier, et n'en sort que pour la page qui le demande.
    private struct Entry {
        var scriptlets: [Int] = []
        var extendedSelectors: [String] = []
    }

    /// Index par domaine. La recherche remonte les domaines parents : une règle posée sur
    /// `youtube.com` doit s'appliquer à `www.youtube.com`.
    private var byDomain: [String: Entry] = [:]
    /// Règles sans domaine, qui valent partout. Rares et volontairement séparées : les
    /// mélanger à l'index obligerait à parcourir tout le dictionnaire.
    private var global = Entry()

    // MARK: - La table des codes

    /// Les codes développés, gardés **dans un fichier projeté en mémoire** plutôt que
    /// décodés au lancement.
    ///
    /// Mesuré : 61 Mo de JSON, 26 ms pour les lire et **629 ms pour les décoder**, sur le
    /// fil principal, avant que la fenêtre apparaisse — et 60 Mo qui restaient là pour la
    /// durée de la session. Or presque aucun de ces codes ne sert : une page en demande
    /// trois, jamais sept mille.
    ///
    /// Le fichier est donc une simple suite d'octets avec une table de bornes. En extraire
    /// un code est une tranche ; le système charge la page de mémoire correspondante et
    /// peut la reprendre quand il en a besoin ailleurs.
    private var blob: Data?
    private var offsets: [Int] = []
    /// Les codes fraîchement développés, quand l'index vient d'être construit et pas relu.
    private var builtCodes: [String] = []

    private func code(at index: Int) -> String? {
        if !builtCodes.isEmpty { return builtCodes[safe: index] }
        guard let blob, offsets.indices.contains(index + 1) else { return nil }
        let range = offsets[index]..<offsets[index + 1]
        guard range.lowerBound >= 0, range.upperBound <= blob.count,
              range.lowerBound <= range.upperBound else { return nil }
        return String(decoding: blob[range], as: UTF8.self)
    }

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
        /// Les bornes des codes dans le fichier voisin, `n + 1` valeurs pour `n` codes.
        var offsets: [Int]
        var global: [Int]
        var scriptlets: [String: [Int]]
        var selectors: [String: [String]]
    }

    private var cacheFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("Wuji/advanced.json")
    }

    private var codeFile: URL {
        cacheFile.deletingLastPathComponent().appendingPathComponent("advanced.codes")
    }

    private var signature = ""

    /// Reprend l'index du dernier lancement, avant que quoi que ce soit ne se charge.
    func restore() {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        // Projeté, pas lu : les pages de ce fichier n'entrent en mémoire que si un code
        // est réellement demandé.
        blob = try? Data(contentsOf: codeFile, options: [.mappedIfSafe])
        guard blob != nil else { return }

        signature = cache.signature
        offsets = cache.offsets
        builtCodes = []
        global = Entry(scriptlets: cache.global)
        byDomain = [:]
        for (domain, indexes) in cache.scriptlets {
            byDomain[domain, default: Entry()].scriptlets = indexes
        }
        for (domain, selectors) in cache.selectors {
            byDomain[domain, default: Entry()].extendedSelectors = selectors
        }
        ruleCount = byDomain.values.reduce(global.scriptlets.count) {
            $0 + $1.scriptlets.count + $1.extendedSelectors.count
        }
    }

    private func persist() {
        var bytes = Data()
        var offsets: [Int] = [0]
        for code in builtCodes {
            bytes.append(contentsOf: Array(code.utf8))
            offsets.append(bytes.count)
        }

        var scriptlets: [String: [Int]] = [:]
        var selectors: [String: [String]] = [:]
        for (domain, entry) in byDomain {
            if !entry.scriptlets.isEmpty { scriptlets[domain] = entry.scriptlets }
            if !entry.extendedSelectors.isEmpty { selectors[domain] = entry.extendedSelectors }
        }

        let cache = Cache(signature: signature, offsets: offsets, global: global.scriptlets,
                          scriptlets: scriptlets, selectors: selectors)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        // Les octets d'abord : un index qui désignerait un fichier plus ancien que lui
        // rendrait des codes tronqués.
        try? bytes.write(to: codeFile, options: .atomic)
        try? data.write(to: cacheFile, options: .atomic)
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
        global = Entry()
        ruleCount = 0
        builtCodes = []
        blob = nil
        offsets = []
        var expanded: [String: Int] = [:]   // appel → rang, pour ne développer qu'une fois

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
                let rank: Int
                if let known = expanded[body] {
                    rank = known
                } else {
                    guard let code = self.expand(body) else { return }
                    self.builtCodes.append(code)
                    rank = self.builtCodes.count - 1
                    expanded[body] = rank
                }
                payloads.forEach { self.add(scriptlet: rank, to: $0) }
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

    private func add(scriptlet rank: Int, to domain: String) {
        if domain.isEmpty { global.scriptlets.append(rank) }
        else { byDomain[domain, default: Entry()].scriptlets.append(rank) }
    }

    private func add(selector: String, to domain: String) {
        // Un sélecteur étendu sans domaine s'appliquerait au web entier à chaque mutation
        // du DOM : le coût serait partout, le bénéfice nulle part.
        guard !domain.isEmpty else { return }
        byDomain[domain, default: Entry()].extendedSelectors.append(selector)
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
        var ranks = global.scriptlets
        var selectors: [String] = []

        // `a.b.example.com` interroge `a.b.example.com`, `b.example.com`, `example.com`.
        var parts = host.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let found = byDomain[parts.joined(separator: ".")] {
                ranks += found.scriptlets
                selectors += found.extendedSelectors
            }
            parts.removeFirst()
        }
        // Les codes ne sont tirés du fichier qu'ici, pour les trois ou quatre scriptlets
        // que cette page réclame.
        return Payload(scriptlets: ranks.compactMap { code(at: $0) }, extendedSelectors: selectors)
    }
}


private extension Array {
    /// Une table de rangs venue du disque peut désigner un code qui n'existe plus.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
