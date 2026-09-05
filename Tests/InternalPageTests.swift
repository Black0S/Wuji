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
            version: "0.1.5", checkUpdates: true, agent: "safari",
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
            version: "0.1.5", checkUpdates: false, agent: "chrome",
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

    @Test func laListeDesExtensionsSeDessineVideEtPleine() {
        #expect(ExtensionsPage.html(entries: []).contains("Aucune extension"))

        var entry = ExtensionHost.Entry(id: "a.b.c", name: "Essai",
                                        origin: "Extension de « Essai »")
        entry.version = "1.0"
        entry.hosts = ["*://exemple.fr/*"]
        entry.permissions = ["storage"]
        let html = ExtensionsPage.html(entries: [entry])
        #expect(html.contains("Essai"))
        #expect(html.contains("exemple.fr"))
        #expect(!html.contains("Optional("))
    }

    @Test func laPageDesScriptsSuitSonInterrupteur() {
        #expect(ScriptsPage.html(scripts: [], isEnabled: true).contains("exécutés sur cette machine"))
        #expect(ScriptsPage.html(scripts: [], isEnabled: false).contains("tous éteints"))
    }
}
