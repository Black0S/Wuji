import Testing
import Foundation
@testable import Wuji

/// Ce que le sélecteur d'éléments produit : **une règle WebKit, pas un script**.
///
/// La traduction est le seul endroit où une erreur ne se voit pas : une règle mal formée
/// est refusée en bloc par le compilateur de WebKit, qui ne dit pas laquelle ni pourquoi —
/// et l'on croit alors que le masquage « ne marche pas ».
@MainActor
struct UserRulesTests {

    private func encoded(_ rules: [UserRules.Rule]) -> [[String: Any]] {
        guard let json = UserRules.encode(rules),
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [[String: Any]] else { return [] }
        return list
    }

    @Test func uneRègleEstUnDéclencheurEtUneAction() throws {
        let entries = encoded([UserRules.Rule(host: "exemple.fr", selector: "#pub")])
        let entry = try #require(entries.first)
        let trigger = try #require(entry["trigger"] as? [String: Any])
        let action = try #require(entry["action"] as? [String: Any])

        // **L'étoile devant le domaine couvre les sous-domaines.** Sans elle, une règle
        // posée sur `exemple.fr` ne vaudrait pas sur `www.exemple.fr` — et il faudrait la
        // reposer sur chaque sous-domaine, ce que personne ne fera.
        #expect(trigger["if-domain"] as? [String] == ["*exemple.fr"])
        // C'est le domaine qui restreint, pas l'adresse : un `url-filter` plus étroit
        // manquerait les ressources servies depuis un chemin qu'on n'a pas prévu.
        #expect(trigger["url-filter"] as? String == ".*")
        #expect(action["type"] as? String == "css-display-none")
        #expect(action["selector"] as? String == "#pub")
    }

    @Test func unSélecteurComposéTraverseIntact() throws {
        let entries = encoded([UserRules.Rule(host: "e.fr", selector: ".banniere > div")])
        let action = try #require(entries.first?["action"] as? [String: Any])
        #expect(action["selector"] as? String == ".banniere > div")
    }

    @Test func aucuneRègleDonneUneListeVide() {
        #expect(UserRules.encode([]) == "[]")
    }

    @Test func lHôteEstRéduitAuSite() {
        // `www` et `m` servent la même page à deux adresses : une règle posée sur l'une
        // doit valoir sur l'autre. C'est la liste des suffixes publics qui dit où s'arrête
        // « ce site », pas un point compté à rebours.
        #expect(UserRules.registrable("www.exemple.fr") == "exemple.fr")
        #expect(UserRules.registrable("a.b.exemple.co.uk") == "exemple.co.uk")
    }

    @Test func lIdentitéDUneRègleEstSonCoupleHôteSélecteur() {
        let a = UserRules.Rule(host: "e.fr", selector: "#a")
        // La date de création n'entre pas dans l'identité : poser deux fois la même règle
        // doit être reconnu comme un doublon, pas comme une seconde règle.
        #expect(a.id == UserRules.Rule(host: "e.fr", selector: "#a").id)
        #expect(a.id != UserRules.Rule(host: "e.fr", selector: "#b").id)
        #expect(a.id != UserRules.Rule(host: "autre.fr", selector: "#a").id)
    }
}
