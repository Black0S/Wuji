import Foundation
import WebKit

/// Un téléchargement, tel que la page et les notifications ont besoin de le connaître.
@MainActor
final class DownloadItem {
    enum State {
        case running, paused, finished, failed(String)
    }

    let id: UUID
    let source: URL
    var filename: String
    var destination: URL?
    var state: State = .running
    let started = Date()

    /// L'avancement vient de l'objet `Progress` du téléchargement, pas d'un compteur qu'on
    /// tiendrait soi-même : `WKDownloadDelegate` n'a aucun rappel par paquet reçu.
    var observation: NSKeyValueObservation?

    /// Nul pendant une pause : mettre en pause, c'est annuler en gardant de quoi
    /// reprendre. WebKit n'a pas d'autre mécanisme.
    var download: WKDownload?
    /// Ce que WebKit rend à l'annulation, et sans quoi une reprise repartirait de zéro.
    var resumeData: Data?

    /// Derniers chiffres connus. Ils survivent à la pause, où l'objet d'avancement
    /// disparaît avec le téléchargement.
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0

    init(download: WKDownload, source: URL, filename: String) {
        id = UUID()
        self.download = download
        self.source = source
        self.filename = filename
    }

    /// Un fichier **déjà reçu**, écrit d'un coup.
    ///
    /// C'est le cas du lecteur PDF de WebKit : le document est en mémoire depuis qu'on le
    /// regarde, et son bouton d'enregistrement rend les octets, pas une adresse. Il n'y a
    /// donc rien à télécharger — mais il y a tout à ranger : la ligne, le nom, la taille,
    /// et la place dans la liste, comme n'importe quel autre fichier.
    init(saved data: Data, to destination: URL, source: URL) {
        id = UUID()
        self.source = source
        filename = destination.lastPathComponent
        self.destination = destination
        received = Int64(data.count)
        expected = Int64(data.count)
        state = .finished
    }

    /// Un téléchargement retrouvé au lancement — voir `DownloadStore.unfinished`.
    init(interrupted stored: StoredDownload) {
        id = stored.id
        source = stored.source
        filename = stored.filename
        destination = stored.destination
        resumeData = stored.resumeData
        received = stored.received
        expected = stored.expected
        state = .failed("Interrompu")
    }

    /// Relève les compteurs — **tant que le téléchargement vit**.
    ///
    /// Une ligne terminée était réinterrogée à chaque rafraîchissement, et affichait alors
    /// ce que l'objet d'avancement de WebKit voulait bien rendre après coup : on a vu un
    /// fichier de 41,9 Mo annoncer 17,1 Mo une fois fini. Des chiffres définitifs sont
    /// définitifs ; les relire, c'est leur donner une chance de mentir.
    func sample() {
        guard isActive, let progress = download?.progress else { return }
        received = progress.completedUnitCount
        if progress.totalUnitCount > 0 { expected = progress.totalUnitCount }
    }

    /// Fige les compteurs sur leur dernière valeur vraie.
    func seal() {
        if let progress = download?.progress {
            received = progress.completedUnitCount
            if progress.totalUnitCount > 0 { expected = progress.totalUnitCount }
        }
        // Un téléchargement fini n'a plus rien à dire : le lâcher rend son objet à WebKit
        // au lieu de le retenir jusqu'à la fermeture de la fenêtre.
        if expected < received { expected = received }
    }

    var fraction: Double {
        guard expected > 0 else { return 0 }
        return min(1, Double(received) / Double(expected))
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// Une pause n'est pas une fin : la ligne reste active, et l'anneau de la sidebar
    /// continue de la compter.
    var isActive: Bool { isRunning || isPaused }

    /// Interrompu par une fermeture, pas par un échec du réseau : la ligne attend un geste.
    var isInterrupted: Bool {
        if case .failed(let reason) = state { return reason == "Interrompu" }
        return false
    }
}

/// La liste des téléchargements de la session.
///
/// Ce qu'un téléchargement inachevé laisse derrière lui.
struct StoredDownload: Codable {
    var id: UUID
    var source: URL
    var filename: String
    var destination: URL?
    var received: Int64
    var expected: Int64
    /// Ce que WebKit rend à l'annulation. Absent quand la fermeture n'a pas laissé le temps
    /// de le demander : la reprise repartira alors de zéro, et le dira.
    var resumeData: Data?
}

/// La liste des téléchargements de la session.
///
/// **Ce qui est fini ne s'enregistre pas ; ce qui ne l'est pas, si.**
///
/// Un téléchargement terminé, ce qui en reste est le fichier — il est dans le Finder, sous
/// le nom qu'on lui a donné. Conserver une liste de ce qu'on a téléchargé un mois plus tôt
/// reviendrait à tenir un journal de plus, que personne n'a demandé et que la promesse
/// « aucune trace » rend gênant. Cette moitié-là de la règle n'a pas changé.
///
/// L'autre moitié manquait. Un fichier de deux gigaoctets interrompu par une fermeture
/// était perdu avec sa liste : le morceau reçu restait sur le disque sans que rien ne sache
/// à quoi il correspondait. Ce qui est **inachevé** survit donc — l'adresse, le fichier
/// visé, ce qui a été reçu, et de quoi reprendre quand WebKit a bien voulu le rendre. Il
/// disparaît à la seconde où il se termine.
@MainActor
final class DownloadStore {

