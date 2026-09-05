import Testing
import Foundation
@testable import Wuji

/// Le coffre : ce qu'il garde, ce qu'il refuse, et ce qu'il ne laisse pas voir.
///
/// **Ce sont les seuls essais du projet dont l'échec serait une fuite.** Le reste vérifie
/// qu'une fonction rend ce qu'on attend ; ici, un `unlock` qui réussirait avec le mauvais
/// mot de passe, ou un fichier où l'on relirait un identifiant en clair, seraient des
/// défauts d'une autre nature — et invisibles à l'usage, puisque tout marcherait.
@MainActor
struct VaultTests {

    /// Chaque essai travaille dans son propre dossier. Sans cela, un essai qui vérifie
    /// qu'on sait créer un coffre écraserait le vrai — on détruirait les mots de passe de
    /// quelqu'un pour prouver qu'on sait les garder.
    private func bench() -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coffre-essai-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Vault.folder = folder
        Vault.lock()
        return folder
    }

    private func clean(_ folder: URL) {
        Vault.lock()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func onNeCréePasUnCoffreAvecTroisLettres() {
        let folder = bench(); defer { clean(folder) }
        // Huit caractères ne font pas un bon mot de passe, mais en dessous il n'y a plus
        // rien à dériver : autant ne pas chiffrer du tout.
        #expect(!Vault.create(master: "court"))
        #expect(!Vault.exists)
    }

    @Test func créerPuisÉcrireEtRelire() {
        let folder = bench(); defer { clean(folder) }
        #expect(Vault.create(master: "phrase-de-passe"))
        #expect(Vault.isUnlocked)
        #expect(Vault.save(host: "exemple.fr", user: "marie", password: "s1"))
        #expect(Vault.password(host: "exemple.fr", user: "marie") == "s1")
        #expect(Vault.accounts(for: "exemple.fr") == ["marie"])
    }

    @Test func verrouilléRienNeSortEtRienNEntre() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        Vault.lock()

        // **La différence entre « vide » et « fermé » n'appartient pas à l'appelant.**
        // Un coffre fermé ne rend rien, et c'est tout ce que la complétion a besoin de
        // savoir pour ne rien proposer.
        #expect(Vault.accounts(for: "exemple.fr").isEmpty)
        #expect(Vault.password(host: "exemple.fr", user: "marie") == nil)
        #expect(Vault.all().isEmpty)
        #expect(!Vault.save(host: "autre.fr", user: "u", password: "p"))
    }

    @Test func leMauvaisMotDePasseNOuvrePas() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        Vault.lock()

        #expect(!Vault.unlock(master: "pas-la-bonne"))
        #expect(!Vault.isUnlocked)
        #expect(Vault.unlock(master: "phrase-de-passe"))
        #expect(Vault.password(host: "exemple.fr", user: "marie") == "s1")
    }

    @Test func unFichierAbîméEstRefuséAuLieuDeRendreNImporteQuoi() throws {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        Vault.lock()

        // AES-GCM authentifie autant qu'il chiffre : un octet retourné doit faire échouer
        // l'ouverture, pas produire un contenu approximatif qu'on rangerait ensuite.
        var bytes = try Data(contentsOf: Vault.url)
        bytes[bytes.count - 20] ^= 0xFF
        try bytes.write(to: Vault.url)
        #expect(!Vault.unlock(master: "phrase-de-passe"))
    }

    @Test func rienNEstLisibleSurLeDisque() throws {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "banque-secrete.fr", user: "marie", password: "tres-secret")

        let raw = try String(contentsOf: Vault.url, encoding: .utf8)
        #expect(!raw.contains("banque-secrete.fr"))
        #expect(!raw.contains("marie"))
        #expect(!raw.contains("tres-secret"))
    }

    @Test func changerDeMaîtreFermeLAncien() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        #expect(Vault.changeMaster(to: "nouvelle-phrase"))
        Vault.lock()

        #expect(!Vault.unlock(master: "phrase-de-passe"))
        #expect(Vault.unlock(master: "nouvelle-phrase"))
        #expect(Vault.password(host: "exemple.fr", user: "marie") == "s1")
    }

    @Test func leLotNÉcritQuUneFois() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        let batch = (1...50).map {
            Vault.Entry(host: "site\($0).fr", user: "u", password: "p\($0)")
        }
        // Ranger cinquante lignes une par une rechiffrerait le coffre entier cinquante
        // fois. `saveAll` en fait un seul chiffrement — et doit rendre le même résultat.
        #expect(Vault.saveAll(batch) == 50)
        #expect(Vault.all().count == 50)
        #expect(Vault.password(host: "site37.fr", user: "u") == "p37")
    }

    @Test func leMêmeCompteEstRemplacéEtNonDoublé() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        Vault.save(host: "exemple.fr", user: "marie", password: "s2")
        // Deux entrées pour le même compte ne se départageraient plus, et le remplissage
        // choisirait au hasard.
        #expect(Vault.all().count == 1)
        #expect(Vault.password(host: "exemple.fr", user: "marie") == "s2")
    }

    @Test func deuxComptesSurLeMêmeSiteSeRetrouventTousLesDeux() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        Vault.save(host: "exemple.fr", user: "marc", password: "s2")
        // L'index range par hôte puis par compte : deux comptes du même hôte ne doivent
        // pas s'écraser l'un l'autre, et l'ordre est celui de l'affichage.
        #expect(Vault.accounts(for: "exemple.fr") == ["marc", "marie"])
        #expect(Vault.password(host: "exemple.fr", user: "marc") == "s2")
    }

    @Test func lIndexSurvitÀLaFermetureEtÀLaRéouverture() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.saveAll((1...20).map {
            Vault.Entry(host: "site\($0).fr", user: "u", password: "p\($0)")
        })
        Vault.lock()
        #expect(Vault.unlock(master: "phrase-de-passe"))
        // L'index est refait à l'ouverture ; s'il ne l'était pas, tout répondrait vide
        // alors que le contenu est là.
        #expect(Vault.password(host: "site13.fr", user: "u") == "p13")
        #expect(Vault.accounts(for: "site13.fr") == ["u"])
    }

    @Test func supprimerRetireAussiDeLIndex() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        Vault.save(host: "exemple.fr", user: "marc", password: "s2")
        #expect(Vault.remove(host: "exemple.fr", user: "marie"))
        // Un index qu'on oublierait de refaire rendrait encore le mot de passe d'un compte
        // supprimé — et le remplirait.
        #expect(Vault.password(host: "exemple.fr", user: "marie") == nil)
        #expect(Vault.accounts(for: "exemple.fr") == ["marc"])
    }

    @Test func ouvrirAvecLaCléSeule() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        // C'est ce chemin-là que Touch ID emprunte : l'Enclave rend la clé, pas le mot de
        // passe maître — qui n'est écrit nulle part et ne se retrouve pas.
        let material = Vault.keyMaterial
        #expect(material?.count == 32)

        Vault.lock()
        #expect(Vault.keyMaterial == nil)
        #expect(Vault.unlock(key: try! #require(material)))
        #expect(Vault.password(host: "exemple.fr", user: "marie") == "s1")
    }

    @Test func uneCléFausseNOuvrePas() throws {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        var material = try #require(Vault.keyMaterial)
        Vault.lock()

        material[0] ^= 0xFF
        #expect(!Vault.unlock(key: material))
        #expect(!Vault.isUnlocked)
        // Une clé de la mauvaise taille est refusée avant même de déchiffrer.
        #expect(!Vault.unlock(key: Data(repeating: 7, count: 16)))
    }

    @Test func changerDeMaîtreInvalideLAncienneClé() throws {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        let before = try #require(Vault.keyMaterial)
        #expect(Vault.changeMaster(to: "nouvelle-phrase"))
        let after = try #require(Vault.keyMaterial)
        Vault.lock()

        // C'est pourquoi changer le mot de passe maître doit reconfier la clé à l'Enclave :
        // sans cela le doigt échouerait en silence, et l'on croirait Touch ID cassé.
        #expect(!Vault.unlock(key: before))
        #expect(Vault.unlock(key: after))
    }

    @Test func supprimer() {
        let folder = bench(); defer { clean(folder) }
        Vault.create(master: "phrase-de-passe")
        Vault.save(host: "exemple.fr", user: "marie", password: "s1")
        #expect(Vault.remove(host: "exemple.fr", user: "marie"))
        #expect(!Vault.remove(host: "exemple.fr", user: "marie"))
        #expect(Vault.all().isEmpty)
        #expect(Vault.destroy())
        #expect(!Vault.exists)
    }
}
