import Testing
import Foundation
@testable import Wuji

/// Les règles que Wuji écrit lui-même.
///
/// Elles partent directement dans le compilateur de WebKit : une virgule de travers et
/// c'est **toute** la liste qui est refusée, silencieusement, avec un navigateur qui ne
/// bloque plus rien et rien pour le dire. D'où ces vérifications.
@MainActor
struct WebKitRuleTests {

    private func decoded(_ rule: String) throws -> [String: Any] {
        let data = Data(rule.utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func masquerProduitDuJSONValide() throws {
        let rule = WebKitRule.hide(selector: ".promo", on: "exemple.com")
        let object = try decoded(rule)
        let action = try #require(object["action"] as? [String: Any])
        #expect(action["type"] as? String == "css-display-none")
        #expect(action["selector"] as? String == ".promo")
    }

    @Test func bloquerÉchappeLesPointsDuDomaine() throws {
        let rule = WebKitRule.block(domain: "exemple.com")
        let object = try decoded(rule)
        let trigger = try #require(object["trigger"] as? [String: Any])
        let filter = try #require(trigger["url-filter"] as? String)
        // Sans échappement, le point d'une expression régulière vaut n'importe quel
        // caractère : « exemple.com » attraperait « exempleXcom ».
        #expect(filter.contains(#"exemple\.com"#))
        // Et le crochet final empêche « exemple.com » d'attraper « exemple.com.pirate.net ».
        #expect(filter.hasSuffix("[/:]"))
    }

    @Test func uneExceptionAnnuleCeQuiPrécède() throws {
        let object = try decoded(WebKitRule.exception(for: "exemple.com"))
        let action = try #require(object["action"] as? [String: Any])
        #expect(action["type"] as? String == "ignore-previous-rules")
    }

    @Test func lesGuillemetsDUnSélecteurNeCassentPasLeJSON() throws {
        let rule = WebKitRule.hide(selector: #"[data-ad="oui"]"#, on: "exemple.com")
        let object = try decoded(rule)
        let action = try #require(object["action"] as? [String: Any])
        #expect(action["selector"] as? String == #"[data-ad="oui"]"#)
    }

    @Test func laDescriptionDitCeQueLaRègleFait() {
        #expect(WebKitRule.describe(WebKitRule.hide(selector: ".pub", on: "exemple.com"))
                    .contains(".pub"))
        #expect(WebKitRule.describe(WebKitRule.block(domain: "traqueur.com"))
                    .contains("traqueur.com"))
        #expect(WebKitRule.describe(WebKitRule.exception(for: "exemple.com"))
                    .contains("exemple.com"))
    }

    @Test func leSiteDUneRègleEstCeluiQuElleVise() {
        #expect(WebKitRule.site(of: WebKitRule.hide(selector: ".pub", on: "exemple.com"))
                == "exemple.com")
        // Une règle qui ne vise aucun site n'en invente pas un : « Mes règles » la range
        // sous « Partout », et c'est cette valeur nulle qui le décide.
        #expect(WebKitRule.site(of: WebKitRule.block(domain: "traqueur.com")) == nil)
    }
}
