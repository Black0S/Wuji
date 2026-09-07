import Testing
import Foundation
@testable import Wuji

/// Les règles à injection : la portée, la sélection, et ce qu'on refuse d'exécuter.
///
/// **C'est le seul module de Wuji qui exécute ce qu'une liste demande.** Il ne le fait que
/// pour des primitives nommées, écrites ici ; le reste de la vérification tient à ce que la
/// bonne règle parte au bon site, et à ce qu'une exception l'annule vraiment. Une erreur ici
/// ne se voit pas en compilant : elle se voit sur un site cassé, des mois plus tard.
@MainActor
struct ExtendedRulesTests {

    // MARK: - La portée d'un domaine

    @Test func unDomaineCouvreSesSousDomaines() {
        let candidats = DomainScope.candidates(of: "poczta.interia.pl")
        #expect(candidats.contains("poczta.interia.pl"))
        #expect(candidats.contains("interia.pl"))
        // `www.` est traité comme le site lui-même : les listes écrivent l'un pour l'autre.
        #expect(DomainScope.candidates(of: "www.exemple.fr").contains("exemple.fr"))

        let sur = { (host: String) in
            DomainScope.matches(domains: ["interia.pl"], excluded: ["poczta.interia.pl"],
                                host: host, candidates: Set(DomainScope.candidates(of: host)))
        }
        #expect(sur("interia.pl"))
        #expect(sur("www.interia.pl"))
        // L'exclusion l'emporte : c'est à cela qu'elle sert.
        #expect(!sur("poczta.interia.pl"))
        #expect(!sur("autre.fr"))

        // Sans domaine, la règle vaut partout — et l'exclusion vaut encore.
        #expect(DomainScope.matches(domains: [], excluded: [], host: "n-importe.fr",
                                    candidates: Set(DomainScope.candidates(of: "n-importe.fr"))))
    }

    // MARK: - Ce que WebKit sait faire lui-même

    @Test func unSelecteurNatifNaPasBesoinDuMoteur() {
        // Mesuré sur le compilateur du système : ceux-là passent en règle compilée.
        for natif in ["#pub", "div.a > span", "div:has(> img)", "li:nth-child(2n)",
                      ":is(.a, .b) span", "div:not(.garder)", "a[href^=\"https://ads\"]"] {
            #expect(ExtendedRules.isNativeSelector(natif), "\(natif) devrait être natif")
        }
        // Ceux-là sont refusés par WebKit, et le refus emporte la liste entière.
        for étendu in ["div:contains(Pub)", "div:has-text(Pub)", "img:upward(3)",
                       ":xpath(//div)", "p:matches-css(width: 300px)",
                       "div:has(span:contains(x))"] {
            #expect(!ExtendedRules.isNativeSelector(étendu), "\(étendu) demande le moteur")
        }
    }

    // MARK: - Les noms des primitives

    @Test func lesPrimitivesSeReconnaissentSousTousLeursNoms() {
        // Les listes écrivent le même geste sous cinq noms : l'abréviation d'uBlock, le
        // nom complet d'AdGuard, l'emprunt préfixé `ubo-`. Sans cette table, la moitié des
        // règles tomberait comme « inconnue » alors qu'on sait les appliquer.
        #expect(Scriptlets.canonical("aopr") == "abort-on-property-read")
        #expect(Scriptlets.canonical("ubo-aopr.js") == "abort-on-property-read")
        #expect(Scriptlets.canonical("acs") == "abort-current-inline-script")
        #expect(Scriptlets.canonical("ubo-set-cookie") == "set-cookie")
        #expect(Scriptlets.canonical("trusted-set-cookie") == "set-cookie")
        #expect(Scriptlets.canonical("set") == "set-constant")
        #expect(Scriptlets.canonical("nostif") == "prevent-setTimeout")
        #expect(Scriptlets.canonical("ra") == "remove-attr")

        #expect(Scriptlets.isSupported("set-constant"))
        // Un nom qu'on n'implémente pas n'est pas envoyé à la page : mieux vaut ne rien
        // faire que poser un appel que rien ne recevra.
        #expect(!Scriptlets.isSupported("primitive-qui-nexiste-pas"))
        #expect(!Scriptlets.script(for: [["set-constant", "a.b", "false"]]).isEmpty)
    }

    // MARK: - Ce que reçoit une page

    private func magasin(_ règles: ExtendedRules) -> ExtendedStore {
        let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wuji-essai-\(UUID().uuidString)", isDirectory: true)
        let magasin = ExtendedStore(directory: dossier)
        magasin.load(règles)
        return magasin
    }

    @Test func laFeuilleEtLeMoteurSeSeparentSelonLeSelecteur() {
        let règles = ExtendedRules(
            styles: [.init(domains: ["exemple.fr"], selector: ".pub",
                           declarations: "display: none !important"),
                     .init(domains: ["exemple.fr"], selector: ".fantôme",
                           declarations: "remove: true")],
            procedural: [.init(domains: ["exemple.fr"], selector: "#natif.simple"),
                         .init(domains: ["exemple.fr"], selector: "div:contains(Pub)")],
            scriptlets: [.init(domains: ["exemple.fr"], name: "ubo-aopr", args: ["a.b"])])
        let p = magasin(règles).payload(for: "exemple.fr")

        // Un sélecteur que WebKit résout repart en feuille, pas dans le moteur : sinon un
        // observateur de mutations tournerait pour une ligne de CSS.
        #expect(p.css.contains(".pub { display: none !important }"))
        #expect(p.css.contains("#natif.simple { display: none !important }"))
        #expect(p.procedural == ["div:contains(Pub)"])
        #expect(p.removals == [".fantôme"])
        #expect(p.scriptlets == [["abort-on-property-read", "a.b"]])

        // Un site qu'aucune règle ne nomme ne reçoit rien du tout.
        #expect(magasin(règles).payload(for: "autre.fr").isEmpty)
    }

    @Test func uneExceptionAnnuleLaRegleMemeVenueDuneAutreListe() {
        let règles = ExtendedRules(
            styles: [.init(domains: ["exemple.fr"], selector: ".pub", declarations: "display: none"),
                     .init(domains: ["exemple.fr"], selector: ".pub", declarations: "display: none",
                           exception: true)],
            procedural: [.init(domains: ["exemple.fr"], selector: "div:contains(A)"),
                         .init(domains: ["exemple.fr"], selector: "div:contains(A)", exception: true)],
            scriptlets: [.init(domains: ["exemple.fr"], name: "set-constant", args: ["a", "false"]),
                         .init(domains: ["exemple.fr"], name: "set", args: [], exception: true)])
        let p = magasin(règles).payload(for: "exemple.fr")
        #expect(p.css.isEmpty)
        #expect(p.procedural.isEmpty)
        // L'exception vise `set`, qui est le même geste que `set-constant` sous un autre
        // nom : sans la table des alias, elle n'annulerait rien.
        #expect(p.scriptlets.isEmpty)
    }

    @Test func uneAnnexeIncompleteNeFaitPasTomberLaListe() {
        // **Swift ne se sert pas des valeurs par défaut quand une clé manque : il refuse.**
        // Une annexe sans `procedural`, ou une entrée sans `excluded`, aurait donc fait
        // tomber la liste entière — silencieusement, et l'on aurait cherché longtemps
        // pourquoi ses règles n'arrivaient pas.
        let minimal = #"{"styles":[{"selector":".a","declarations":"display:none"}]}"#
        let lu = ExtendedRules.decode(Data(minimal.utf8))
        #expect(lu?.styles.count == 1)
        #expect(lu?.styles.first?.domains.isEmpty == true)
        #expect(lu?.styles.first?.exception == false)

        #expect(ExtendedRules.decode(Data("{}".utf8))?.isEmpty == true)
        // Ce qui n'est pas du JSON reste refusé : la liste garde alors ses règles compilées,
        // qui sont l'essentiel.
        #expect(ExtendedRules.decode(Data("pas du json".utf8)) == nil)
    }

    @Test func leCacheSeRelitSansReseau() throws {
        let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wuji-cache-\(UUID().uuidString)", isDirectory: true)
        let magasin = ExtendedStore(directory: dossier)
        let voulu = ExtendedStore.Wanted(id: "EasyList.txt", file: "Extended-EasyList.json",
                                         cache: ExtendedStore.cacheName("EasyList.txt", "2.1"))

        // Rien sur le disque : il faut aller chercher, et le magasin le dit.
        #expect(!magasin.loadCached([voulu]))

        let contenu = #"{"scriptlets":[{"domains":["exemple.fr"],"name":"aopr","args":["a.b"]}]}"#
        try Data(contenu.utf8).write(to: dossier.appendingPathComponent(voulu.cache))
        #expect(magasin.loadCached([voulu]))
        #expect(magasin.payload(for: "exemple.fr").scriptlets
                == [["abort-on-property-read", "a.b"]])

        // Une liste sans annexe ne manque jamais : elle n'a rien à charger.
        let sansAnnexe = ExtendedStore.Wanted(id: "Autre.txt", file: nil, cache: "Autre.txt@1.json")
        #expect(magasin.loadCached([voulu, sansAnnexe]))
        try? FileManager.default.removeItem(at: dossier)
    }

    @Test func leMoteurNePartQueSilADuTravail() {
        var feuille = ExtendedStore.Payload()
        feuille.css = ".pub { display: none }"
        let simple = CosmeticEngine.script(for: feuille)
        #expect(simple != nil)
        // Douze kilo-octets et un observateur pour quatre lignes de CSS, c'est exactement
        // ce qu'on reproche à un bloqueur d'extension.
        #expect(simple?.contains("MutationObserver") == false)

        var retrait = feuille
        retrait.removals = [".fantôme"]
        let léger = CosmeticEngine.script(for: retrait)
        #expect(léger?.contains("querySelectorAll") == true)
        #expect((léger?.count ?? .max) < 3000)

        var complet = feuille
        complet.procedural = ["div:contains(x)"]
        let moteur = CosmeticEngine.script(for: complet)
        #expect(moteur?.contains("appliquerOp") == true)

        #expect(CosmeticEngine.script(for: ExtendedStore.Payload()) == nil)
    }
}
