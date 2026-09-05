import Testing
import AppKit
@testable import Wuji

/// Le raccourci écrit et la touche réelle ne doivent pas pouvoir diverger.
///
/// Les menus déclarent leur raccourci **tel qu'il s'affiche** — « ⇧⌘T » — et `NativeMenu`
/// en tire ce qu'AppKit attend. C'est ce qui a coûté un libellé menteur du temps où les
/// deux se déclaraient séparément : la feuille annonçait un raccourci qui n'était plus
/// celui du menu système, et un libellé qui ment sur ce qu'il faut taper est pire que pas
/// de libellé du tout.
@MainActor
struct NativeMenuTests {

    @Test func unRaccourciSimple() {
        let (key, modifiers) = NativeMenu.shortcut("⌘T")
        #expect(key == "t")
        #expect(modifiers == [.command])
    }

    @Test func laToucheDescendEnMinuscule() {
        // Une majuscule ajoute un ⇧ implicite du côté d'AppKit : « ⇧⌘T » se serait affiché
        // « ⇧⇧⌘T », et la touche aurait demandé deux fois la même chose.
        let (key, modifiers) = NativeMenu.shortcut("⇧⌘T")
        #expect(key == "t")
        #expect(modifiers == [.command, .shift])
    }

    @Test func lesModificateursSAccumulentDansNimporteQuelOrdre() {
        #expect(NativeMenu.shortcut("⌥⌘N").1 == [.command, .option])
        #expect(NativeMenu.shortcut("⌘⌥N").1 == [.command, .option])
    }

    @Test func unRaccourciAbsentNeDonneAucuneTouche() {
        let (key, modifiers) = NativeMenu.shortcut(nil)
        #expect(key.isEmpty)
        #expect(modifiers.isEmpty)
    }

    @Test func lesTouchesQuiNeSontPasDesLettres() {
        // « ⌘, » pour les réglages, « ⌘+ » pour le zoom : elles n'ont pas de casse, et la
        // mise en minuscule ne doit pas les abîmer.
        #expect(NativeMenu.shortcut("⌘,").0 == ",")
        #expect(NativeMenu.shortcut("⌘+").0 == "+")
    }

    /// Un menu vide ne s'ouvre pas : AppKit afficherait un rectangle d'une ligne de haut,
    /// qui ne dit rien et se referme au premier clic.
    @Test func unMenuSansEntréeNexistePas() {
        #expect(NativeMenu.make([]) == nil)
        #expect(NativeMenu.make([.separator, .separator]) == nil)
    }

    @Test func lesSéparateursRestentDesSéparateurs() {
        let menu = NativeMenu.make([ActionItem(title: "Un"), .separator, ActionItem(title: "Deux")])
        #expect(menu?.items.count == 3)
        #expect(menu?.items[1].isSeparatorItem == true)
    }

    /// La cible d'une entrée est retenue par l'entrée elle-même.
    ///
    /// `NSMenuItem.target` est une référence **faible** : sans l'ancrage dans
    /// `representedObject`, la fermeture mourrait entre la construction du menu et le clic,
    /// et l'entrée ne ferait rien — sans rien signaler.
    @Test func uneEntréeRetientSaFermeture() {
        let menu = NativeMenu.make([ActionItem(title: "Agir", action: {})])
        #expect(menu?.items.first?.target != nil)
        #expect(menu?.items.first?.representedObject != nil)
    }
}

/// La citation d'une sélection dans le menu contextuel.
///
/// `NSMenu` tronque de lui-même, mais au milieu du libellé : le guillemet fermant partait
/// et on ne savait plus où finissait ce qu'on avait sélectionné. La coupe se fait donc ici.
@MainActor
struct SelectionTitleTests {

    @Test func uneSélectionCourtePasseEntière() {
        #expect(AppDelegate.searchTitle(for: "mozart") == "Rechercher « mozart »")
    }

    @Test func uneSélectionLongueEstCoupéeAvantLeGuillemet() {
        let long = String(repeating: "a", count: 200)
        let titre = AppDelegate.searchTitle(for: long)
        #expect(titre.hasSuffix("… »"))
        #expect(titre.count < 80)
    }

    @Test func lesRetoursÀLaLigneNeCassentPasLaLigne() {
        #expect(AppDelegate.searchTitle(for: "deux\nmots") == "Rechercher « deux mots »")
    }
}

/// Reconnaître un script utilisateur.
///
/// Deux signes, et ils ne disent pas la même chose. Le suffixe `.user.js` est une
/// **déclaration d'intention** : la convention de Greasemonkey, respectée par Greasy Fork
/// et OpenUserJS, et elle vaut qu'on court-circuite l'affichage. Le contenu, lui, est un
/// **constat** : il se vérifie après coup, sur la page, sans rien empêcher de s'afficher.
@MainActor
struct UserScriptDetectionTests {

    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func leSuffixeConvenu() {
        #expect(AppDelegate.looksLikeUserScript(url("https://greasyfork.org/scripts/1/code/loop.user.js")))
    }

    @Test func uneRequêteNeCacheParLeSuffixe() {
        // Greasy Fork ajoute une version en paramètre : le suffixe se lit sur le chemin,
        // et le chercher dans l'adresse entière l'aurait manqué.
        #expect(AppDelegate.looksLikeUserScript(url("https://greasyfork.org/code/loop.user.js?version=1420")))
    }

    @Test func unScriptOrdinaireNEnEstPasUn() {
        #expect(!AppDelegate.looksLikeUserScript(url("https://exemple.fr/app.js")))
        // Le piège inverse : le mot dans le chemin, pas en suffixe.
        #expect(!AppDelegate.looksLikeUserScript(url("https://exemple.fr/user.js/doc")))
    }

    @Test func unePageOrdinaireNEnEstPasUn() {
        #expect(!AppDelegate.looksLikeUserScript(url("https://exemple.fr/")))
    }
}
