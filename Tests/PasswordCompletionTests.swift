import Testing
import Foundation
@testable import Wuji

/// Ce que la complétion propose, et ce qu'elle refuse de proposer.
///
/// **La seule partie de la fonction qui décide.** Le reste pose une carte sous un champ,
/// ce qui se voit ; ici on choisit quels comptes remontent et dans quel ordre, ce qui ne se
/// voit qu'au moment où l'on se connecte au mauvais.
struct PasswordCompletionTests {

    private let comptes = ["marc@exemple.fr", "marie@exemple.fr", "élodie@autre.net"]

    @Test func sansAmorceOnProposeTout() {
        #expect(PasswordCompletion.matches(comptes, for: "") == comptes)
        // Des espaces ne sont pas une amorce : un champ qu'on vient de vider en laisse.
        #expect(PasswordCompletion.matches(comptes, for: "   ") == comptes)
    }

    @Test func lePréfixeRemonteAvantLeMilieu() {
        // « ma » commence `marc` et `marie` ; il ne se trouve nulle part ailleurs.
        #expect(PasswordCompletion.matches(comptes, for: "ma")
                == ["marc@exemple.fr", "marie@exemple.fr"])
    }

    @Test func leMilieuCompteAussi() {
        // On se souvient du domaine plus souvent que de ce qui le précède.
        #expect(PasswordCompletion.matches(comptes, for: "exemple")
                == ["marc@exemple.fr", "marie@exemple.fr"])
    }

    @Test func lOrdreMetLesPréfixesDevant() {
        let liste = ["zoe@marque.fr", "marc@exemple.fr"]
        // `marc` commence par l'amorce, `zoe@marque.fr` ne fait que la contenir.
        #expect(PasswordCompletion.matches(liste, for: "mar")
                == ["marc@exemple.fr", "zoe@marque.fr"])
    }

    @Test func laCasseEtLesAccentsNeSéparentPas() {
        #expect(PasswordCompletion.matches(comptes, for: "MARC") == ["marc@exemple.fr"])
        // Taper `elodie` doit atteindre `élodie` : un identifiant qu'on n'atteint qu'en le
        // réécrivant exactement n'est pas complété, il est recopié.
        #expect(PasswordCompletion.matches(comptes, for: "elodie") == ["élodie@autre.net"])
    }

    @Test func rienÀCompléterNePropopseRien() {
        // Le compte est déjà écrit en entier : la carte s'ouvrirait pour répéter le champ,
        // et il faudrait la fermer pour voir la page.
        #expect(PasswordCompletion.matches(comptes, for: "marie@exemple.fr").isEmpty)
        #expect(PasswordCompletion.matches(comptes, for: "MARIE@exemple.fr").isEmpty)
    }

    @Test func uneSeuleRéponseIncomplèteResteProposée() {
        // `elodie` ne fait pas le compte entier : il reste quelque chose à compléter.
        #expect(PasswordCompletion.matches(comptes, for: "elo") == ["élodie@autre.net"])
    }

    @Test func surLeChampDeMotDePasseLExactitudeNeFermePas() {
        // L'amorce y est l'identifiant déjà saisi à côté : il est normalement exact, et
        // refuser de proposer parce qu'il l'est fermerait la liste au moment précis où
        // l'on vient chercher le secret.
        #expect(PasswordCompletion.matches(comptes, for: "marie@exemple.fr", completing: false)
                == ["marie@exemple.fr"])
    }

    @Test func ceQuiNeCorrespondÀRienNeProposeRien() {
        #expect(PasswordCompletion.matches(comptes, for: "zzz").isEmpty)
        #expect(PasswordCompletion.matches([], for: "ma").isEmpty)
    }
}
