import Testing
import Foundation
@testable import Wuji

/// Les certificats refusés, et ce qu'on en dit.
///
/// Deux familles de sites étaient inatteignables avant ce travail — mesuré sur deux
/// serveurs locaux : l'authentification HTTP n'affichait aucune invite, et un certificat
/// auto-signé échouait sans issue. Ce qui se vérifie sans fenêtre est ici : quelle erreur
/// ouvre droit à une exception, et quelle page on montre alors.
@MainActor
struct AuthenticationTests {

    private func error(_ code: Int, domain: String = NSURLErrorDomain) -> NSError {
        NSError(domain: domain, code: code)
    }

    @Test func lesÉchecsDeCertificatOuvrentDroitÀUneException() {
        #expect(ErrorPage.isUntrusted(error(NSURLErrorServerCertificateUntrusted)))
        #expect(ErrorPage.isUntrusted(error(NSURLErrorServerCertificateHasUnknownRoot)))
        #expect(ErrorPage.isUntrusted(error(NSURLErrorServerCertificateHasBadDate)))
        #expect(ErrorPage.isUntrusted(error(NSURLErrorSecureConnectionFailed)))
    }

    @Test func lesAutresÉchecsNOuvrentRien() {
        // Un serveur muet ou un domaine inexistant n'ont pas de certificat à accepter :
        // proposer « continuer quand même » y serait un bouton mort.
        #expect(!ErrorPage.isUntrusted(error(NSURLErrorCannotFindHost)))
        #expect(!ErrorPage.isUntrusted(error(NSURLErrorTimedOut)))
        #expect(!ErrorPage.isUntrusted(error(NSURLErrorNotConnectedToInternet)))
        // Une page arrêtée par le bloqueur n'est pas un problème d'identité.
        #expect(!ErrorPage.isUntrusted(error(104, domain: "WebKitErrorDomain")))
    }

    private func page(_ code: Int, certificate: [String] = []) -> String {
        ErrorPage.html(url: URL(string: "https://192.168.1.40/")!,
                       error: error(code), certificate: certificate)
    }

    @Test func laPageMontreLeCertificatAvantDeProposerDeLAccepter() {
        // **Demander une exception sans montrer sur quoi, c'est demander un blanc-seing.**
        let html = page(NSURLErrorServerCertificateUntrusted,
                        certificate: ["Délivré à 192.168.1.40", "SHA-256 AB:CD:EF"])
        #expect(html.contains("Délivré à 192.168.1.40"))
        #expect(html.contains("AB:CD:EF"))
        #expect(html.contains("Continuer quand même"))
        #expect(html.contains(#"action: "trust""#))
        // L'empreinte se compare caractère par caractère : elle porte sa chasse fixe.
        #expect(html.contains(#"<p class="print">SHA-256"#))
    }

    @Test func laPortéeDeLExceptionEstDite() {
        let html = page(NSURLErrorServerCertificateUntrusted)
        #expect(html.contains("cette session"))
    }

    @Test func unCertificatExpiréNestPasUnCertificatInconnu() {
        // Deux causes, deux conduites : l'une se corrige côté serveur, l'autre vient
        // souvent de l'horloge de cette machine.
        #expect(page(NSURLErrorServerCertificateHasBadDate).contains("Certificat expiré"))
        #expect(page(NSURLErrorServerCertificateNotYetValid).contains("horloge"))
        #expect(page(NSURLErrorServerCertificateUntrusted).contains("Identité non vérifiée"))
    }

    @Test func unEchecOrdinaireProposeRéessayer() {
        let html = page(NSURLErrorTimedOut)
        #expect(html.contains("Réessayer"))
        #expect(!html.contains(#"action: "trust""#))
    }
}
