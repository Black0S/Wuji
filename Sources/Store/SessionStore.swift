import Foundation

/// L'état d'un onglet sur le disque : ce qu'il faut pour le réafficher sans le charger.
struct StoredTab: Codable {
    var url: String?
    var title: String
}

struct StoredFolder: Codable {
    var name: String
    var isExpanded: Bool
    var tabs: [StoredTab]
}

struct StoredSpace: Codable {
    var name: String
    var symbol: String
    var folders: [StoredFolder]
    var loose: [StoredTab]
    /// Rang de l'onglet courant dans l'ordre d'affichage de l'espace.
    var currentTab: Int?
}

struct StoredSession: Codable {
    var spaces: [StoredSpace]
    var currentSpace: Int
}

/// La session sur le disque.
///
/// **JSON et non SQLite**, contrairement à ce que prévoyait la spec §6.4. Une session
/// tient en quelques kilo-octets et se réécrit en entier : une base apporterait ses
/// migrations et son schéma sans rien résoudre ici. Surtout, le fichier reste lisible et
/// modifiable à la main, ce qui est précisément la promesse « vos données vous
/// appartiennent ». SQLite redeviendra le bon outil pour l'historique, qu'on interroge.
///
/// L'écriture est **atomique** : une session à moitié écrite au moment d'un plantage
/// serait pire que pas de session du tout.
@MainActor
final class SessionStore {

    private let url: URL
    private var pendingSave: DispatchWorkItem?

    init(directory: URL = Storage.directory) {
        url = directory.appendingPathComponent("session.json")
    }

    var fileURL: URL { url }

    func load() -> StoredSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    /// Écriture différée : chaque frappe dans un titre de page déclencherait sinon une
    /// écriture disque, pour un état qui aura changé une seconde plus tard.
    func scheduleSave(_ session: @autoclosure @escaping () -> StoredSession) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save(session()) }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func save(_ session: StoredSession) {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
