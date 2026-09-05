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
        guard let item = downloads.item(for: download) else {
            return downloads.destination(for: suggestedFilename)
        }

        // **Une reprise reprend le même fichier.** WebKit redemande la destination après
        // `resumeDownload`, et le nom est déjà pris — par ce téléchargement-là. En chercher
        // un libre donnerait « gros 2.bin », reparti de zéro, et laisserait le morceau déjà
        // reçu orphelin dans le dossier. Une destination déjà posée ne peut venir que d'ici,
        // donc d'un premier passage : c'est le signe d'une reprise, et il suffit.
        if let existing = item.destination { return existing }

        let destination = downloads.destination(for: suggestedFilename)
        item.filename = destination.lastPathComponent
        item.destination = destination
        refreshDownloads(reload: true)
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = downloads.item(for: download) else { return }
        // Les chiffres définitifs sont relevés **avant** de fermer la ligne : après, plus
        // rien ne la met à jour, et c'est précisément ce qu'on veut.
        item.seal()
        item.state = .finished
        item.observation = nil
        refreshDownloads(reload: true)
        // Sans signal, un téléchargement terminé est invisible : le fichier est arrivé
        // quelque part et rien ne le dit.
        layout.toast.show("\(item.filename) · téléchargé") { [weak self] in self?.showDownloads(nil) }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = downloads.item(for: download) else { return }
        item.seal()
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

// MARK: - Ce que le lecteur de PDF rend

extension AppDelegate {

    /// Le bouton d'enregistrement du lecteur PDF de WebKit.
    ///
    /// **Ce bouton ne faisait rien, et c'était invisible.** Mesuré : on clique la flèche du
    /// lecteur, aucun fichier n'arrive, aucune erreur ne s'affiche. La raison est que
    /// WebKit ne passe pas par `WKDownload` pour ce geste — le document est déjà en mémoire
    /// depuis qu'on le regarde, il n'y a rien à télécharger. Il appelle son délégué
    /// d'interface avec les octets, par une méthode que `WKUIDelegate` ne déclare pas
    /// publiquement. Une application qui ne l'implémente pas ne reçoit rien, et le bouton
    /// reste muet.
    ///
    /// **Le sélecteur est privé, l'échec est inoffensif.** WebKit demande
    /// `respondsToSelector:` avant d'appeler : si Apple renomme la méthode, on cesse
    /// simplement d'être appelé — exactement l'état d'avant. Rien ne casse, rien ne plante.
    ///
    /// Ce qui arrive ensuite est le chemin ordinaire : le nom que WebKit propose, la
    /// destination que le magasin réserve — donc jamais un fichier écrasé —, une ligne dans
    /// la liste, et le Finder qui montre où c'est tombé.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(_ webView: WKWebView, saveDataToFile data: Data,
                 suggestedFilename: String, mimeType: String, originatingURL: URL) {
        let destination = downloads.destination(for: suggestedFilename)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            layout.toast.show("Écriture impossible dans le dossier des téléchargements")
            return
        }
        downloads.add(DownloadItem(saved: data, to: destination, source: originatingURL))
        layout.toast.show("« \(destination.lastPathComponent) » téléchargé") { [weak self] in
            self?.showDownloads(nil)
        }
    }
}
