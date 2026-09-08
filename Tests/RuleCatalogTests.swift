import Testing
import Foundation
@testable import Wuji

/// Le catalogue, après que le dépôt a changé de schéma.
///
/// **C'est l'endroit où une refonte amont se paie en silence.** Une identité qui change,
/// un champ qui disparaît, un nombre qui change de sens : rien de tout cela n'empêche de
/// compiler. Cela décoche les listes de quelqu'un, ou lui affiche un compte faux.
@MainActor
struct RuleCatalogTests {

    private func liste(id: String = "adguard-base", source: String = "AdGuard-Base-filter.txt",
                       hash: String = "abc", version: String = "2.4", groupe: String = "AdGuard",
                       uniques: Int = 89628, morceaux: [RuleList.Part] = [
                           .init(file: "a.json", rules: 45000, bytes: 1000),
                           .init(file: "b.json", rules: 45628, bytes: 1000)]) -> RuleList {
        RuleList(id: id, name: "AdGuard Base filter", source: source, sourceHash: hash,
                 version: version, group: groupe, coverage: 88.8, uniqueRules: uniques,
                 parts: morceaux)
    }

    @Test func leCompteAfficheEstCeluiDesReglesDistinctes() {
        // Une liste découpée réplique ses exceptions dans chaque tranche : additionner les
        // fichiers compte donc plusieurs fois la même règle. Le dépôt publie les deux
        // nombres ; c'est le distinct qu'on montre.
        #expect(liste().rules == 89628)
        #expect(liste().parts.reduce(0) { $0 + $1.rules } == 90628)
        // Un catalogue qui ne publierait pas le compte distinct — l'ancien — retombe sur
        // la somme plutôt que d'afficher zéro.
        #expect(liste(uniques: 0).rules == 90628)
    }

    @Test func lEmpreinteDitCeQuiAChange() {
        // Deux listes que la version seule ne distingue pas : l'une a changé chez son
        // mainteneur, l'autre chez le convertisseur. Vingt-deux listes du dépôt ne publient
        // aucune version — les comparer par là les aurait dites à jour pour toujours.
        #expect(liste().build != liste(hash: "def").build)
        #expect(liste().build != liste(uniques: 89629).build)
        #expect(liste().build == liste().build)
        // Sans empreinte publiée, on retombe sur la version et le compte.
        #expect(liste(hash: "", version: "1").build != liste(hash: "", version: "2").build)
    }

    @Test func lOrdreDesFamillesEstDIciEtNonDuDepot() {
        // Le dépôt range par mainteneur ; ce qu'il ne peut pas savoir, c'est ce qu'on vient
        // chercher en premier. Les listes par langue et par région passent en dernier.
        #expect(RuleCatalog.rank(of: "AdGuard") < RuleCatalog.rank(of: "EasyList (regions)"))
        #expect(RuleCatalog.rank(of: "uBlock Origin") < RuleCatalog.rank(of: "AdGuard (langues)"))
        // Une famille que le dépôt ajouterait demain ne disparaît pas : elle passe après.
        #expect(RuleCatalog.rank(of: "Un Nouveau Mainteneur") == RuleCatalog.order.count)
    }

    @Test func lAnnexeSeTrouveAvecOuSansSonDossier() {
        // Le dépôt les nommait sans leur dossier — 404 en suivant l'index à la lettre. Il
        // les nomme correctement depuis ; les deux écritures marchent, parce qu'un
        // consommateur qui casse au premier changement de chemin n'est pas robuste.
        let avec = RuleCatalog.extended("extended/Extended-EasyList.json").absoluteString
        let sans = RuleCatalog.extended("Extended-EasyList.json").absoluteString
        #expect(avec == sans)
        #expect(avec.hasSuffix("/dist/extended/Extended-EasyList.json"))
    }

    @Test func lesListesHorsCatalogueSeVoient() {
        // Elles bloquent encore — leurs règles compilées sont sur le disque — mais plus
        // personne ne les publie. Les cacher aurait été le pire des deux.
        let état = BlockingPage.State(
            catalog: [liste()], installed: ["adguard-base"], outdated: [],
            activeRules: 89628, working: [:], failure: nil, unreachable: false,
            paused: [], orphans: ["EasyList-Annoyances.txt"])
        let html = BlockingPage.html(state: état)
        #expect(html.contains("Hors catalogue"))
        #expect(html.contains("EasyList-Annoyances.txt"))
        #expect(html.contains(#"data-action="forget-orphan""#))
        #expect(!html.contains("Optional("))

        // Rien à signaler : pas de section.
        var sain = état
        sain.orphans = []
        #expect(!BlockingPage.html(state: sain).contains("Hors catalogue"))
    }

    @Test func laProvenanceRemplaceLaDescriptionDisparue() {
        // Soixante-dix listes sur soixante et onze ont une description vide depuis la
        // refonte du dépôt. Une ligne vide n'apprend rien ; l'adresse du mainteneur, si.
        var avec = liste()
        avec.homepage = "https://github.com/AdguardTeam/AdguardFilters"
        avec.license = "https://github.com/AdguardTeam/AdguardFilters/blob/master/LICENSE"
        let état = BlockingPage.State(catalog: [avec], installed: [], outdated: [],
                                      activeRules: 0, working: [:], failure: nil,
                                      unreachable: false, paused: [])
        let html = BlockingPage.html(state: état)
        #expect(html.contains("github.com · sous licence"))

        // Une description publiée reprend sa place : c'est elle qui en dit le plus.
        var décrite = avec
        décrite.summary = "Le filtre de base."
        var autre = état
        autre.catalog = [décrite]
        #expect(BlockingPage.html(state: autre).contains("Le filtre de base."))
    }
}
