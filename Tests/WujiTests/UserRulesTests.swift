import Testing
import Foundation
@testable import Wuji

/// Les règles écrites à la main.
///
/// Elles partent dans le même compilateur que les listes livrées, et **une seule règle mal
/// formée fait refuser toute la liste** — sans bruit, au prochain démarrage. C'était
/// supportable tant que seul le sélecteur d'élément les écrivait ; depuis qu'on peut les
/// taper et les corriger, il faut juger avant d'écrire.
@MainActor
struct UserRulesTests {

    private func temporaire() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuji-test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Le point est échappé **pour JSON** — donc deux barres obliques inverses dans le
    // texte du fichier. Une seule, et c'est une séquence d'échappement que JSON ne connaît
    // pas : la règle entière est refusée. Ce test l'a appris en échouant.
    private let bloque = #"{"action":{"type":"block"},"trigger":{"url-filter":"^https://ads\\.com"}}"#
    private let masque = WebKitRule.hide(selector: "#pub", on: "exemple.com")

    // MARK: - Ce qu'on accepte

    @Test func uneRègleBienForméePasse() {
        #expect(WebKitRule.isValid(bloque))
        #expect(WebKitRule.isValid(masque))
        #expect(WebKitRule.isValid(WebKitRule.exception(for: "exemple.com")))
    }

    @Test func ceQuiNEstPasDuJSONEstRefusé() {
        #expect(!WebKitRule.isValid("||exemple.com^"))          // la syntaxe Adblock
        #expect(!WebKitRule.isValid(""))
        #expect(!WebKitRule.isValid(#"{"action":{"type":"block"}"#))  // accolade manquante
    }

    @Test func ilFautUneActionQueLeMoteurExécute() {
        // `redirect` compile puis est ignorée — mesuré. L'accepter promettrait ce qui
        // n'arrive pas.
        #expect(!WebKitRule.isValid(
            #"{"action":{"type":"redirect","url":"about:blank"},"trigger":{"url-filter":".*"}}"#))
        #expect(!WebKitRule.isValid(#"{"trigger":{"url-filter":".*"}}"#))
    }

    @Test func ilFautUnDéclencheurAvecSonMotif() {
        #expect(!WebKitRule.isValid(#"{"action":{"type":"block"},"trigger":{}}"#))
        #expect(!WebKitRule.isValid(#"{"action":{"type":"block"}}"#))
    }

    @Test func unMasquageSansSélecteurNeMasqueRien() {
        #expect(!WebKitRule.isValid(
            #"{"action":{"type":"css-display-none","selector":""},"trigger":{"url-filter":".*"}}"#))
        #expect(!WebKitRule.isValid(
            #"{"action":{"type":"css-display-none"},"trigger":{"url-filter":".*"}}"#))
    }

    // MARK: - La correction

    @Test func corrigerUneRègleNeLaDéplacePas() {
        // Retirer puis rajouter l'aurait renvoyée en fin de liste : on corrige une règle,
        // on ne la réécrit pas, et une liste qui se réordonne ne se relit plus.
        let rules = UserRules(directory: temporaire())
        rules.add(bloque)
        rules.add(masque)
        let corrigé = WebKitRule.hide(selector: "#pub-2", on: "exemple.com")

        #expect(rules.replace(bloque, with: corrigé))
        #expect(rules.rules.first == corrigé)
        #expect(rules.rules.count == 2)
    }

    @Test func onNeCorrigePasCeQuiNExistePlus() {
        let rules = UserRules(directory: temporaire())
        rules.add(bloque)
        #expect(!rules.replace(masque, with: bloque))
        #expect(!rules.replace(bloque, with: "   "))
    }

    @Test func uneCorrectionNeFaitPasUnDoublon() {
        let rules = UserRules(directory: temporaire())
        rules.add(bloque)
        rules.add(masque)
        #expect(!rules.replace(bloque, with: masque))
        #expect(rules.rules.count == 2)
    }

    @Test func laCorrectionSurvitÀUneNouvelleInstance() {
        let dossier = temporaire()
        let rules = UserRules(directory: dossier)
        rules.add(bloque)
        let corrigé = WebKitRule.block(domain: "autre.com")
        rules.replace(bloque, with: corrigé)

        #expect(UserRules(directory: dossier).rules == [corrigé])
    }
}
