import Testing
import Foundation
@testable import Wuji

/// Un onglet garde son identité quoi que dise sa vue web.
///
/// C'est une règle du produit avant d'être une règle de code : **rien ne disparaît de la
/// colonne sans qu'on l'ait fermé**. Ce test existe parce que le défaut est passé
/// plusieurs fois — la vue web passe par des états où elle annonce un document vide, et
/// l'onglet se faisait alors prendre pour un onglet vierge.
@MainActor
struct TabIdentityTests {

    private let page = URL(string: "https://exemple.com/article")!
    private let autre = URL(string: "https://exemple.com/suite")!
    private let vide = URL(string: "about:blank")!

    // Chaque cas ci-dessous correspond à un moment vécu par un onglet. Plusieurs ont déjà
    // fait disparaître une ligne de la colonne, par des chemins différents.

    @Test func pageAffichée() {
        #expect(Tab.resolvedURL(live: page, lastKnown: page) == page)
    }

    @Test func vueVidée() {
        // La vue annonce un document vide : c'est la mémoire qui nomme l'onglet.
        #expect(Tab.resolvedURL(live: vide, lastKnown: page) == page)
    }

    @Test func restauréMaisPasEncoreChargé() {
        #expect(Tab.resolvedURL(live: nil, lastKnown: page) == page)
    }

    @Test func entreDeuxNavigations() {
        // La vue a lâché l'ancienne page sans avoir engagé la nouvelle.
        #expect(Tab.resolvedURL(live: nil, lastKnown: autre) == autre)
    }

    @Test func laVueVivanteLEmporteSurLaMémoire() {
        // Une fois la nouvelle page engagée, c'est elle qui fait foi : la mémoire ne doit
        // pas figer l'onglet sur son adresse précédente.
        #expect(Tab.resolvedURL(live: autre, lastKnown: page) == autre)
    }

    @Test func ongletVraimentVierge() {
        #expect(Tab.resolvedURL(live: nil, lastKnown: nil) == nil)
    }

    @Test func vueVidéeSansMémoire() {
        // Rien à inventer : on rend ce que la vue dit, et la colonne décidera.
        #expect(Tab.resolvedURL(live: vide, lastKnown: nil) == vide)
    }
}

/// Le zoom par site.
///
/// Il touche à deux réglages qui se ressemblent — la valeur générale et l'écart retenu
/// pour un site — et les confondre donnerait soit un zoom qui ne suit pas, soit un
/// enregistrement pour chaque site visité.
@MainActor
struct SiteZoomTests {

    @Test func unSiteSansÉcartPrendLeRéglageGénéral() {
        let settings: [String: Double] = ["exemple.com": 1.3]
        #expect(settings["autre.com"] == nil)
    }

    @Test func leZoomEstRangéSousLeSiteEtPasSousLHôte() {
        // C'est ce qui fait qu'un réglage posé sur `www.lemonde.fr` vaut aussi sur
        // `m.lemonde.fr` : on range sous le nom du site, pas sous celui de la machine.
        #expect(Site.name(ofHost: "www.lemonde.fr") == Site.name(ofHost: "m.lemonde.fr"))
    }

    @Test func deuxSitesVoisinsRestentDistincts() {
        #expect(Site.name(ofHost: "foo.github.io") != Site.name(ofHost: "bar.github.io"))
    }
}
