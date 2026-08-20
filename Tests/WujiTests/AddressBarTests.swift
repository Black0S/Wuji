import Testing
import Foundation
@testable import Wuji

/// Ce que la barre du haut affirme.
///
/// L'adresse et le cadenas répondent à une question de sécurité — *sur quel site suis-je,
/// et par quel chemin ?* — et ils y répondent sans que personne les interroge. Un
/// indicateur qui se trompe est donc pire qu'un indicateur absent : on le croit. Afficher
/// `youtube.com` sur une page servie par un autre domaine, ou un cadenas là où rien n'est
/// chiffré, c'est exactement la tromperie qu'un navigateur doit rendre impossible.
///
/// Deux défauts vus à l'écran ont donné la moitié de ces tests : un cadenas affiché sur
/// `wuji://`, où il n'y a aucune connexion à certifier, et un onglet neuf annoncé `wuji://`
/// alors que sa vue portait `about:blank`.
@MainActor
struct AddressBarTests {

    // MARK: - Le cadenas

    @Test func leCadenasNeCertifieQueLesConnexions() {
        #expect(ContentTopBar.certifies(URL(string: "https://exemple.com/page")!))
        // En clair aussi : le symbole change de forme et de couleur, mais il reste — c'est
        // là qu'on a le plus besoin de le voir.
        #expect(ContentTopBar.certifies(URL(string: "http://exemple.com")!))
    }

    @Test func rienÀCertifier() {
        #expect(!ContentTopBar.certifies(nil))
        #expect(!ContentTopBar.certifies(URL(string: "about:blank")!))
        // Le défaut vu à l'écran : `🔒 wuji://` sur un onglet neuf.
        #expect(!ContentTopBar.certifies(URL(string: "wuji://settings")!))
        // Un fichier local ne voyage pas : il n'y a pas de transport à qualifier.
        #expect(!ContentTopBar.certifies(URL(string: "file:///Users/moi/page.html")!))
    }

    // MARK: - L'adresse

    private func rendu(_ adresse: String?, insecure: Bool = false) -> String {
        ContentTopBar.render(adresse.flatMap { URL(string: $0) }, insecure: insecure).string
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
        #expect(rendu("https://m.youtube.com/watch?v=42") == "m.youtube.com/watch?v=42")
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

    @Test func unOngletVideEstChezWuji() {
        #expect(rendu(nil) == "wuji://")
        // Une vue vidée par la veille annonce `about:blank` : elle n'est nulle part non plus.
        #expect(rendu("about:blank") == "wuji://")
    }

    @Test func uneAdresseSansHôteSeDitTelleQuelle() {
        // Elle s'affichait « wuji:// » : la barre attribuait à Wuji une page qui ne lui
        // appartient pas.
        #expect(rendu("file:///Users/moi/page.html") == "file:///Users/moi/page.html")
    }
}
