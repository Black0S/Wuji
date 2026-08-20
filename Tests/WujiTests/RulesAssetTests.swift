import Testing
import Foundation
@testable import Wuji

/// Les listes de blocage, relues comme WebKit les relira.
///
/// Ces fichiers sont écrits à la main et partent directement dans le compilateur du
/// moteur. Une virgule oubliée, un point non échappé, un doublon : la liste entière est
/// refusée, sans bruit, et cette famille-là ne bloque plus rien. Ces tests sont la seule
/// barrière entre une contribution et ce silence.
///
/// Depuis le découpage en plusieurs listes, ils vérifient aussi ce qu'aucune liste seule
/// ne peut vérifier : que le catalogue annoncé dans les réglages existe sur le disque, et
/// qu'une même règle n'est pas écrite dans deux familles à la fois.
@MainActor
struct RulesAssetTests {

    /// Les fichiers tels qu'ils vivent dans le dépôt — pas la copie du paquet, qui
    /// pourrait dater.
    private static func asset(_ file: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // WujiTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // racine
            .appendingPathComponent("Sources/Blocking/Assets/\(file).json")
    }

    /// Les lignes que le chargeur retient — le tri est celui de l'application, appelé ici
    /// plutôt que réécrit : un test qui recopie le code qu'il vérifie ne vérifie rien.
    private func rules(of list: RuleList) throws -> [[String: Any]] {
        let text = try String(contentsOf: Self.asset(list.file), encoding: .utf8)
        let json = "[" + ContentBlocker.rules(in: text).joined(separator: ",") + "]"
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    /// Toutes les règles livrées, toutes listes confondues.
    private func rules() throws -> [[String: Any]] {
        try RuleList.all.flatMap { try rules(of: $0) }
    }

    @Test func chaqueListeDuCatalogueExiste() throws {
        for list in RuleList.all {
            #expect(FileManager.default.fileExists(atPath: Self.asset(list.file).path),
                    "liste annoncée mais absente : \(list.file).json")
            // Une liste vide serait un interrupteur qui ne pilote rien.
            #expect(try rules(of: list).count > 1, "liste vide : \(list.id)")
        }
    }

    @Test func lesIdentifiantsSontUniques() {
        #expect(Set(RuleList.all.map(\.id)).count == RuleList.all.count)
        // L'identifiant nomme la liste compilée dans le magasin de WebKit : deux listes de
        // même nom s'écraseraient l'une l'autre sans rien dire.
        #expect(Set(RuleList.all.map(\.identifier)).count == RuleList.all.count)
    }

    @Test func chaqueListeSeDécritEnUnePhrase() {
        for list in RuleList.all {
            #expect(!list.name.isEmpty)
            // Sans phrase, l'interrupteur demande de deviner ce qu'on éteint.
            #expect(list.summary.count > 40, "description trop courte : \(list.id)")
        }
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
        //
        // Et elle porte sur **toutes les listes à la fois** : un domaine recopié dans deux
        // familles serait bloqué même après en avoir éteint une, ce qui ferait mentir
        // l'interrupteur.
        var seen: [String: String] = [:]
        for list in RuleList.all {
            for rule in try rules(of: list) {
                let trigger = (rule["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
                let selector = (rule["action"] as? [String: Any])?["selector"] as? String ?? ""
                let identity = trigger + " " + selector
                #expect(seen[identity] == nil,
                        "règle en double : \(identity) — \(seen[identity] ?? "") et \(list.id)")
                seen[identity] = list.id
            }
        }
    }
}
