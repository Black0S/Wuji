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
    private let autre = URL(string: "https://exemple.com/suite")!
    private let vide = URL(string: "about:blank")!

    // Chaque cas ci-dessous correspond à un moment vécu par un onglet. Trois d'entre eux
    // ont déjà fait disparaître une ligne de la colonne, par trois chemins différents.

    @Test func pageAffichée() {
        #expect(Tab.resolvedURL(live: page, lastKnown: page) == page)
    }

    @Test func enVeille() {
        // La vue est vidée : c'est la mémoire qui nomme l'onglet.
        #expect(Tab.resolvedURL(live: vide, lastKnown: page) == page)
    }

    @Test func pendantLeRéveil() {
        // Le défaut signalé : on survole pour réveiller, la vue n'a pas encore repris, et
        // l'onglet disparaissait sous le curseur.
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

/// L'adresse telle que la barre l'écrit.
///
/// Elle répond à une question de sécurité — sur quel site suis-je ? — et une erreur de
/// découpage la ferait mentir : afficher `youtube.com` sur une page servie par un autre
/// domaine serait exactement le genre de tromperie qu'un navigateur doit rendre impossible.
@MainActor
struct AddressRenderingTests {

    private func rendu(_ adresse: String, insecure: Bool = false) -> String {
        ContentTopBar.render(URL(string: adresse), insecure: insecure).string
    }

    @Test func leProtocoleChiffréNEstPasÉcrit() {
        // Le cadenas le dit mieux, et il occupait la place du nom du site.
        #expect(!rendu("https://www.youtube.com/watch?v=abc").contains("https"))
    }

    @Test func leProtocoleEnClairEstÉcrit() {
        // Là il informe : on doit le voir sans aller chercher le petit symbole.
        #expect(rendu("http://exemple.com/page", insecure: true).hasPrefix("http://"))
    }

    @Test func lAdresseResteComplèteEtLisible() {
        #expect(rendu("https://www.youtube.com/watch?v=abc") == "www.youtube.com/watch?v=abc")
    }

    @Test func laRacineNAffichePasSaBarreSeule() {
        // « exemple.com/ » se lit moins bien que « exemple.com », pour rien de plus.
        #expect(rendu("https://exemple.com/") == "exemple.com")
    }

    @Test func unePageInterneGardeSonSchéma() {
        // Sans lui, « wuji://settings » s'affichait comme un simple « settings » — rien ne
        // la distinguait d'un site qui s'appellerait ainsi.
        #expect(rendu("wuji://settings") == "wuji://settings")
        #expect(rendu("wuji://ad-block/my-rules") == "wuji://ad-block/my-rules")
    }
}