    private(set) var items: [DownloadItem] = []
    var onChange: (() -> Void)?

    private let index: URL

    init(root: URL = Storage.directory) {
        index = root.appendingPathComponent("downloads.json")
    }

    /// Relit ce qui était en cours au dernier arrêt.
    ///
    /// Rien n'est repris tout seul : les lignes reviennent marquées « interrompu », avec
    /// leur bouton. Reprendre un téléchargement de deux gigaoctets sur un partage de
    /// connexion parce que le navigateur a redémarré serait une décision qu'on n'a pas prise.
    func restore() {
        guard let data = try? Data(contentsOf: index),
              let stored = try? JSONDecoder().decode([StoredDownload].self, from: data) else {
            return
        }
        items = stored.map(DownloadItem.init(interrupted:))
        onChange?()
    }

    /// Écrit ce qui reste à finir. Appelé quand la composition change et à la fermeture.
    func persist() {
        let unfinished = items.filter { $0.isActive || $0.isInterrupted }.map {
            StoredDownload(id: $0.id, source: $0.source, filename: $0.filename,
                           destination: $0.destination, received: $0.received,
                           expected: $0.expected, resumeData: $0.resumeData)
        }
        guard !unfinished.isEmpty else {
            try? FileManager.default.removeItem(at: index)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(unfinished) else { return }
        try? data.write(to: index, options: .atomic)
    }

    var runningCount: Int { items.filter(\.isRunning).count }

    func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        onChange?()
    }

    func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func item(id: String?) -> DownloadItem? {
        items.first { $0.id.uuidString == id }
    }

    func remove(_ item: DownloadItem) {
        items.removeAll { $0 === item }
        onChange?()
    }

    func changed() { onChange?() }

    func clearFinished() {
        items.removeAll { !$0.isActive }
        onChange?()
    }

    /// Un nom libre dans le dossier Téléchargements : « fichier.zip », puis
    /// « fichier 2.zip ». Écraser un fichier existant sans le dire serait une perte de
    /// données silencieuse.
    ///
    /// **Et un nom qu'aucun téléchargement en cours n'a déjà pris.** Le disque ne suffit
    /// pas : WebKit demande la destination bien avant de créer le fichier, donc deux
    /// téléchargements lancés dans la même seconde sur le même nom trouvaient tous deux la
    /// place libre et repartaient avec la même. Mesuré : deux liens vers le même fichier
    /// cliqués coup sur coup n'en livraient qu'un. La réservation vit dans la liste — c'est
    /// elle qui sait ce qui est en vol.
    func destination(for suggested: String) -> URL {
        // **Seuls les téléchargements encore en vol retiennent un nom.** Un terminé a
        // laissé son fichier : c'est le disque qui parle pour lui. Le compter ici
        // interdirait de reprendre le nom d'un fichier qu'on vient d'effacer — mesuré, on
        // obtenait « doublon 2.txt » là où « doublon.txt » était redevenu libre.
        Self.destination(for: suggested, in: Self.downloadsFolder,
                         taken: Set(items.filter(\.isActive).compactMap(\.destination)))
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// La règle seule, sans disque ni WebKit, pour qu'elle se vérifie.
    static func destination(for suggested: String, in folder: URL, taken: Set<URL>) -> URL {
        // Un nom vide, ou qui ne serait qu'un chemin : le suggéré vient du serveur, et un
        // serveur peut proposer « ../../ailleurs ». On ne garde que le dernier segment.
        let proposed = (suggested as NSString).lastPathComponent
        let name = proposed.isEmpty || proposed == "." || proposed == ".." ? "fichier" : proposed

        func free(_ url: URL) -> Bool {
            !taken.contains(url) && !FileManager.default.fileExists(atPath: url.path)
        }

        var candidate = folder.appendingPathComponent(name)
        guard !free(candidate) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        } while !free(candidate)
        return candidate
    }
}
