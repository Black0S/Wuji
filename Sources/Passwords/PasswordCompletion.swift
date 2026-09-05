import Foundation

/// Ce que la complétion propose, à partir de ce qui est tapé.
///
/// **Une fonction pure, et c'est délibéré.** Toute la partie qui décide — quels comptes
/// remonter, dans quel ordre, et quand ne rien proposer du tout — tient ici, sans champ,
/// sans vue et sans trousseau. C'est la seule partie de la fonction qu'on puisse vérifier
/// par un essai plutôt qu'à l'œil, et c'est aussi celle qui se trompe : le reste pose une
/// carte à un endroit, ce qui se voit tout de suite.
enum PasswordCompletion {

    /// Les comptes à proposer pour cette amorce.
    ///
    /// Les préfixes d'abord, les autres ensuite. Taper `ma` doit remonter `marie` avant
    /// `dimanche@…` : on tape le début de ce qu'on cherche, et une liste qui répond par le
    /// milieu des mots oblige à lire au lieu de choisir. Mais `contains` reste, parce qu'un
    /// identifiant est souvent une adresse et qu'on se souvient du domaine plus souvent que
    /// de ce qui le précède.
    ///
    /// **Rien à proposer quand il n'y a rien à compléter.** Une seule proposition, égale à
    /// ce qui est déjà écrit, n'ajoute rien : la carte s'ouvrirait sous le champ pour
    /// répéter ce qu'il contient, et il faudrait la fermer pour voir la page.
    ///
    /// Cette règle-là ne vaut que pour le champ qu'on écrit. Sur le champ de **mot de
    /// passe**, l'amorce n'est pas ce qu'on tape : c'est l'identifiant déjà saisi à côté,
    /// qui dit seulement de quel compte il s'agit. Il est alors normalement exact — et
    /// refuser de proposer parce qu'il l'est fermerait la liste précisément au moment où
    /// l'on vient chercher le secret. D'où `completing` : l'amorce se complète-t-elle, ou
    /// désigne-t-elle ?
    static func matches(_ accounts: [String], for typed: String,
                        completing: Bool = true) -> [String] {
        let needle = fold(typed)
        guard !needle.isEmpty else { return accounts }

        var prefixed: [String] = []
        var contained: [String] = []
        for account in accounts {
            let candidate = fold(account)
            if candidate.hasPrefix(needle) { prefixed.append(account) }
            else if candidate.contains(needle) { contained.append(account) }
        }
        let result = prefixed + contained
        if completing, result.count == 1, fold(result[0]) == needle { return [] }
        return result
    }

    /// Casse et accents mis de côté : on tape `Marie` pour `marie`, et `elodie` pour
    /// `élodie`. Un identifiant qu'on n'atteint qu'en le réécrivant exactement n'est pas
    /// complété, il est recopié.
    private static func fold(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
