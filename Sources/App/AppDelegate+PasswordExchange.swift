import AppKit

/// Faire entrer et sortir des identifiants : l'export d'un autre gestionnaire, et celui
/// que Wuji écrit à son tour.
extension AppDelegate {

    // MARK: - Entrer, sortir

    /// Exporte le coffre en CSV, au format que tout le monde relit.
    ///
    /// **Ce qui sort est en clair, et c'est inévitable** : un export chiffré que seul Wuji
    /// relit ne serait pas un export. La seule chose honnête est de le dire au moment où on
    /// le demande, et de laisser choisir l'endroit — pas de l'écrire d'office dans les
    /// téléchargements, où il resterait.
    func exportPasswords() {
        guard Vault.isUnlocked else {
            return askToUnlock { [weak self] opened in
                if opened { self?.exportPasswords() }
            }
        }
        let entries = Vault.all()
        guard !entries.isEmpty else {
            return layout.toast.show("Le coffre est vide")
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "identifiants-wuji.csv"
        panel.prompt = "Exporter"
        panel.message = "Le fichier sera en clair. Rangez-le comme un mot de passe, "
            + "ou supprimez-le après usage."

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let text = PasswordImport.csv(entries.map {
                PasswordImport.Credential(host: $0.host, user: $0.user, password: $0.password)
            })
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                layout.toast.show("\(entries.count) identifiant"
                    + "\(entries.count > 1 ? "s exportés" : " exporté") — le fichier est en clair")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                layout.toast.show("Écriture impossible")
            }
        }
        guard let window else { return handle(panel.runModal()) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { handle(response) }
        }
    }

    /// Importer l'export de l'app **Mots de passe** de macOS.
    ///
    /// **Wuji ne peut pas lire ce trousseau-là**, et aucun navigateur tiers ne le peut : les
    /// identifiants de Safari et de l'app Mots de passe vivent dans le trousseau iCloud, sous
    /// des groupes d'accès qui appartiennent à Apple. Mesuré ici — une requête sur les
    /// éléments synchronisés rend `errSecItemNotFound`, et Wuji ne voit que ce qu'il a
    /// lui-même rangé. Reste la porte que le système ouvre volontairement : l'export.
    ///
    /// **On demande avant d'écrire.** Un import verse des dizaines d'identifiants dans le
    /// coffre ; le nombre est annoncé, et le fichier nommé, avant que rien n'y entre.
    func importPasswords() {
        guard Vault.isUnlocked else {
            return askToUnlock { [weak self] opened in
                if opened { self?.importPasswords() }
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.prompt = "Lire"
        panel.message = "Choisissez le fichier exporté par l'app Mots de passe "
            + "(Fichier ▸ Exporter tous les mots de passe…)."

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                layout.toast.show("Fichier illisible — il doit être en UTF-8")
                return
            }
            let read = PasswordImport.parse(text)
            guard !read.credentials.isEmpty else {
                layout.toast.show("Aucun identifiant lu dans « \(url.lastPathComponent) » — "
                    + "il faut les colonnes URL, Username et Password")
                return
            }
            let rest = read.skipped > 0
                ? " \(read.skipped) ligne\(read.skipped > 1 ? "s" : "") sans hôte, compte "
                    + "ou mot de passe seront ignorée\(read.skipped > 1 ? "s" : "")."
                : ""
            layout.toast.ask(
                title: "Importer \(read.credentials.count) identifiant"
                    + "\(read.credentials.count > 1 ? "s" : "") ?",
                message: "Depuis « \(url.lastPathComponent) ». Ils iront dans le coffre de "
                    + "Wuji, chiffrés.\(rest) Le fichier, lui, est en clair : pensez à le "
                    + "supprimer.",
                confirm: "Importer", isDestructive: false, onCancel: {}) { [weak self] in
                    self?.write(read.credentials, from: url)
                }
        }

        guard let window else { return handle(panel.runModal()) }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { handle(response) }
        }
    }

    /// Range ce qui a été lu, et dit ce qui est passé.
    ///
    /// Rien du contenu n'est journalisé : ni un hôte, ni un compte, ni bien sûr un secret.
    /// Le seul retour est un compte de lignes — c'est tout ce qu'il faut pour savoir si
    /// l'import a marché, et tout ce qu'on peut dire sans le raconter.
    private func write(_ credentials: [PasswordImport.Credential], from url: URL) {
        // **Un seul chiffrement pour tout le lot.** Ranger deux cents lignes une par une
        // rechiffrerait et réécrirait le coffre entier deux cents fois — mesuré à 7 ms
        // pour le lot, contre plus d'une seconde ligne à ligne.
        let written = Vault.saveAll(credentials.map {
            Vault.Entry(host: $0.host, user: $0.user, password: $0.password)
        })
        let refused = credentials.count - written
        layout.toast.show(refused == 0
            ? "\(written) identifiant\(written > 1 ? "s" : "") importé\(written > 1 ? "s" : "") — "
                + "supprimez « \(url.lastPathComponent) », il est en clair"
            : "\(written) importé\(written > 1 ? "s" : ""), \(refused) refusé"
                + "\(refused > 1 ? "s" : "") par le coffre")
        refreshSettingsPages()
    }

    func handlePasswordAction(_ action: String, payload: [String: Any]) {
        let host = payload["host"] as? String ?? ""
        let user = payload["user"] as? String ?? ""
        switch action {
        case "forget-password":
            Vault.remove(host: host, user: user)
            refreshSettingsPages()
        case "import-passwords":
            importPasswords()
        case "export-passwords":
            exportPasswords()
        case "unlock-vault":
            askToUnlock()
        case "lock-vault":
            lockVault()
        case "change-master":
            askToChangeMaster()
        case "destroy-vault":
            askToDestroy()
        case "copy-password":
            // **Le secret ne passe pas par la page.** Il va du coffre au presse-papiers,
            // en Swift, sans jamais traverser le JavaScript des réglages — une page interne
            // reste une page, et ce qui y entre peut en ressortir.
            guard let password = Vault.password(host: host, user: user) else {
                layout.toast.show("Le coffre n'a pas rendu ce mot de passe")
                return
            }
            Self.copy(password)
            layout.toast.show("Mot de passe de \(host) copié")
        default:
            break
        }
    }
}
