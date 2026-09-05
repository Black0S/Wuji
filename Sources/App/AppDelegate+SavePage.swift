import AppKit
import WebKit

/// Enregistrer la page qu'on regarde.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    /// `⌘S` — la page, telle qu'elle est, dans un fichier.
    ///
    /// **Deux formats, et ils ne servent pas à la même chose.** L'archive web garde la page
    /// vivante : son HTML, ses images, ses feuilles de style, réunis dans un fichier que
    /// Safari et Wuji rouvrent tel quel, liens compris. Le PDF garde la page **figée** :
    /// il se lit partout, s'annote, s'imprime, et ne dépendra jamais d'un moteur.
    ///
    /// Le choix est fait dans le panneau d'enregistrement, par l'extension du nom : c'est là
    /// qu'on décide de toute façon où le fichier va, et une question de plus avant celle-là
    /// serait une question de trop.
    @objc func savePage(_ sender: Any?) {
        guard let tab = currentTab, let url = tab.url, !isBlank(tab) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.saveName(for: url, title: tab.title)
        panel.allowedContentTypes = [.webArchive, .pdf]
        panel.prompt = "Enregistrer"
        panel.message = "Archive web pour garder la page navigable, PDF pour la figer."

        let write: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            if destination.pathExtension.lowercased() == "pdf" {
                savePDF(of: tab, to: destination)
            } else {
                saveArchive(of: tab, to: destination)
            }
        }

        guard let window else { return write(panel.runModal()) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { write(response) }
        }
    }

    /// L'archive : ce que WebKit a déjà en mémoire, écrit d'un bloc.
    private func saveArchive(of tab: Tab, to destination: URL) {
        tab.webView.createWebArchiveData { [weak self] result in
            MainActor.assumeIsolated {
                self?.finish(result, at: destination, kind: "Archive")
            }
        }
    }

    /// Le PDF : la page **entière**, et pas ce qui tient à l'écran.
    ///
    /// Sans configuration, WebKit rend le PDF de la zone visible. Un article de trois écrans
    /// s'enregistrait alors sur un seul, coupé au milieu d'un paragraphe — un fichier qui a
    /// l'air d'avoir marché et qui ne contient pas ce qu'on voulait.
    private func savePDF(of tab: Tab, to destination: URL) {
        tab.webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                self?.finish(result, at: destination, kind: "PDF")
            }
        }
    }

    /// Écrit, puis le dit — et dit aussi quand ça n'a pas marché.
    ///
    /// Un enregistrement muet est indistinguable d'un enregistrement raté : on va vérifier
    /// dans le Finder, ce qui est exactement le travail qu'un message évite.
    private func finish(_ result: Result<Data, any Error>, at destination: URL, kind: String) {
        switch result {
        case .success(let data):
            do {
                try data.write(to: destination, options: .atomic)
                layout.toast.show("\(kind) enregistrée · \(destination.lastPathComponent)") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                layout.toast.show("Écriture impossible : \(error.localizedDescription)")
            }
        case .failure(let error):
            layout.toast.show("\(kind) impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - Mode lecture

    /// `⇧⌘R` — l'article, et rien d'autre.
    ///
    /// **Une bascule qui n'en est pas une, et c'est volontaire.** Entrer transforme le
    /// document ; sortir le recharge. Garder l'original de côté pour le remettre voudrait
    /// dire retenir une page entière par onglet, et la remettre telle qu'elle était
    /// demanderait de rejouer ce que ses scripts avaient fait — ce qu'aucun navigateur ne
    /// sait faire. Recharger rend exactement la page, et coûte ce que coûte un ⌘R.
    @objc func toggleReader(_ sender: Any?) {
        guard let tab = currentTab, !isBlank(tab) else { return }
        if readingTabs.contains(tab.id) {
            readingTabs.remove(tab.id)
            tab.webView.reload()
            syncChrome()
            return
        }
        tab.webView.evaluateJavaScript(Reader.enter) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard found as? Bool == true else {
                    // Une page d'accueil ou une application web n'a pas d'article. Le dire
                    // vaut mieux que d'afficher un cadre vide en prétendant avoir travaillé.
                    self.layout.toast.show("Rien qui ressemble à un article sur cette page")
                    return
                }
                self.readingTabs.insert(tab.id)
                self.syncChrome()
            }
        }
    }

    // MARK: - Traduire

    /// Traduit la page vers la langue du système.
    ///
    /// **Rien ne sort de la machine.** Les modèles sont ceux que macOS a installés ; si le
    /// couple de langues manque, Wuji le dit et renvoie aux réglages du système plutôt que
    /// de déclencher un téléchargement d'un gigaoctet derrière un clic sur « traduire ».
    ///
    /// Il n'y a pas de retour : c'est le document qui est modifié, comme dans le mode
    /// lecture, et recharger rend la page d'origine. Garder les deux versions en mémoire
    /// pour une bascule coûterait une page entière par onglet.
    @objc func translatePage(_ sender: Any?) {
        guard let tab = currentTab, !isBlank(tab) else { return }
        let target = Locale.current.language

        Task { @MainActor in
            guard let raw = try? await tab.webView.evaluateJavaScript(Translator.collect) as? [String],
                  !raw.isEmpty else {
                layout.toast.show("Rien à traduire sur cette page")
                return
            }

            // La langue se devine sur un échantillon, pas sur la première phrase : un titre
            // en anglais sur une page française tromperait la reconnaissance.
            let sample = raw.prefix(60).joined(separator: " ")
            guard let source = Translator.language(of: sample) else {
                layout.toast.show("Langue de la page non reconnue")
                return
            }
            guard source.languageCode != target.languageCode else {
                layout.toast.show("Cette page est déjà dans votre langue")
                return
            }
            guard await Translator.isReady(from: source, to: target) else {
                layout.toast.show("Modèle de traduction absent — Réglages Système › "
                    + "Général › Langue et région")
                return
            }

            layout.toast.show("Traduction en cours…")
            do {
                let translated = try await Translator.translate(raw, from: source, to: target)
                _ = try? await tab.webView.evaluateJavaScript(Translator.apply(translated))
                layout.toast.show("Page traduite sur cet appareil · recharger pour l'original")
            } catch {
                layout.toast.show("Traduction impossible : \(error.localizedDescription)")
            }
        }
    }

    /// Un nom de fichier tiré du titre, et de l'adresse à défaut.
    ///
    /// Le titre est ce qu'on reconnaîtra dans six mois ; l'adresse ne se lit pas. Les
    /// caractères que le système refuse — la barre oblique, le deux-points — sont remplacés
    /// plutôt que retirés : « Actualité : Paris » deviendrait sinon « Actualité Paris »,
    /// avec un espace double dont personne ne sait d'où il vient.
    static func saveName(for url: URL, title: String) -> String {
        let source = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = source.isEmpty ? (url.host() ?? "page") : source
        let cleaned = base.map { character -> Character in
            "/\\:?%*|\"<>".contains(character) ? "-" : character
        }
        // Le système d'exploitation coupe à 255 octets ; un titre long, en accents, y arrive
        // plus vite qu'on ne croit.
        return String(String(cleaned).prefix(120)) + ".webarchive"
    }
}
