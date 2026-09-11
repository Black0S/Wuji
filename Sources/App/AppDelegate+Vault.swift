import AppKit

/// Le cycle du coffre : le créer, l'ouvrir, le refermer, changer sa clé, le jeter — et ce
/// que la page des réglages en demande.
///
/// **Séparé de la complétion**, qui parle aux pages, alors que ceci parle à l'utilisateur.
/// Les deux tenaient dans un fichier de six cents lignes où il fallait deviner lequel des
/// deux sujets on lisait.
extension AppDelegate {

    // MARK: - Le coffre

    /// Ouvre le coffre, ou le crée s'il n'existe pas encore.
    ///
    /// **La même porte pour les deux**, parce que de l'endroit où l'on clique, c'est la
    /// même intention : accéder à ses identifiants. La différence — créer ou ouvrir — est
    /// dans ce que Wuji sait déjà, pas dans ce qu'on a à décider.
    func askToUnlock(then finish: (@MainActor (Bool) -> Void)? = nil) {
        guard Vault.exists else { return askToCreate(then: finish) }

        // **Le doigt d'abord quand il est proposé, le mot de passe maître ensuite.** Le
        // repli n'est pas une politesse : une empreinte ajoutée ou retirée invalide
        // l'élément, et sans ce repli le coffre deviendrait inouvrable un matin sans
        // qu'on ait rien fait.
        guard Biometrics.isEnabled, Biometrics.isAvailable else {
            return askMasterToUnlock(then: finish)
        }
        Task { @MainActor in
            guard let material = await Biometrics.key(
                    reason: "déverrouiller le coffre de Wuji"),
                  Vault.unlock(key: material) else {
                return askMasterToUnlock(then: finish)
            }
            upgradeBiometricProtection()
            layout.toast.show("Coffre ouvert")
            refreshSettingsPages()
            reproposeCompletion()
            finish?(true)
        }
    }

    /// Reconfie la clé à l'Enclave dès que la version le permet.
    ///
    /// **Sinon la protection faible serait définitive.** Elle est choisie faute de mieux sur
    /// une copie signée ad-hoc ; le jour où Wuji est signé avec un certificat, l'Enclave
    /// devient accessible — mais rien n'irait le voir, et la clé resterait dans son fichier
    /// pour toujours. On réessaie donc au moment où l'on a la clé en main, c'est-à-dire à
    /// l'ouverture du coffre, et on le dit quand ça change.
    private func upgradeBiometricProtection() {
        guard Biometrics.protection == .softwareGate,
              let material = Vault.keyMaterial,
              Biometrics.enable(key: material) == .secureEnclave else { return }
        layout.toast.show("\(Biometrics.name) passe à l'Enclave sécurisée")
    }

    private func askMasterToUnlock(then finish: (@MainActor (Bool) -> Void)? = nil) {
        NativeMenu.secret(
            title: "Déverrouiller le coffre",
            message: "Le mot de passe maître ouvre les identifiants de Wuji. Il n'est écrit "
                + "nulle part : ni sur le disque, ni dans le trousseau de macOS.",
            confirm: "Déverrouiller", confirming: false, in: window) { [weak self] master in
                guard let self else { return }
                let opened = Vault.unlock(master: master)
                layout.toast.show(opened ? "Coffre ouvert"
                                         : "Mot de passe maître refusé")
                refreshSettingsPages()
                if opened { reproposeCompletion() }
                finish?(opened)
            }
    }

    /// Crée le coffre. **Deux champs, et c'est la seule protection qui existe** : un coffre
    /// chiffré n'a pas de récupération, donc une faute de frappe au moment de le créer le
    /// rendrait inouvrable — sans que rien ne le signale avant la prochaine ouverture.
    func askToCreate(then finish: (@MainActor (Bool) -> Void)? = nil) {
        NativeMenu.secret(
            title: "Créer le coffre de Wuji",
            message: "Les identifiants seront chiffrés avec ce mot de passe, dans un fichier "
                + "qui n'appartient qu'à Wuji. Huit caractères au minimum.\n\n"
                + "Il n'y a pas de récupération : oublié, le coffre est perdu. C'est ce que "
                + "« chiffré » veut dire.",
            confirm: "Créer", confirming: true, in: window) { [weak self] master in
                guard let self else { return }
                guard !master.isEmpty else {
                    layout.toast.show("Les deux mots de passe ne correspondent pas")
                    finish?(false)
                    return
                }
                guard master.count >= 8 else {
                    layout.toast.show("Huit caractères au minimum")
                    finish?(false)
                    return
                }
                let made = Vault.create(master: master)
                layout.toast.show(made ? "Coffre créé" : "Le coffre n'a pas pu être écrit")
                refreshSettingsPages()
                finish?(made)
            }
    }

