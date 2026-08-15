import AppKit
import WebKit

/// Les téléchargements.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let destination = DownloadStore.destination(for: suggestedFilename)
        guard let item = downloads.item(for: download) else { return destination }
        item.filename = destination.lastPathComponent
        item.destination = destination
        refreshDownloads(reload: true)
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = downloads.item(for: download) else { return }
        item.state = .finished
        item.observation = nil
        refreshDownloads(reload: true)
        // Sans signal, un téléchargement terminé est invisible : le fichier est arrivé
        // quelque part et rien ne le dit.
        layout.toast.show("\(item.filename) · téléchargé") { [weak self] in self?.showDownloads(nil) }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = downloads.item(for: download) else { return }
        item.state = .failed(error.localizedDescription)
        refreshDownloads(reload: true)
    }

    /// `reload` : à réserver aux changements de composition. Pour le seul avancement, on
    /// pousse les chiffres dans la page — la recharger à chaque paquet reçu la faisait
    /// clignoter et remontait le défilement.
    func refreshDownloads(reload: Bool = false) {
        downloads.changed()
        downloads.items.forEach { $0.sample() }
        let running = downloads.items.filter(\.isActive)
        // Un seul anneau pour tous : la moyenne dit « ça avance », ce qui est la seule
        // question qu'on se pose sans ouvrir la page.
        let fraction = running.isEmpty ? nil : running.reduce(0) { $0 + $1.fraction } / Double(running.count)
        layout.sidebar.updateDownloads(progress: fraction)

        let pages = spaces.flatMap(\.allTabs).filter { $0.url == Self.downloadsPage }
        guard !pages.isEmpty else { return }

        if reload {
            pages.forEach { $0.webView.reload() }
            return
        }
        // Quelques rafraîchissements par seconde suffisent à donner le mouvement ; le
        // rappel d'avancement, lui, se déclenche des dizaines de fois.
        guard Date().timeIntervalSince(lastProgressPush) > 0.15 else { return }
        lastProgressPush = Date()

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        for item in downloads.items where item.isRunning {
            item.sample()
            let detail = "\(formatter.string(fromByteCount: item.received)) sur "
                + (item.expected > 0 ? formatter.string(fromByteCount: item.expected) : "?")
                + " · en cours"
            let script = "window.wujiProgress && window.wujiProgress('\(item.id.uuidString)', "
                + "\(Int(item.fraction * 100)), '\(detail)')"
            pages.forEach { $0.webView.evaluateJavaScript(script) }
        }
    }

    static let downloadsPage = URL(string: "wuji://downloads")!

    @objc func showDownloads(_ sender: Any?) {
        openInternal(Self.downloadsPage)
    }
}
