import Testing
import Foundation
@testable import Wuji

/// Les magasins : ce qui écrit vos données sur le disque.
///
/// C'est la seule partie du code où une erreur est **irréversible**. Un blocage raté se
/// voit et se corrige ; une session écrasée ne revient pas. Ces tests travaillent dans un
/// dossier temporaire — un test qui vérifierait qu'on sait écrire une session en écrasant
/// la vraie détruirait les onglets de quelqu'un pour prouver qu'on sait les garder.
@MainActor
struct StoreTests {

    private func temporaire() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuji-test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func session(spaces: Int, tabs: Int) -> StoredSession {
        StoredSession(spaces: (0..<spaces).map { index in
            StoredSpace(name: "Espace \(index)", symbol: "square.stack", folders: [],
                        loose: (0..<tabs).map {
                            StoredTab(url: "https://exemple.com/\($0)", title: "Page \($0)")
                        },
                        currentTab: 0)
        }, currentSpace: 0)
    }

    // MARK: - La session

    @Test func laSessionSeRelitTelleQuElleAÉtéÉcrite() {
        let store = SessionStore(directory: temporaire())
        store.save(session(spaces: 2, tabs: 3))

        let relue = store.load()
        #expect(relue?.spaces.count == 2)
        #expect(relue?.spaces.first?.loose.count == 3)
        #expect(relue?.spaces.first?.loose.first?.url == "https://exemple.com/0")
    }

    @Test func unFichierAbsentNeRendRienEtNePlantePas() {
        #expect(SessionStore(directory: temporaire()).load() == nil)
    }

    @Test func unFichierAbîméNeRendRienEtNePlantePas() throws {
        // Le cas d'un plantage pendant l'écriture, ou d'un fichier corrigé à la main de
        // travers. Il doit se solder par « pas de session », jamais par un arrêt.
        let dossier = temporaire()
        let store = SessionStore(directory: dossier)
        try Data("{ ceci n'est pas du JSON".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test func écrireDeuxFoisNeLaisseQuUneSession() {
        let store = SessionStore(directory: temporaire())
        store.save(session(spaces: 3, tabs: 1))
        store.save(session(spaces: 1, tabs: 1))
        // L'écriture est atomique : jamais de reste de la précédente collé à la nouvelle.
        #expect(store.load()?.spaces.count == 1)
    }

    @Test func uneSessionSurvitÀUneNouvelleInstance() {
        let dossier = temporaire()
        SessionStore(directory: dossier).save(session(spaces: 1, tabs: 4))
        #expect(SessionStore(directory: dossier).load()?.spaces.first?.loose.count == 4)
    }

    // MARK: - Les règles de l'utilisateur

    @Test func uneRègleSurvitÀUneNouvelleInstance() {
        let dossier = temporaire()
        let règle = #"{"action":{"type":"block"},"trigger":{"url-filter":"pub"}}"#
        UserRules(directory: dossier).add(règle)
        #expect(UserRules(directory: dossier).rules == [règle])
    }

    @Test func uneMêmeRègleNEstPasAjoutéeDeuxFois() {
        let store = UserRules(directory: temporaire())
        store.add("une règle")
        store.add("une règle")
        #expect(store.rules.count == 1)
    }

    @Test func retirerUneRègleLaRetireVraiment() {
        let dossier = temporaire()
        let store = UserRules(directory: dossier)
        store.add("a"); store.add("b")
        store.remove("a")
        #expect(UserRules(directory: dossier).rules == ["b"])
    }

    // MARK: - Les favoris

    @Test func unFavoriSurvitÀUneNouvelleInstance() throws {
        let dossier = temporaire()
        let page = try #require(URL(string: "https://exemple.com/article"))
        let ajouté = FavoritesStore(directory: dossier).toggle(url: page, title: "Un article")
        #expect(ajouté)
        #expect(FavoritesStore(directory: dossier).contains(page))
    }

    @Test func basculerDeuxFoisRevientAuPointDeDépart() throws {
        // `⌘D` sur une page déjà en favori ne peut vouloir dire que « finalement, non » :
        // c'est le même geste qui pose et qui retire.
        let dossier = temporaire()
        let page = try #require(URL(string: "https://exemple.com/article"))
        let store = FavoritesStore(directory: dossier)
        _ = store.toggle(url: page, title: "Un article")
        let retiré = store.toggle(url: page, title: "Un article")
        #expect(!retiré)
        #expect(!FavoritesStore(directory: dossier).contains(page))
    }

    // MARK: - L'historique

    @Test func uneVisiteSeRetrouveDansLesRécentes() throws {
        let store = HistoryStore(directory: temporaire())
        let page = try #require(URL(string: "https://exemple.com/mozart"))
        store.record(url: page, title: "Mozart, une biographie")
        #expect(store.recent().contains { $0.title == "Mozart, une biographie" })
    }

    @Test func revoirUnePageNeLaCompteQuUneFois() throws {
        // La table est indexée par adresse : reculer et revenir sur la même page ne doit
        // pas remplir l'historique de la même ligne.
        let store = HistoryStore(directory: temporaire())
        let page = try #require(URL(string: "https://exemple.com/page"))
        store.record(url: page, title: "Page")
        store.record(url: page, title: "Page")
        #expect(store.recent().filter { $0.title == "Page" }.count == 1)
    }

    @Test func effacerLHistoriqueLeVideVraiment() throws {
        let store = HistoryStore(directory: temporaire())
        store.record(url: try #require(URL(string: "https://exemple.com/a")), title: "A")
        store.clear()
        #expect(store.recent().isEmpty)
    }
}