    /// Allume ou éteint l'ouverture par empreinte.
    ///
    /// **Allumer demande le coffre ouvert** : c'est la clé du moment qu'on confie, et elle
    /// n'existe que quand il l'est. Éteindre efface l'élément — il ne reste rien dans le
    /// trousseau du système.
    func setBiometricUnlock(_ enabled: Bool) {
        guard enabled else {
            Biometrics.disable()
            layout.toast.show("\(Biometrics.name) ne déverrouille plus le coffre")
            refreshSettingsPages()
            return
        }
        guard Vault.isUnlocked, let material = Vault.keyMaterial else {
            return askToUnlock { [weak self] opened in
                if opened { self?.setBiometricUnlock(true) }
            }
        }
        switch Biometrics.enable(key: material) {
        case .secureEnclave:
            layout.toast.show("\(Biometrics.name) déverrouille le coffre — la clé est gardée "
                + "par l'Enclave sécurisée")
        case .softwareGate:
            // On ne laisse pas croire à la protection forte quand c'est l'autre : la
            // différence est réelle, et elle se dit au moment où l'on allume.
            layout.toast.show("\(Biometrics.name) déverrouille le coffre — protection "
                + "logicielle, voir la ligne des réglages")
        case nil:
            layout.toast.show("\(Biometrics.name) n'a pas pu recevoir la clé")
        }
        refreshSettingsPages()
    }

    /// Redemande à la page courante d'ouvrir sa complétion, si un champ de connexion y a
    /// encore le curseur. Sans cela, déverrouiller depuis la carte ne rouvre rien : la
    /// feuille a pris le clavier, le champ a perdu le focus, et personne ne repose la
    /// question — alors qu'on venait d'ouvrir le coffre pour ça.
    private func reproposeCompletion() {
        guard let webView = currentTab?.webView else { return }
        webView.evaluateJavaScript(
            "window.__wujiCompletionRelance && window.__wujiCompletionRelance()")
    }

    /// Referme : la clé quitte la mémoire, le contenu aussi.
    func lockVault() {
        Vault.lock()
        layout.suggestions.dismiss()
        layout.toast.show("Coffre verrouillé")
        refreshSettingsPages()
    }

    func askToChangeMaster() {
        guard Vault.isUnlocked else { return askToUnlock() }
        NativeMenu.secret(
            title: "Changer le mot de passe maître",
            message: "Le coffre est rechiffré avec le nouveau. L'ancien ne l'ouvrira plus.",
            confirm: "Changer", confirming: true, in: window) { [weak self] master in
                guard let self else { return }
                guard master.count >= 8 else {
                    layout.toast.show(master.isEmpty
                        ? "Les deux mots de passe ne correspondent pas"
                        : "Huit caractères au minimum")
                    return
                }
                guard Vault.changeMaster(to: master) else {
                    layout.toast.show("Le coffre n'a pas pu être rechiffré")
                    return
                }
                // La clé a changé : celle qui dort dans l'Enclave n'ouvre plus rien. La
                // remplacer plutôt que la laisser aurait fait échouer le doigt en silence,
                // et croire que Touch ID ne marche plus.
                if Biometrics.isEnabled, let material = Vault.keyMaterial {
                    Biometrics.enable(key: material)
                }
                layout.toast.show("Mot de passe maître changé")
                refreshSettingsPages()
            }
    }

    /// Jette le coffre. **Irréversible, et dit comme tel** : c'est la seule action de tout
    /// ce fichier qui détruise quelque chose qu'on ne peut pas retrouver.
    func askToDestroy() {
        guard Vault.exists else { return }
        layout.toast.ask(
            title: "Supprimer le coffre ?",
            message: "Tous les identifiants de Wuji disparaissent, définitivement. Aucune "
                + "récupération n'est possible — exportez-les d'abord si vous les voulez.",
            confirm: "Supprimer", isDestructive: true, onCancel: {}) { [weak self] in
                guard let self else { return }
                Biometrics.disable()
                layout.toast.show(Vault.destroy() ? "Coffre supprimé"
                                                  : "Le coffre n'a pas pu être supprimé")
                refreshSettingsPages()
            }
    }
}
