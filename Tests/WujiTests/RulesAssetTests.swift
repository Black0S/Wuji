import Testing
import Foundation

/// L'asset de blocage, relu comme WebKit le relira.
///
/// Ce fichier est écrit à la main et part directement dans le compilateur du moteur. Une
/// virgule oubliée, un point non échappé, un doublon : la liste entière est refusée, sans
/// bruit, et le navigateur ne bloque plus rien. Ces tests sont la seule barrière entre une
/// contribution et ce silence-là.
struct RulesAssetTests {

    /// Le fichier tel qu'il vit dans le dépôt — pas la copie du paquet, qui pourrait dater.
    private static var asset: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // WujiTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // racine
            .appendingPathComponent("Sources/Blocking/Assets/wuji-rules.json")
    }

    /// Les lignes que le chargeur retient : celles qui sont des règles. Les repères de
    /// lecture en `//` sont ignorés ici comme ils le sont à l'exécution.
    private func rules() throws -> [[String: Any]] {
        let text = try String(contentsOf: Self.asset, encoding: .utf8)
        let kept = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            .filter { $0.hasPrefix("{") && $0.hasSuffix("}") }
        let json = "[" + kept.joined(separator: ",") + "]"
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    @Test func chaqueRègleEstUnObjetJSONValide() throws {
        #expect(try rules().count > 100)
    }

    @Test func chaqueRègleADéclencheurEtAction() throws {
        for rule in try rules() {
            let action = try #require(rule["action"] as? [String: Any])
            let trigger = try #require(rule["trigger"] as? [String: Any])
            let type = try #require(action["type"] as? String)
            // Ces trois-là sont les seules que WebKit exécute réellement. `redirect` est
            // acceptée à la compilation puis ignorée — mesuré — donc elle n'a rien à faire ici.
            #expect(["block", "css-display-none", "ignore-previous-rules"].contains(type),
                    "action inattendue : \(type)")
            #expect(trigger["url-filter"] != nil)
        }
    }

    @Test func unMasquageAToujoursUnSélecteur() throws {
        for rule in try rules() {
            guard let action = rule["action"] as? [String: Any],
                  action["type"] as? String == "css-display-none" else { continue }
            let selector = try #require(action["selector"] as? String)
            #expect(!selector.isEmpty)
        }
    }

    @Test func lesPointsDUnDomaineSontÉchappés() throws {
        for rule in try rules() {
            guard let trigger = rule["trigger"] as? [String: Any],
                  let filter = trigger["url-filter"] as? String,
                  filter.hasSuffix("[/:]") else { continue }
            // Un point nu vaut n'importe quel caractère : « ads.com » attraperait « adsXcom ».
            let body = filter.replacingOccurrences(of: #"^[^:]+://+([^:/]+\.)?"#, with: "")
                             .replacingOccurrences(of: "[/:]", with: "")
            #expect(!body.replacingOccurrences(of: #"\."#, with: "").contains("."),
                    "point non échappé dans \(filter)")
        }
    }

    @Test func aucuneRègleNEstÉcriteDeuxFois() throws {
        // La comparaison porte sur la règle entière, pas sur son seul déclencheur : les
        // masquages partagent tous `.*` et ne se distinguent que par leur sélecteur.
        var seen: Set<String> = []
        for rule in try rules() {
            let trigger = (rule["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
            let selector = (rule["action"] as? [String: Any])?["selector"] as? String ?? ""
            let identity = trigger + " " + selector
            #expect(seen.insert(identity).inserted, "règle en double : \(identity)")
        }
    }
}
