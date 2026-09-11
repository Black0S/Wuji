import Testing
import Foundation
@testable import Wuji

/// Où dort la clé que Touch ID rend, et ce que cela coûte.
///
/// **Le trousseau demandait son mot de passe à chaque déverrouillage.** Il attache chaque
/// élément à l'application qui l'a créé, reconnue à sa signature ; une copie compilée sur
/// place est signée *ad hoc*, et son empreinte change à chaque compilation — deux
/// compilations d'affilée, deux empreintes. Le système ne reconnaissait donc jamais Wuji
/// d'un lancement à l'autre, et « Toujours autoriser » n'autorisait que la version en cours
/// d'exécution. Un coffre dont la promesse est de ne jamais faire appel au mot de passe du
/// Mac le réclamait ainsi plus souvent que n'importe quoi d'autre.
@MainActor
struct BiometricsTests {

    private func dossierNeuf() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wuji-biom-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Biometrics.directory = url
        return url
    }

    @Test func laCleDuRepliNeVaPlusDansLeTrousseau() throws {
        let dossier = dossierNeuf()
        defer {
            Biometrics.disable()
            try? FileManager.default.removeItem(at: dossier)
            Biometrics.directory = Storage.directory
        }

        // On n'affirme rien sur l'état de départ : la machine qui exécute cet essai peut
        // porter un ancien élément dans son trousseau, et Wuji le compte tant qu'il n'a pas
        // déménagé. C'est le fichier qui est vérifié ici, et lui seul.
        #expect(Biometrics.protection != .secureEnclave)
        let clé = Data((0..<32).map { UInt8($0) })
        // Sur une copie signée ad-hoc, l'Enclave refuse — `errSecMissingEntitlement`,
        // mesuré — et c'est le repli qui prend la clé.
        #expect(Biometrics.enable(key: clé) == .softwareGate)
        #expect(Biometrics.protection == .softwareGate)
        #expect(Biometrics.isEnabled)

        let fichier = dossier.appendingPathComponent("coffre-touchid.bin")
        #expect(FileManager.default.fileExists(atPath: fichier.path))
        #expect(try Data(contentsOf: fichier) == clé)

        // **Un fichier de clé lisible par le groupe n'est pas un fichier de clé.** Les
        // droits sont posés explicitement, et pas laissés au masque du processus.
        let droits = try FileManager.default.attributesOfItem(atPath: fichier.path)[.posixPermissions]
        #expect((droits as? NSNumber)?.int16Value == 0o600)

        // Éteindre efface : une fonction coupée ne laisse pas sa clé derrière elle.
        #expect(Biometrics.disable())
        #expect(!FileManager.default.fileExists(atPath: fichier.path))
        // Éteindre pose la pierre tombale quand le trousseau refuse la suppression de
        // l'ancien élément : sans elle, il répondrait « oui, c'est allumé » au lancement
        // suivant, et l'interrupteur ne tiendrait pas.
        if Biometrics.leftoverInKeychain {
            #expect(FileManager.default.fileExists(
                atPath: dossier.appendingPathComponent("coffre-touchid.ancien-efface").path))
        }
    }

    @Test func rallumerRemplaceAuLieuDeSuperposer() throws {
        let dossier = dossierNeuf()
        defer {
            Biometrics.disable()
            try? FileManager.default.removeItem(at: dossier)
            Biometrics.directory = Storage.directory
        }
        let première = Data(repeating: 1, count: 32)
        let seconde = Data(repeating: 2, count: 32)
        Biometrics.enable(key: première)
        Biometrics.enable(key: seconde)
        // Changer de mot de passe maître change la clé : l'ancienne ne doit pas survivre,
        // sinon un doigt ouvrirait un coffre qui n'existe plus.
        let fichier = dossier.appendingPathComponent("coffre-touchid.bin")
        #expect(try Data(contentsOf: fichier) == seconde)
    }
}
