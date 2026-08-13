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
@MainActor
final class FaviconStore {

    private var cache: [String: NSImage] = [:]
    private var pending: Set<String> = []

    /// Appelé quand une nouvelle favicon arrive, pour rafraîchir la sidebar.
    var onUpdate: (() -> Void)?

    func icon(for url: URL?) -> NSImage? {
        guard let host = url?.host() else { return nil }
        if let cached = cache[host] { return cached }
        fetch(host: host)
        return nil
    }

    private func fetch(host: String) {
        guard !pending.contains(host),
              let iconURL = URL(string: "https://\(host)/favicon.ico") else { return }
        pending.insert(host)

        Task { [weak self] in
            let image: NSImage? = await withCheckedContinuation { continuation in
                URLSession.shared.dataTask(with: iconURL) { data, _, _ in
                    continuation.resume(returning: data.flatMap(NSImage.init(data:)))
                }.resume()
            }
            guard let self else { return }
            self.pending.remove(host)
            guard let image, image.isValid else { return }
            image.size = NSSize(width: 16, height: 16)
            self.cache[host] = image
            self.onUpdate?()
        }
    }
}
