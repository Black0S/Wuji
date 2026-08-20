import Testing
@testable import Wuji

/// La page des listes de règles.
///
/// Elle affiche un interrupteur par liste livrée, et c'est tout son sujet : un
/// interrupteur qui n'existe pas se cherche longtemps, un interrupteur qui ne pilote rien
/// se croit sur parole. Ces tests vérifient les deux — que chaque liste du catalogue
/// arrive dans la page, et qu'aucune ne s'affiche allumée quand le blocage est éteint.
@MainActor
struct BlockingPageTests {

    private let listes = [
        AdBlockPage.List(id: "tracking", name: "Mouchards",
                         summary: "Rien ici ne sert à afficher la page.", count: 72, isOn: true),
        AdBlockPage.List(id: "social", name: "Réseaux sociaux",
                         summary: "Les boutons qui rapportent votre visite.", count: 15, isOn: false)
    ]

    private func page(isBlockingOn: Bool = true) -> String {
        AdBlockPage.html(section: .lists, lists: listes, isBlockingOn: isBlockingOn,
                         userRules: [], exceptions: [])
    }

    @Test func lAdresseMèneÀLaPage() {
        #expect(AdBlockPage.Section.from(path: "/lists") == .lists)
        #expect(AdBlockPage.Section.lists.address == "wuji://ad-block/lists")
        // Le sommaire est la seule façon d'y arriver : sans l'entrée, la page existe et
        // personne ne la trouve.
        #expect(InternalShell.groups.contains { _, items in
            items.contains { $0.address == AdBlockPage.Section.lists.address }
        })
    }

    @Test func chaqueListeADeSaLigne() {
        let html = page()
        for liste in listes {
            #expect(html.contains(#"data-id="\#(liste.id)""#))
            #expect(html.contains(liste.name))
            #expect(html.contains("\(liste.count) règles"))
        }
    }

    @Test func lÉtatDeLInterrupteurSuitLaListe() {
        let html = page()
        // Une seule allumée sur les deux : le compte de l'entête ne porte que sur elle.
        #expect(html.contains("1 liste active, 72 règles"))
    }

    // MARK: - Mes règles

    private func mesRègles(_ rules: [String]) -> String {
        AdBlockPage.html(section: .myRules, lists: [], isBlockingOn: true,
                         userRules: rules, exceptions: [])
    }

    private var deuxSites: [String] {
        [WebKitRule.hide(selector: "#pub", on: "ledauphine.com"),
         WebKitRule.hide(selector: "#pub2", on: "ledauphine.com"),
         WebKitRule.hide(selector: "#offer", on: "youtube.com")]
    }

    @Test func onChoisitLeSiteQuOnVeutVoir() {
        let html = mesRègles(deuxSites)
        #expect(html.contains(#"<select id="site">"#))
        // Le compte par site est dans le choix : sans lui, on ouvre un paquet pour
        // découvrir ce qu'il pèse.
        #expect(html.contains("ledauphine.com · 2"))
        #expect(html.contains("youtube.com · 1"))
        #expect(html.contains("Tous les sites · 3"))
        // Le filtre a besoin de savoir à quel site appartient chaque paquet.
        #expect(html.contains(#"<section data-site="ledauphine.com">"#))
    }

    @Test func unSeulSiteNaPasBesoinDeChoix() {
        // Un menu déroulant à une entrée est un contrôle mort : il ne change rien.
        let html = mesRègles([WebKitRule.hide(selector: "#pub", on: "ledauphine.com")])
        #expect(!html.contains(#"<select id="site">"#))
    }

    @Test func chaqueRègleSeCorrige() {
        let html = mesRègles(deuxSites)
        #expect(html.contains(#"data-action="edit""#))
        #expect(html.contains(#"data-action="unrule""#))
    }

    @Test func blocageÉteintAucunInterrupteurNEstOffert() {
        // Ils ne piloteraient rien : un contrôle mort est pire qu'un contrôle absent.
        let html = page(isBlockingOn: false)
        #expect(!html.contains("data-id="))
        #expect(html.contains("Le blocage est éteint"))
    }
}
