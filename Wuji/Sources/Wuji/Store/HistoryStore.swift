import Foundation
import SQLite3

struct HistoryEntry {
    let url: URL
    let title: String
    let visits: Int
    let lastVisit: Date
}

/// L'historique de navigation.
///
/// **SQLite cette fois, contrairement à la session.** La différence n'est pas la taille
/// mais l'usage : une session se réécrit en entier et se relit une fois par lancement,
/// un historique s'interroge à chaque frappe dans l'omnibox et grossit indéfiniment.
/// Relire un JSON de cent mille lignes à chaque touche serait absurde.
///
/// Le classement mélange **fréquence et récence** — ce que les navigateurs appellent
/// frecency. Le seul nombre de visites remonterait éternellement un site consulté cent
/// fois l'an dernier ; la seule date remonterait ce qu'on vient d'ouvrir par erreur.
@MainActor
final class HistoryStore {

    // nonisolated : la base doit être fermée depuis `deinit`, qui n'est pas isolé.
    nonisolated(unsafe) private var database: OpaquePointer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Wuji", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path

        guard sqlite3_open(path, &database) == SQLITE_OK else {
            database = nil
            return
        }
        execute("""
            CREATE TABLE IF NOT EXISTS visits (
                url        TEXT PRIMARY KEY,
                title      TEXT NOT NULL DEFAULT '',
                visits     INTEGER NOT NULL DEFAULT 1,
                last_visit REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS visits_last ON visits(last_visit DESC);
        """)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: - Écriture

    /// Une page vue. Les pages internes et les schémas non web n'ont rien à faire ici.
    func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }

        let sql = """
            INSERT INTO visits (url, title, visits, last_visit) VALUES (?, ?, 1, ?)
            ON CONFLICT(url) DO UPDATE SET
                visits = visits + 1,
                last_visit = excluded.last_visit,
                -- Un titre vide arrive quand la page commence à peine à charger : il ne
                -- doit pas écraser celui qu'on avait déjà.
                title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, url.absoluteString)
        bind(statement, 2, title)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    // MARK: - Lecture

    func search(_ query: String, limit: Int = 5) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Le classement : la fréquence pèse, la récence départage. `visits` est passé au
        // logarithme pour qu'un site vu mille fois ne noie pas tout le reste.
        let sql = """
            SELECT url, title, visits, last_visit FROM visits
            WHERE url LIKE ? OR title LIKE ?
            ORDER BY (LOG(visits + 1) * 86400 + last_visit) DESC
            LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(trimmed)%"
        bind(statement, 1, pattern)
        bind(statement, 2, pattern)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var results: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: raw)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            results.append(HistoryEntry(url: url,
                                        title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                                        visits: Int(sqlite3_column_int(statement, 2)),
                                        lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return results
    }

    /// Les pages les plus récentes, pour la page d'historique. Bornée : au-delà de
    /// quelques centaines de lignes, on ne parcourt plus, on cherche — et la recherche
    /// est là pour ça.
    func recent(limit: Int = 600) -> [HistoryEntry] {
        var statement: OpaquePointer?
        let sql = "SELECT url, title, visits, last_visit FROM visits ORDER BY last_visit DESC LIMIT ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: raw)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            results.append(HistoryEntry(url: url,
                                        title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                                        visits: Int(sqlite3_column_int(statement, 2)),
                                        lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return results
    }

    func delete(url: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM visits WHERE url = ?;", -1, &statement, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, url)
        sqlite3_step(statement)
    }

    var count: Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM visits;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    // MARK: - Purge

    /// Rétention : la spec §4.1 la veut configurable, et c'est ce qui rend « vos données
    /// restent chez vous » vérifiable plutôt que déclaratif.
    func purge(olderThan days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        execute("DELETE FROM visits WHERE last_visit < \(cutoff);")
    }

    func clear() {
        execute("DELETE FROM visits;")
        execute("VACUUM;")
    }

    // MARK: - Interne

    private func execute(_ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    /// `SQLITE_TRANSIENT` : sans lui, SQLite garde le pointeur d'une chaîne Swift qui
    /// aura disparu avant l'exécution.
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }
}
