import Testing
import Foundation
@testable import Wuji

/// Où atterrit un fichier téléchargé.
///
/// **Écraser un fichier existant sans le dire est une perte de données silencieuse** — la
/// seule espèce de défaut que ce projet refuse de laisser passer. La règle a deux moitiés,
/// et la seconde a manqué longtemps : le disque dit ce qui est *arrivé*, la liste dit ce
/// qui est *en vol*. WebKit demande la destination bien avant de créer le fichier ; sans la
/// seconde moitié, deux téléchargements lancés dans la même seconde repartaient avec le
/// même nom, et un seul des deux fichiers existait à la fin. Mesuré sur le banc d'essai.
@MainActor
struct DownloadDestinationTests {

    private let folder = URL(fileURLWithPath: "/tmp/wuji-essai-telechargements")

    private func destination(_ name: String, taken: [String] = []) -> String {
        DownloadStore.destination(for: name, in: folder,
                                  taken: Set(taken.map { folder.appendingPathComponent($0) }))
            .lastPathComponent
    }

    @Test func unNomLibrePasseTelQuel() {
        #expect(destination("rapport.pdf") == "rapport.pdf")
    }

    @Test func unNomDéjàRéservéPrendLeSuivant() {
        #expect(destination("rapport.pdf", taken: ["rapport.pdf"]) == "rapport 2.pdf")
    }

    @Test func onCompteJusquÀTrouverLaPlace() {
        #expect(destination("rapport.pdf", taken: ["rapport.pdf", "rapport 2.pdf"])
                == "rapport 3.pdf")
    }

    @Test func sansExtensionLeNuméroSeCollePareil() {
        #expect(destination("archive", taken: ["archive"]) == "archive 2")
    }

    /// Le nom suggéré vient du serveur, et un serveur peut proposer ce qu'il veut. Sans ce
    /// nettoyage, `Content-Disposition: attachment; filename="../../.zshrc"` écrirait hors
    /// du dossier des téléchargements.
    @Test func unCheminSuggéréEstRéduitÀSonDernierSegment() {
        #expect(destination("../../.zshrc") == ".zshrc")
        #expect(destination("/etc/passwd") == "passwd")
    }

    @Test func unNomVideDevientUnNom() {
        #expect(destination("") == "fichier")
        #expect(destination("..") == "fichier")
    }
}

/// Où un identifiant peut être proposé.
///
/// **La règle vise le réseau, pas le protocole.** HTTPS partout, parce qu'un mot de passe
/// proposé en clair est proposé à quiconque écoute — sauf pour un service qu'on héberge sur
/// sa propre machine, qui ne traverse aucun réseau. Exclure `localhost` ferait payer la
/// précaution là où elle ne protège de rien, et priverait de la fonction les seuls sites
/// qu'on ne peut pas passer en HTTPS sans monter une autorité de certification pour soi.
@MainActor
struct LocalHostTests {

    @Test func laMachineElleMême() {
        #expect(AppDelegate.isLocalHost("localhost"))
        #expect(AppDelegate.isLocalHost("127.0.0.1"))
        #expect(AppDelegate.isLocalHost("::1"))
    }

    @Test func unServiceDerrièreUnRouteurDeConteneurs() {
        // La forme que prend chaque service derrière Traefik : `pma.localhost`, `api.localhost`.
        #expect(AppDelegate.isLocalHost("pma.localhost"))
        #expect(AppDelegate.isLocalHost("dolibarr.localhost"))
    }

    @Test func leRéseauQuOnATousSousLaMain() {
        #expect(AppDelegate.isLocalHost("192.168.1.20"))
        #expect(AppDelegate.isLocalHost("10.0.0.4"))
        #expect(AppDelegate.isLocalHost("172.20.0.5"))
        #expect(AppDelegate.isLocalHost("imprimante.local"))
    }

    @Test func leResteDuWebNEnEstPas() {
        #expect(!AppDelegate.isLocalHost("exemple.fr"))
        #expect(!AppDelegate.isLocalHost("172.32.0.1"))
        // Le piège du préfixe : « 10 » commence « 10.0.0.0/8 », pas « 100.com ».
        #expect(!AppDelegate.isLocalHost("localhost.exemple.fr"))
    }
}
