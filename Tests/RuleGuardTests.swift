import Testing
import Foundation
@testable import Wuji

/// La garde qui s'interpose entre une liste et le compilateur de WebKit.
///
/// **Deux dangers opposés, mesurés sur ce système.** Une clé de déclencheur inconnue est
/// *ignorée* : une règle dont c'est justement cette clé qui restreint devient « bloquer
/// tout ». Une valeur inconnue, elle, fait refuser le fichier **entier** — des dizaines de
/// milliers de règles perdues pour une. La garde répond aux deux en écartant la règle.
@MainActor
struct RuleGuardTests {

    private func json(_ règles: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: règles), encoding: .utf8)!
    }

    @Test func uneCleInconnueEcarteLaRegleAuLieuDeLElargir() throws {
        // Le cas exact du rapport : `url-filter` est volontairement large, et c'est la
        // dernière clé qui restreint. L'ignorer donne « bloquer tous les scripts tiers ».
        let texte = json([["trigger": ["url-filter": ".*", "resource-type": ["script"],
                                       "load-type": ["third-party"], "si-jamais-vu": ["x"]],
                           "action": ["type": "block"]]])
        #expect(!RuleGuard.onlyKnownKeys(texte))
        let propre = try #require(RuleGuard.filtered(texte))
        #expect(propre.dropped == 1)
        #expect(propre.json == "[]")
    }

    @Test func lesClesDeSafari26SontConnues() {
        // `if-frame-url` et `request-method` existent et sont appliquées par ce WebKit :
        // les écarter perdrait des règles justes.
        let texte = json([["trigger": ["url-filter": ".*", "resource-type": ["script"],
                                       "load-type": ["third-party"],
                                       "if-frame-url": ["^https?://exemple\\."]],
                           "action": ["type": "block"]],
                          ["trigger": ["url-filter": ".*", "request-method": "post",
                                       "unless-frame-url": ["^https?://a\\."]],
                           "action": ["type": "block"]]])
        #expect(RuleGuard.onlyKnownKeys(texte))
        #expect(RuleGuard.filtered(texte) == nil)
    }

    @Test func lesValeursQuiFontTomberLeFichierSontEcartees() throws {
        // Chacune de ces trois formes fait refuser le fichier entier par WebKit — mesuré.
        for règle in [["trigger": ["url-filter": ".*", "resource-type": ["xmlhttprequest"]],
                       "action": ["type": "block"]],
                      ["trigger": ["url-filter": ".*", "if-domain": ["a.fr"],
                                   "if-frame-url": ["^https?://b\\."]],
                       "action": ["type": "block"]],
                      ["trigger": ["url-filter": ".*", "request-method": ["post"]],
                       "action": ["type": "block"]]] {
            let propre = try #require(RuleGuard.filtered(json([règle])))
            #expect(propre.dropped == 1)
        }
    }

    @Test func uneListeSaineNEstPasTouchee() {
        let texte = json([["trigger": ["url-filter": "pub\\.js", "resource-type": ["script"],
                                       "load-context": ["child-frame"], "request-method": "get"],
                           "action": ["type": "block"]],
                          ["trigger": ["url-filter": ".*", "if-domain": ["exemple.fr"]],
                           "action": ["type": "css-display-none", "selector": "#pub"]]])
        #expect(RuleGuard.onlyKnownKeys(texte))
        // Rien à refaire : on rend `nil` plutôt qu'une copie identique, et le fichier part
        // tel quel au compilateur.
        #expect(RuleGuard.filtered(texte) == nil)
    }

    @Test func leBalayageNeConstruitRien() {
        // Un seul passage d'octets : toute chaîne suivie de deux-points est une clé. Six
        // millisecondes par mégaoctet, là où une lecture complète en coûte des centaines.
        let texte = json([["trigger": ["url-filter": "a:b", "if-domain": ["x.fr"]],
                           "action": ["type": "block"]]])
        let clés = RuleGuard.keys(in: texte)
        #expect(clés == ["trigger", "url-filter", "if-domain", "action", "type"])
        // `a:b` est une valeur, pas une clé : les deux-points qu'elle contient ne doivent
        // pas la transformer en nom de champ.
        #expect(!clés.contains("a:b"))
    }
}
