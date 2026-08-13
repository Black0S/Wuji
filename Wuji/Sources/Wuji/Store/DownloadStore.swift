import Foundation
import WebKit

/// Un téléchargement, tel que la page et les notifications ont besoin de le connaître.
@MainActor
final class DownloadItem {
    enum State {
        case running, finished, failed(String)
    }

    let id = UUID()
    let source: URL
    var filename: String
    var destination: URL?
    var state: State = .running
    var received: Int64 = 0
    var expected: Int64 = 0
    let started = Date()

    /// Retenu pour pouvoir suivre l'avancement et annuler.
    let download: WKDownload

    init(download: WKDownload, source: URL, filename: String) {
        self.download = download
        self.source = source
        self.filename = filename
    }

    var fraction: Double {
        guard expected > 0 else { return 0 }
        return min(1, Double(received) / Double(expected))
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}

/// La liste des téléchargements de la session.
///
/// **En mémoire, pas sur le disque.** Un téléchargement terminé, ce qui en reste est le
/// fichier — il est dans le Finder, sous le nom qu'on lui a donné. Conserver une liste de
/// ce qu'on a téléchargé un mois plus tôt reviendrait à tenir un journal de plus, que
/// personne n'a demandé et que la promesse « aucune trace » rend gênant.
@MainActor
final class DownloadStore {

    private(set) var items: [DownloadItem] = []
    var onChange: (() -> Void)?

    var runningCount: Int { items.filter(\.isRunning).count }

    func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        onChange?()
    }

    func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func changed() { onChange?() }

    func clearFinished() {
        items.removeAll { !$0.isRunning }
        onChange?()
    }

    /// Un nom libre dans le dossier Téléchargements : « fichier.zip », puis
    /// « fichier 2.zip ». Écraser un fichier existant sans le dire serait une perte de
    /// données silencieuse.
    static func destination(for suggested: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggested.isEmpty ? "fichier" : suggested
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
