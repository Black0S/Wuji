import Testing
import Foundation
@testable import Wuji

/// Les pages internes se dessinent — toutes, dans tous leurs états.
///
/// **C'est le seul endroit du projet où une erreur ne se voit pas en compilant.** Une page
/// interne est du HTML fabriqué par concaténation : une section oubliée dans le `switch`,
/// un état vide qui produit une liste sans lignes, une interpolation qui laisse passer un
/// `Optional(...)` — rien de tout cela n'empêche le code de compiler, et tout se découvre en
/// ouvrant la page. Ces essais l'ouvrent à notre place, à chaque changement.
@MainActor
struct InternalPageTests {

    /// Un état complet, avec du contenu partout : c'est le cas qui exerce le plus de code.
    private func fullState() -> SettingsPage.State {
        SettingsPage.State(
            theme: "auto", searchEngine: "duckduckgo", pageZoom: 1, retention: 90,
            historyCount: 42, siteDataCount: 3,
            siteData: [("exemple.fr", "cookies · stockage"), ("autre.net", "cache")],
            isDefaultBrowser: false, siteZoom: [("exemple.fr", 120)],
            version: "0.4.8", checkUpdates: true, agent: "safari",
            permissions: [("exemple.fr", "camera", true), ("autre.net", "microphone", false)],
            logins: [("exemple.fr", "marie")], passwordsEnabled: true,
            vaultExists: true, vaultUnlocked: true,
            biometryAvailable: true, biometryEnabled: true, biometrySealed: false,
            biometryName: "Touch ID")
    }

    /// Le même, vide de partout : c'est le cas qui casse, parce qu'on l'écrit rarement.
    private func emptyState() -> SettingsPage.State {
        SettingsPage.State(
            theme: "light", searchEngine: "google", pageZoom: 1, retention: 7,
            historyCount: 0, siteDataCount: nil, siteData: [],
            isDefaultBrowser: true, siteZoom: [],
            version: "0.4.8", checkUpdates: false, agent: "chrome",
            permissions: [], logins: [], passwordsEnabled: false,
            vaultExists: false, vaultUnlocked: false,
            biometryAvailable: false, biometryEnabled: false, biometrySealed: false,
            biometryName: "Touch ID")
    }

    @Test func toutesLesSectionsSeDessinent() {
        // `allCases` n'existe pas : on énumère à la main, et **c'est voulu** — ajouter une
        // section sans l'ajouter ici laisse un trou, et ce trou est le défaut qu'on cherche.
        let sections: [SettingsPage.Section] = [
            .features, .appearance, .privacy, .search, .websites,
            .passwords, .zoom, .permissions
        ]
        for section in sections {
            for state in [fullState(), emptyState()] {
                let html = SettingsPage.html(section: section, state: state)
                #expect(html.contains("<main>"))
                #expect(html.contains(section.title))
                // Une interpolation d'optionnel laisse cette trace, et rien d'autre ne la
                // produit : c'est le défaut le plus courant d'une page fabriquée à la main.
                #expect(!html.contains("Optional("))
                #expect(!html.contains("nil</"))
            }
        }
    }

    @Test func chaqueSectionARaisonSurSonAdresse() {
        // L'adresse sert de clé au routeur **et** de marque à la colonne : les deux doivent
        // désigner la même section, sinon la page s'ouvre et rien ne s'y allume.
        let sections: [SettingsPage.Section] = [
            .features, .appearance, .privacy, .search, .websites,
            .passwords, .zoom, .permissions
        ]
        for section in sections {
            let path = section.address.replacingOccurrences(of: "wuji://settings", with: "")
            #expect(SettingsPage.Section.from(path: path) == section)
        }
    }

    @Test func uneAdresseInconnueRetombeSurUneSectionValide() {
        // Un chemin qui n'existe pas ne doit pas rendre une page vide : on préfère la
        // première section à un écran blanc dont personne ne sait d'où il vient.
        let html = SettingsPage.html(section: .from(path: "/nimporte-quoi"),
                                     state: emptyState())
        #expect(html.contains("<main>"))
    }

    @Test func lePageDeBlocageSeDessineVideEtPleine() {
        // Vide **et injoignable** : c'est le cas qui compte, parce qu'une liste vide sans
        // explication se lit « il n'y a rien à bloquer » au lieu de « je n'ai pas pu lire ».
        let muet = BlockingPage.State(catalog: [], installed: [], outdated: [],
                                      activeRules: 0, busy: nil, failure: nil,
                                      unreachable: true, paused: [])
        #expect(BlockingPage.html(state: muet).contains("catalogue injoignable"))

        let liste = RuleList(name: "AdGuard Base filter", source: "AdGuard-Base-filter.txt",
                             version: "2.4", coverage: 96,
                             parts: [.init(file: "Webkit-AdGuard-Base-filter.json",
                                           rules: 123902, bytes: 12566360)])
        let plein = BlockingPage.State(catalog: [liste], installed: [liste.id],
                                       outdated: [liste.id], activeRules: 123902,
                                       busy: nil, failure: nil, unreachable: false,
                                       paused: [])
        let html = BlockingPage.html(state: plein)
        #expect(html.contains("AdGuard Base filter"))
        #expect(html.contains("Mettre à jour"))
        #expect(html.contains("96 % converti"))
        #expect(!html.contains("Optional("))
    }

    @Test func leCorrectifDeLaPageDeBlocageSAnnonce() {
        // **Le mot convenu est le correctif.** Une fonction qui ne renvoie rien vaut
        // `undefined`, que WebKit rend comme « rien » — indistinguable d'un crochet absent :
        // le côté natif rechargeait alors la page qu'il venait de mettre à jour, et la liste
        // remontait en haut à chaque case cochée.
        let état = BlockingPage.State(catalog: [], installed: [], outdated: [],
                                      activeRules: 0, busy: nil, failure: nil,
                                      unreachable: false, paused: [])
        #expect(BlockingPage.patch(état).contains("'wuji-ok'"))
        // Le catalogue ne repasse que lorsqu'on le demande : cent soixante et une lignes
        // n'ont pas à traverser le pont pour une case cochée.
        #expect(!BlockingPage.patch(état).contains("\"catalog\""))
        #expect(BlockingPage.patch(état, catalog: true).contains("\"catalog\""))
    }

    @Test func laPageDesReglesSeDessineVideEtPleine() {
        // Vide, elle explique le geste : une page qui ne montre rien sans dire comment on
        // y met quelque chose se lit comme une fonction cassée.
        let vide = RulesPage.State(mine: [])
        #expect(RulesPage.html(state: vide).contains("Masquer un élément"))
        #expect(RulesPage.tally(vide) == "aucune règle posée")

        let état = RulesPage.State(mine: [
            .init(host: "exemple.fr", selector: "#pub"),
            .init(host: "exemple.fr", selector: ".banniere"),
            .init(host: "autre.fr", selector: "#encart")
        ])
        let html = RulesPage.html(state: état)
        // Rangées par site : on se souvient du site, jamais du sélecteur.
        #expect(html.contains("exemple.fr"))
        #expect(html.contains("#pub"))
        #expect(html.contains("Tout retirer"))
        #expect(RulesPage.tally(état) == "3 éléments masqués sur 2 sites")
        #expect(!html.contains("Optional("))
        #expect(RulesPage.patch(état).contains("'wuji-ok'"))
    }

    @Test func laPageDesScriptsSuitSonInterrupteur() {
        #expect(ScriptsPage.html(scripts: [], isEnabled: true).contains("exécutés sur cette machine"))
        #expect(ScriptsPage.html(scripts: [], isEnabled: false).contains("tous éteints"))
    }
}
