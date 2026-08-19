import Testing
import Foundation
@testable import Wuji

/// Un onglet endormi doit rester visible.
///
/// C'est une règle du produit avant d'être une règle de code : **rien ne disparaît de la
/// colonne sans qu'on l'ait fermé**. La veille rend la mémoire, elle ne retire pas la
/// ligne. Ce test existe parce que le défaut est passé deux fois — la vue web bascule sur
/// un document vide en s'endormant, et l'onglet se faisait alors prendre pour un onglet
/// vierge.
@MainActor
struct SleepingTabTests {

    private let page = URL(string: "https://exemple.com/article")!
    private let blank = URL(string: "about:blank")!

    @Test func enVeilleLAdresseMiseDeCôtéFaitFoi() {
        #expect(Tab.resolvedURL(live: blank, pending: page, isSleeping: true) == page)
    }

    @Test func éveilléCEstLaVueQuiFaitFoi() {
        #expect(Tab.resolvedURL(live: page, pending: nil, isSleeping: false) == page)
    }

    @Test func unOngletRestauréAnnonceSonAdresseAvantDAvoirChargé() {
        // À la reprise d'une session, la vue n'a encore rien : sans ce repli, la ligne
        // serait vide au démarrage.
        #expect(Tab.resolvedURL(live: nil, pending: page, isSleeping: false) == page)
    }

    @Test func unOngletVraimentVierseNAPasDAdresse() {
        #expect(Tab.resolvedURL(live: nil, pending: nil, isSleeping: false) == nil)
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
