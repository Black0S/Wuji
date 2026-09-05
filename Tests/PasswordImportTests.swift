import Testing
import Foundation
@testable import Wuji

/// Lire l'export de l'app **Mots de passe** de macOS.
///
/// **Le lecteur CSV est écrit à la main, et il le fallait.** Un mot de passe contient des
/// virgules, des guillemets, parfois un retour à la ligne ; couper sur les virgules donne
/// des secrets tronqués — et un secret tronqué qui entre dans le trousseau est pire qu'un
/// import raté, parce qu'il ne se voit qu'à la prochaine connexion.
struct PasswordImportTests {

    private func credentials(_ csv: String) -> [PasswordImport.Credential] {
        PasswordImport.parse(csv).credentials
    }

    @Test func leFormatDeLAppMotsDePasse() {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        Exemple,https://exemple.fr/connexion,marie@exemple.fr,secret,,
        """
        #expect(credentials(csv) == [PasswordImport.Credential(
            host: "exemple.fr", user: "marie@exemple.fr", password: "secret")])
    }

    @Test func lOrdreDesColonnesNeCompteBas() {
        // Chrome et Firefox n'écrivent pas les mêmes colonnes dans le même ordre. On les
        // cherche par leur nom : prendre « la deuxième colonne » importerait un jour des
        // notes personnelles à la place des identifiants.
        let csv = """
        password,url,username
        secret,exemple.fr,marie
        """
        #expect(credentials(csv) == [PasswordImport.Credential(
            host: "exemple.fr", user: "marie", password: "secret")])
    }

    @Test func sansEnTêteReconnaissableOnNeDevinePas() {
        #expect(PasswordImport.parse("a,b,c\n1,2,3") == PasswordImport.Result())
        #expect(PasswordImport.parse("") == PasswordImport.Result())
    }

    @Test func unSecretÀVirgulesEtÀGuillemetsResteEntier() {
        let csv = """
        url,username,password
        exemple.fr,marie,"a,b\"\"c"
        """
        #expect(credentials(csv).first?.password == #"a,b"c"#)
    }

    @Test func unSecretÀRetourÀLaLigneResteEntier() {
        let csv = "url,username,password\nexemple.fr,marie,\"deux\nlignes\"\n"
        #expect(credentials(csv).first?.password == "deux\nlignes")
    }

    @Test func lesFinsDeLigneWindowsNeLaissentPasDeRetourChariot() {
        let csv = "url,username,password\r\nexemple.fr,marie,secret\r\n"
        #expect(credentials(csv) == [PasswordImport.Credential(
            host: "exemple.fr", user: "marie", password: "secret")])
    }

    @Test func lHôteSeDégageDeToutesLesFormes() {
        #expect(PasswordImport.host(from: "https://exemple.fr/a/b?c=1") == "exemple.fr")
        #expect(PasswordImport.host(from: "exemple.fr") == "exemple.fr")
        #expect(PasswordImport.host(from: "http://Exemple.FR:8080") == "exemple.fr")
        #expect(PasswordImport.host(from: "  ") == nil)
    }

    @Test func lesLignesIncomplètesSontComptéesEtÉcartées() {
        let csv = """
        url,username,password
        exemple.fr,marie,secret
        exemple.fr,,sans-compte
        ,marc,sans-hôte
        exemple.fr,marc,
        """
        let read = PasswordImport.parse(csv)
        // « 1 importé » sans reste laisserait croire que le fichier n'en contenait qu'un.
        #expect(read.credentials.count == 1)
        #expect(read.skipped == 3)
    }

    @Test func ceQuOnÉcritSeRelit() {
        // L'export doit se réimporter — ici et ailleurs : les colonnes sont celles de l'app
        // Mots de passe. Un aller-retour qui perdrait une virgule perdrait un mot de passe.
        let originals = [
            PasswordImport.Credential(host: "exemple.fr", user: "marie", password: #"a,b"c"#),
            PasswordImport.Credential(host: "autre.net", user: "marc", password: "deux\nlignes"),
            PasswordImport.Credential(host: "site.io", user: "élodie", password: "simple")
        ]
        #expect(PasswordImport.parse(PasswordImport.csv(originals)).credentials == originals)
        #expect(PasswordImport.csv(originals)
                .hasPrefix("Title,URL,Username,Password,Notes,OTPAuth"))
    }

    @Test func laLigneVideFinaleNEstPasUneLigneÉcartée() {
        let read = PasswordImport.parse("url,username,password\nexemple.fr,marie,secret\n")
        #expect(read.credentials.count == 1)
        #expect(read.skipped == 0)
    }
}
