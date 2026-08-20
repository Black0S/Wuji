import Testing
import Foundation
@testable import Wuji

/// Adresse ou recherche ?
///
/// C'est la seule ambiguïté que l'omnibox ait à lever, et elle se trompait dans les deux
/// sens : `localhost:8080` partait chez le moteur de recherche faute de point, et
/// `pma.localhost` était visé en `https` — un serveur de développement ne présente presque
/// jamais de certificat, donc l'adresse échouait alors qu'elle répond.
@MainActor
struct OmniboxInputTests {

    private func adresse(_ saisie: String) -> String? {
        AppDelegate.directURL(saisie)?.absoluteString
    }

    @Test func unSchémaÉcritÀLaMainFaitFoi() {
        // Le cas signalé : un conteneur derrière un routeur local.
        #expect(adresse("http://pma.localhost/") == "http://pma.localhost/")
        #expect(adresse("https://exemple.com/page") == "https://exemple.com/page")
    }

    @Test func leWebEstEnHttpsParDéfaut() {
        #expect(adresse("exemple.com") == "https://exemple.com")
        #expect(adresse("www.lemonde.fr/international") == "https://www.lemonde.fr/international")
    }

    @Test func chezSoiCestHttp() {
        #expect(adresse("pma.localhost") == "http://pma.localhost")
        #expect(adresse("localhost") == "http://localhost")
        #expect(adresse("imprimante.local") == "http://imprimante.local")
        #expect(adresse("192.168.1.10") == "http://192.168.1.10")
        #expect(adresse("172.20.0.5") == "http://172.20.0.5")
    }

    @Test func unPortSuffitÀFaireUneAdresse() {
        // Sans point, la saisie partait en recherche : « localhost:8080 » n'est pas une
        // question qu'on pose à un moteur.
        #expect(adresse("localhost:8080") == "http://localhost:8080")
        #expect(adresse("127.0.0.1:3000/admin") == "http://127.0.0.1:3000/admin")
    }

    @Test func ceQuiRessembleÀUneRechercheEnReste() {
        #expect(adresse("comment faire du pain") == nil)
        #expect(adresse("localhost quelque chose") == nil)
        // Un mot seul n'est pas un hôte, même collé à autre chose.
        #expect(adresse("dictionnaire") == nil)
    }

    @Test func uneIPPubliqueNEstPasLocale() {
        // 172.5 n'est pas dans la plage privée : elle ne doit pas être rétrogradée en clair.
        #expect(adresse("172.5.0.1") == "https://172.5.0.1")
        #expect(!AppDelegate.isLocalHost("localhost.exemple.com"))
    }

    @Test func lesPagesInternesRestentDesPages() {
        #expect(adresse("wuji://settings") == "wuji://settings")
    }
}
