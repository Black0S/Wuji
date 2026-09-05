import AppKit

/// Les favicons, récupérées **depuis le site lui-même** (`https://hôte/favicon.ico`).
///
/// C'est une contrainte d'identité, pas un détail d'implémentation : tous les navigateurs
/// grand public passent par un service tiers de résolution de favicons, ce qui revient à
/// annoncer à ce tiers chaque domaine visité. Incompatible avec « aucune requête sortante
/// que vous n'avez pas déclenchée ». Le site que vous visitez sait déjà que vous le visitez.
///
/// Conséquence assumée : pas de favicon quand le site n'en sert pas à cet emplacement.
/// Un globe monochrome fait le repli.
///
/// **Le cache va sur le disque**, dans le dossier de l'application. Sans lui, l'icône d'un
/// site déjà visité repartirait en requête à chaque démarrage — et surtout, les pages
/// internes n'auraient rien à afficher sans aller la chercher elles-mêmes.
@MainActor
final class FaviconStore {

    private var cache: [String: NSImage] = [:]
    /// Hôtes dont on sait qu'ils n'ont rien sur le disque : sans cette liste, chaque
    /// rafraîchissement de la sidebar irait relire le disque pour un fichier absent.
    private var absent: Set<String> = []
    private var pending: Set<String> = []
    private var encoded: [String: String] = [:]

    private let directory: URL

    /// Appelé quand une nouvelle favicon arrive, pour rafraîchir la sidebar.
    var onUpdate: (() -> Void)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Wuji/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func icon(for url: URL?) -> NSImage? {
        guard let host = url?.host() else { return nil }
        if let image = known(host) { return image }
        fetch(host: host)
        return nil
    }

    /// La favicon déjà connue, encodée pour une page interne — **sans jamais rien demander
    /// au réseau**.
    ///
    /// Les pages internes affichaient l'icône par son adresse : ouvrir un historique de
    /// cent lignes tirait cent requêtes vers autant de domaines, d'un coup, parce qu'on
    /// avait ouvert une liste. Certaines ne répondaient jamais, et la page restait en
    /// chargement — barre en travers de l'écran comprise.
    func dataURI(for url: URL) -> String? {
        guard let host = url.host() else { return nil }
        if let uri = encoded[host] { return uri }
        guard let image = known(host),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let uri = "data:image/png;base64,\(png.base64EncodedString())"
        encoded[host] = uri
        return uri
    }

    // MARK: - Interne

    /// Mémoire, puis disque. Le disque n'est lu qu'une fois par hôte et par session.
    private func known(_ host: String) -> NSImage? {
        if let cached = cache[host] { return cached }
        guard !absent.contains(host) else { return nil }
        guard let image = NSImage(contentsOf: file(for: host)), image.isValid else {
            absent.insert(host)
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        cache[host] = image
        return image
    }

    private func fetch(host: String) {
        guard !pending.contains(host),
              let iconURL = URL(string: "https://\(host)/favicon.ico") else { return }
        pending.insert(host)

        Task { [weak self] in
            let data: Data? = await withCheckedContinuation { continuation in
                Fetch.session.dataTask(with: Fetch.request(iconURL)) { data, _, _ in
                    continuation.resume(returning: data)
                }.resume()
            }
            guard let self else { return }
            self.pending.remove(host)
            guard let data, let image = NSImage(data: data), image.isValid else { return }
            image.size = NSSize(width: 16, height: 16)
            self.cache[host] = image
            self.absent.remove(host)
            // Gardée telle que le site l'a servie : la réencoder ferait perdre les
            // formats animés ou multi-tailles pour rien.
            try? data.write(to: self.file(for: host), options: .atomic)
            self.onUpdate?()
        }
    }

    /// Un nom de fichier sûr : un hôte peut contenir « : » ou « / » dans les cas tordus,
    /// et on ne veut pas qu'une adresse décide d'un chemin sur le disque.
    private func file(for host: String) -> URL {
        let safe = host.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_"
        }
        return directory.appendingPathComponent(String(safe) + ".ico")
    }
}
