import Testing
import Foundation
@testable import Wuji

/// Savoir s'il existe une version plus récente.
///
/// Deux façons de se tromper, et la seconde est la pire : annoncer une mise à jour qui
/// n'existe pas fait perdre une minute ; **taire celle qui existe** laisse quelqu'un sur
/// une version dont un défaut a peut-être déjà été corrigé.
///
/// Le piège classique est la comparaison alphabétique : « 0.10.0 » vient après « 0.9.0 »
/// dans les nombres et avant dans les lettres. Un navigateur resterait alors bloqué sur sa
/// version 0.9 pour toujours.
@MainActor
struct UpdateCheckTests {

    @Test func laComparaisonEstNumériqueEtNonAlphabétique() {
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.99.99"))
    }

    @Test func laMêmeVersionNEnEstPasUneNouvelle() {
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        // Les longueurs inégales se complètent par des zéros : c'est la même version.
        #expect(!UpdateCheck.isNewer("0.1", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1"))
    }

    @Test func onNeRétrogradePas() {
        #expect(!UpdateCheck.isNewer("0.0.9", than: "0.1.0"))
    }

    @Test func lÉtiquetteEstLueTellementQuElleSoitÉcrite() {
        // Les étiquettes de release sont écrites à la main : elles varient.
        #expect(UpdateCheck.version(in: "v0.2.0") == [0, 2, 0])
        #expect(UpdateCheck.version(in: "V - 0.1.0") == [0, 1, 0])
        #expect(UpdateCheck.version(in: "Wuji 1.2.3 (bêta)") == [1, 2, 3])
        #expect(UpdateCheck.version(in: "0.2") == [0, 2])
    }

    @Test func uneÉtiquetteSansNuméroNAnnonceRien() {
        // Le cas réel du dépôt : la première release est étiquetée « latest ». Une telle
        // étiquette ne doit pas être prise pour une version, ni provoquer d'annonce.
        #expect(UpdateCheck.version(in: "latest") == nil)
        #expect(!UpdateCheck.isNewer("latest", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.2.0", than: "inconnue"))
    }
}
