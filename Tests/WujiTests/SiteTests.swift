import Testing
@testable import Wuji

/// Ce que Wuji appelle « ce site ».
///
/// Cette question décide où va une exception de blocage. Une réponse trop large la fait
/// déborder sur les pages de tout le monde ; une réponse trop étroite la fait perdre à la
/// première redirection. C'est pour ces deux cas précis que la liste des suffixes publics
/// est une dépendance du projet, et ces tests existent pour qu'on ne la retire pas un jour
/// en croyant simplifier.
@MainActor
struct SiteTests {

    @Test func lesSousDomainesSontLeMêmeSite() {
        #expect(Site.name(ofHost: "www.youtube.com") == "youtube.com")
        #expect(Site.name(ofHost: "m.youtube.com") == "youtube.com")
        #expect(Site.name(ofHost: "youtube.com") == "youtube.com")
    }

    @Test func unHôteAccentuéSeRangeSousSaFormeRéseau() {
        // La seconde barrière : même si une URL mal normalisée arrive jusqu'ici, la clé de
        // rangement doit être celle que la page annoncera — sinon une exception de blocage
        // ne correspond à rien.
        #expect(Site.punycode("caf%C3%A9.fr") == "xn--caf-dma.fr")
        #expect(Site.name(ofHost: "caf%C3%A9.fr") == "xn--caf-dma.fr")
        #expect(Site.name(ofHost: "www.m%C3%BCnchen.de") == "xn--mnchen-3ya.de")
        // Ce qui n'a pas de pourcentage n'est pas touché : la conversion ne s'invite pas.
        #expect(Site.punycode("exemple.com") == "exemple.com")
        #expect(Site.name(ofHost: "xn--caf-dma.fr") == "xn--caf-dma.fr")
    }

    @Test func unSuffixePublicNEstPasUnSite() {
        // Deux personnes différentes. Lever la protection sur l'une ne doit rien faire
        // pour l'autre — c'est le cas qui interdit de couper au deuxième point.
        #expect(Site.name(ofHost: "foo.github.io") == "foo.github.io")
        #expect(Site.name(ofHost: "bar.github.io") == "bar.github.io")
    }

    @Test func lesSuffixesÀDeuxNiveauxSontRespectés() {
        #expect(Site.name(ofHost: "www.bbc.co.uk") == "bbc.co.uk")
    }

    @Test func ceQueLaListeNeSaitPasResteTelQuel() {
        // Une adresse IP, un nom de machine local : on ne devine pas.
        #expect(Site.name(ofHost: "192.168.1.10") == "192.168.1.10")
        #expect(Site.name(ofHost: "localhost") == "localhost")
    }

    @Test func laCasseNeChangeRien() {
        #expect(Site.name(ofHost: "WWW.YouTube.COM") == "youtube.com")
    }
}
