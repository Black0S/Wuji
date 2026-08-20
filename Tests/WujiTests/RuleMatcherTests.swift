import Testing
import Foundation
@testable import Wuji

/// À qui attribuer une ressource absente.
///
/// WebKit ne dit pas ce qu'il bloque : le journal ne voyait que des trous, sans pouvoir
/// distinguer une régie qu'on a arrêtée d'un serveur en panne. Les règles étant à nous, on
/// peut les relire — et c'est cette relecture qui est testée ici, parce qu'une attribution
/// fausse serait pire que pas d'attribution du tout : elle accuserait une liste à sa place.
@MainActor
struct RuleMatcherTests {

    private func matcher(_ groups: [(list: String, rules: [String])]) -> RuleMatcher {
        let matcher = RuleMatcher()
        matcher.load(groups)
        return matcher
    }

    private let mouchard = WebKitRule.block(domain: "bat.bing.com")
    private let pub = WebKitRule.block(domain: "doubleclick.net")

    private func url(_ address: String) -> URL { URL(string: address)! }

    @Test func laListeQuiViseLAdresseEstNommée() {
        let m = matcher([("Mouchards", [mouchard]), ("Publicité", [pub])])
        #expect(m.match(url("https://bat.bing.com/bat.js"), on: "lemonde.fr")?.list == "Mouchards")
        #expect(m.match(url("https://ad.doubleclick.net/x"), on: "lemonde.fr")?.list == "Publicité")
    }

    @Test func laRègleExacteEstRendue() {
        // On montre ce sur quoi l'attribution repose : nommer une liste sans montrer la
        // règle demande d'être cru.
        let m = matcher([("Mouchards", [mouchard])])
        #expect(m.match(url("https://bat.bing.com/bat.js"), on: "lemonde.fr")?.rule == mouchard)
    }

    @Test func lesSousDomainesSontVisésEtLesVoisinsNon() {
        let m = matcher([("Publicité", [WebKitRule.block(domain: "doubleclick.net")])])
        #expect(m.match(url("https://stats.g.doubleclick.net/x"), on: "site.fr") != nil)
        // Le crochet final du motif : « doubleclick.net » ne doit pas attraper
        // « doubleclick.net.pirate.com ».
        #expect(m.match(url("https://doubleclick.net.pirate.com/x"), on: "site.fr") == nil)
    }

    @Test func cequAucuneRègleNeViseNestPasAttribué() {
        // **Le cas le plus utile du journal** : l'absence ne vient pas de nous.
        let m = matcher([("Mouchards", [mouchard])])
        #expect(m.match(url("https://cdn.lemonde.fr/photo.jpg"), on: "lemonde.fr") == nil)
    }

    @Test func unMasquageNeFaitDisparaîtreAucuneRequête() {
        // Une règle cosmétique cache un élément, elle n'empêche rien d'arriver :
        // l'attribuer accuserait à tort.
        let m = matcher([("Habillage", [WebKitRule.hide(selector: "#pub", on: "lemonde.fr")])])
        #expect(m.match(url("https://lemonde.fr/pub.js"), on: "lemonde.fr") == nil)
    }

    @Test func uneRègleDeSiteNeVautQueSurSonSite() {
        // `if-domain` : la règle existe, mais pas ici. L'attribuer ferait croire à un
        // blocage qui n'a pas eu lieu.
        let règle = #"{"action":{"type":"block"},"trigger":{"url-filter":"tracker","if-domain":["*lemonde.fr"]}}"#
        let m = matcher([("Mes règles", [règle])])
        #expect(m.match(url("https://x.com/tracker.js"), on: "www.lemonde.fr") != nil)
        #expect(m.match(url("https://x.com/tracker.js"), on: "figaro.fr") == nil)
    }

    @Test func laCasseNeChangeRien() {
        // WebKit ignore la casse sauf mention contraire : un domaine en majuscules dans la
        // page échapperait sinon au relevé.
        let m = matcher([("Mouchards", [mouchard])])
        #expect(m.match(url("https://BAT.BING.COM/bat.js"), on: "lemonde.fr") != nil)
    }

    @Test func unePortéeCouvreLeDomaineEtSesSousDomaines() {
        #expect(RuleMatcher.covers(["*lemonde.fr"], "www.lemonde.fr"))
        #expect(RuleMatcher.covers(["*lemonde.fr"], "lemonde.fr"))
        #expect(!RuleMatcher.covers(["*lemonde.fr"], "fauxlemonde.fr"))
        #expect(!RuleMatcher.covers(["*lemonde.fr"], nil))
    }

    @Test func laNatureDeLaRessourceVientDeLaBalise() {
        #expect(BlockingLog.Resource(tag: "SCRIPT") == .script)
        #expect(BlockingLog.Resource(tag: "img") == .image)
        #expect(BlockingLog.Resource(tag: "IFRAME") == .frame)
        #expect(BlockingLog.Resource(tag: nil) == .other)
    }
}
