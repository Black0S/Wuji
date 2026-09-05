import Testing
@testable import Wuji

/// Ce qu'un espace privé promet.
///
/// La promesse est simple — *rien ne sera enregistré* — et elle n'a de valeur que si elle
/// vaut pour toute la vie de l'espace. Une bascule privé/normal existait et ne pouvait pas
/// la tenir : le magasin de données est choisi quand une vue web naît, donc rendre un
/// espace privé après coup laissait ses onglets écrire sur le disque, et le rendre normal
/// aurait versé dans une session enregistrée ce qu'il avait promis de ne pas garder.
///
/// Ces tests gardent ce qui reste : la confidentialité se décide à la naissance, et le
/// symbole qui l'annonce ne se change pas.
@MainActor
struct SpaceTests {

    @Test func unEspacePrivéNaîtPrivé() {
        let space = Space.makePrivate()
        #expect(space.isPrivate)
        #expect(space.symbol == Space.privateSymbol)
    }

    @Test func unEspaceOrdinaireNeLEstPas() {
        let space = Space(name: "Personnel", symbol: Space.symbol(forIndex: 0))
        #expect(!space.isPrivate)
        #expect(space.symbol == Space.symbol(forIndex: 0))
    }

    @Test func leSymboleDUnEspacePrivéNeChangePas() {
        // C'est à ce symbole qu'on le reconnaît, et on doit le reconnaître *toujours* de
        // la même façon — sinon la reconnaissance devient une convention personnelle,
        // c'est-à-dire quelque chose qu'on oublie au mauvais moment.
        let space = Space.makePrivate()
        space.symbol = "leaf"
        #expect(space.symbol == Space.privateSymbol)
    }

    @Test func unEspaceOrdinaireGardeLeSymboleQuOnLuiDonne() {
        let space = Space(name: "Travail", symbol: "briefcase")
        space.symbol = "leaf"
        #expect(space.symbol == "leaf")
    }
}
