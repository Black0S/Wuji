import AppKit
import WebKit

/// Les identifiants : ce que la page demande, ce que le coffre rend.
///
/// Une extension et non une classe à part : `AppDelegate` reste un seul objet — il
/// tient l'état de la fenêtre, et le couper en morceaux qui se renvoient la balle
/// coûterait plus cher que le fichier long qu'on remplace. Ce qu'on gagne ici, c'est
/// de pouvoir ouvrir le sujet qu'on cherche sans traverser le reste.
extension AppDelegate {

    /// Ce qu'une page peut demander à propos des mots de passe — et ce qu'elle ne peut pas.
    ///
    /// **L'hôte vient de WebKit, jamais de la page.** `message.frameInfo.securityOrigin`
    /// est l'origine réelle du cadre qui parle ; la page n'a aucun moyen de la mentir. Si
    /// l'hôte venait de la charge utile, `mauvais.example` demanderait l'identifiant de la
    /// banque en s'annonçant sous son nom, et le navigateur le lui donnerait. C'est la seule
    /// protection qui compte dans tout ce fichier.
    func handlePasswordMessage(_ message: WKScriptMessage, payload: [String: Any]) {
        guard settings.passwordsEnabled, message.frameInfo.isMainFrame,
              let webView = message.webView else { return }
        let host = message.frameInfo.securityOrigin.host
        // **Rien en clair — sauf chez soi.**
        //
        // Un identifiant proposé sur `http://` est proposé à quiconque écoute le réseau : la
        // règle est donc HTTPS. Mais elle vise le réseau, et un service qu'on héberge sur sa
        // propre machine n'en traverse aucun — `localhost`, `.local`, les plages privées.
        // Les exclure ferait payer la précaution exactement là où elle ne protège de rien,
        // et priverait de la fonction les seuls sites qu'on ne peut pas mettre en HTTPS
        // sans monter une autorité de certification pour soi.
        let secure = message.frameInfo.securityOrigin.protocol == "https"
        guard !host.isEmpty, secure || AppDelegate.isLocalHost(host) else { return }

        switch payload["action"] as? String {
        case "ask":
            fillIfPossible(host: host, in: webView)
        case "complete":
            complete(host: host, payload: payload, in: webView)
        case "dismiss":
            layout.suggestions.dismiss()
        case "save":
            let user = (payload["user"] as? String) ?? ""
            guard let password = payload["password"] as? String, !password.isEmpty else { return }
            offerToSave(host: host, user: user, password: password)
        default:
            break
        }
    }

    /// Remplit, **quand il n'y a rien à choisir**.
    ///
    /// Un seul compte connu pour cet hôte : on remplit. Plusieurs : on ne devine pas, et on
    /// n'ouvre pas non plus une question par-dessus une page qui vient d'arriver — le champ
    /// reste vide, et le menu du cadenas de la barre donne la liste. Choisir à la place de
    /// quelqu'un entre deux comptes, c'est le connecter au mauvais.
    func fillIfPossible(host: String, in webView: WKWebView) {
        let accounts = Vault.accounts(for: host)
        guard accounts.count == 1, let user = accounts.first,
              let password = Vault.password(host: host, user: user) else { return }
        webView.evaluateJavaScript(PasswordForm.fill(user: user, password: password))
    }

    /// Ouvre la complétion sous le champ que la page vient de désigner.
    ///
    /// **La position vient de la page, l'identité vient de WebKit.** Un rectangle est une
    /// donnée inoffensive : au pire il ouvre la carte au mauvais endroit. L'hôte, lui,
    /// décide quels comptes existent — il ne peut donc venir que de `securityOrigin`, et
    /// c'est déjà tranché à l'entrée.
    ///
    /// **Et la page ne voit jamais la liste.** Elle est dessinée par AppKit, dans la
    /// fenêtre : un site ne peut ni la lire, ni compter ses lignes, ni deviner sous quels
    /// noms on est inscrit chez lui. Une liste posée dans le DOM aurait rendu tout cela
    /// lisible par le premier script de la page.
    ///
    /// Le coffre répond de mémoire, sans toucher au disque : il est déchiffré une fois à
    /// l'ouverture, et une frappe n'y coûte qu'un parcours de tableau. C'est la contrepartie
    /// d'un coffre à soi — le trousseau du système, lui, demandait un aller-retour à
    /// `securityd` à chaque lecture.
    func complete(host: String, payload: [String: Any], in webView: WKWebView) {
        // **Un coffre fermé n'est pas un coffre vide.** Ne rien afficher laisserait croire
        // qu'aucun identifiant n'existe pour ce site alors qu'il y en a peut-être dix
        // derrière le mot de passe maître — et il n'y aurait, à cet endroit, aucun moyen de
        // s'en apercevoir. On ne demande pas non plus le mot de passe de force : la ligne
        // se propose, elle n'interrompt pas.
        guard Vault.isUnlocked else {
            guard Vault.exists, let anchor = anchor(from: payload, in: webView) else {
                return layout.suggestions.dismiss()
            }
            layout.suggestions.onUnlock = { [weak self] in self?.askToUnlock() }
            layout.suggestions.show([.unlock], under: anchor)
            return
        }
        // Le champ visé voyage jusqu'au choix : c'est lui qui décide de ce qu'on remplit,
        // et il est connu au moment où la liste s'ouvre, pas au moment où l'on clique.
        let field: PasswordForm.Field = payload["champ"] as? String == "secret"
            ? .secret : .account
        let typed = payload["amorce"] as? String ?? ""
        let proposed = PasswordCompletion.matches(Vault.accounts(for: host),
                                                  for: typed, completing: field == .account)
        guard !proposed.isEmpty else { return layout.suggestions.dismiss() }

        guard let anchor = anchor(from: payload, in: webView) else {
            return layout.suggestions.dismiss()
        }
        // **Un identifiant vide n'est pas un identifiant à préserver.** Choisir depuis le
        // champ de mot de passe ne remplit que le mot de passe — c'est le sens du geste —,
        // sauf quand il n'y a rien à côté : n'écrire que le secret laisserait alors un
        // formulaire à moitié rempli, avec un compte que la page ignore.
        let written: PasswordForm.Field =
            field == .secret && typed.trimmingCharacters(in: .whitespaces).isEmpty
            ? .both : field
        layout.suggestions.onChoose = { [weak self, weak webView] user in
            guard let self, let webView else { return }
            fill(host: host, user: user, field: written, in: webView)
        }
        layout.suggestions.show(proposed.map { .account($0) }, under: anchor)
    }

    /// Le rectangle du champ, de la page jusqu'à la fenêtre.
    ///
    /// Deux pièges s'y suivent, et les deux ont posé la carte ailleurs qu'au bon endroit.
    ///
    /// **Le zoom.** La page compte en pixels CSS, la vue en points : à 90 %, oublier le
    /// facteur décale la carte d'un dixième de la hauteur de page — et l'on agrandit les
    /// pages de connexion plus souvent que les autres.
    ///
    /// **Le sens de l'axe.** `WKWebView` est une vue *renversée* : son origine est en haut,
    /// comme celle du DOM, alors que le reste d'AppKit compte depuis le bas. Retourner
    /// l'ordonnée à la main y ajoutait donc un second retournement, et la carte s'ouvrait
    /// en miroir du champ — à `hauteur − y` au lieu de `y`. On demande son sens à la vue et
    /// on laisse `convert` faire le reste : c'est lui qui sait, pas nous.
    private func anchor(from payload: [String: Any], in webView: WKWebView) -> NSRect? {
        guard let x = payload["x"] as? Double, let y = payload["y"] as? Double,
              let width = payload["largeur"] as? Double,
              let height = payload["hauteur"] as? Double, width > 0, height > 0 else {
            return nil
        }
        let zoom = webView.pageZoom
        let top = CGFloat(y) * zoom
        let size = NSSize(width: CGFloat(width) * zoom, height: CGFloat(height) * zoom)
        let originY = webView.isFlipped ? top : webView.bounds.height - top - size.height
        let box = NSRect(origin: NSPoint(x: CGFloat(x) * zoom, y: originY), size: size)
        return layout.suggestions.convert(box, from: webView)
    }

    /// Remplit depuis la liste, et referme.
    ///
    /// **Le mot de passe ne sort pas du coffre pour un identifiant.** Choisir un compte
    /// dans le champ d'identifiant écrit ce compte, et rien d'autre : le secret n'est ni lu,
    /// ni envoyé à la page, ni exposé au risque qu'elle en fasse quelque chose. Il ne quitte
    /// le coffre que lorsque c'est le champ de mot de passe qui a été désigné.
    private func fill(host: String, user: String,
                      field: PasswordForm.Field, in webView: WKWebView) {
        let script: String
        switch field {
        case .account:
            script = PasswordForm.fill(user: user, field: .account)
        case .secret, .both:
            guard let password = Vault.password(host: host, user: user) else {
                layout.toast.show("Le coffre n'a pas rendu ce mot de passe")
                return
            }
            script = field == .secret
                ? PasswordForm.fill(password: password, field: .secret)
                : PasswordForm.fill(user: user, password: password, field: .both)
        }
        webView.evaluateJavaScript(script)
        webView.evaluateJavaScript("window.__wujiCompletionFermée && window.__wujiCompletionFermée()")
    }

    /// Propose d'enregistrer — et ne le fait pas tout seul.
    ///
    /// **Rien n'entre dans le coffre sans un oui.** Un navigateur qui enregistre en
    /// silence range aussi les mots de passe tapés par erreur, ceux d'un compte qu'on ne
    /// veut pas garder, et celui d'un ordinateur qu'on empruntait.
    ///
    /// La question ne se repose pas pour un couple déjà connu au même secret : se faire
    /// demander à chaque connexion si l'on veut enregistrer ce qui l'est déjà, c'est la
    /// façon la plus sûre d'apprendre à répondre non sans lire.
    func offerToSave(host: String, user: String, password: String) {
        guard !layout.toast.isAsking else { return }

        // **Coffre fermé : on propose de l'ouvrir, on ne perd pas la saisie.** Se taire
        // ferait manquer l'enregistrement sans rien dire, et il n'y a pas de seconde
        // chance : le mot de passe qu'on vient de taper ne repassera pas par ici.
        guard Vault.isUnlocked else {
            let title = Vault.exists ? "Déverrouiller pour enregistrer ?"
                                     : "Créer le coffre pour enregistrer ?"
            layout.toast.ask(
                title: title,
                message: "Wuji garde ses identifiants dans son propre coffre, chiffré. "
                    + "\(user.isEmpty ? host : "\(user) sur \(host)") y sera rangé.",
                confirm: Vault.exists ? "Déverrouiller" : "Créer",
                isDestructive: false, onCancel: {}) { [weak self] in
                    self?.askToUnlock { opened in
                        guard opened else { return }
                        self?.offerToSave(host: host, user: user, password: password)
                    }
                }
            return
        }
        if Vault.password(host: host, user: user) == password { return }

        let known = Vault.accounts(for: host).contains(user)
        let title = known ? "Mettre à jour le mot de passe ?" : "Enregistrer ce mot de passe ?"
        let who = user.isEmpty ? host : "\(user) sur \(host)"
        layout.toast.ask(
            title: title,
            message: "\(who). Il ira dans le coffre de Wuji, chiffré avec votre mot de "
                + "passe maître — et nulle part ailleurs.",
            confirm: known ? "Mettre à jour" : "Enregistrer",
            isDestructive: false, onCancel: {}) { [weak self] in
                guard let self else { return }
                let done = Vault.save(host: host, user: user, password: password)
                layout.toast.show(done ? "Mot de passe enregistré pour \(host)"
                                       : "Le coffre a refusé l'enregistrement")
                refreshSettingsPages()
            }
    }

    /// Ce que le menu du cadenas ajoute quand des identifiants existent pour ce site.
    ///
    /// C'est là qu'ils ont leur place : le cadenas parle déjà de l'identité du site et de ce
    /// qu'on lui confie. Remplir depuis ce menu est aussi la seule façon d'entrer un compte
    /// quand il y en a plusieurs — et la seule qui demande un geste, donc la seule qui ne
    /// puisse pas se tromper à votre place.
    func passwordItems(for host: String) -> [ActionItem] {
        guard settings.passwordsEnabled else { return [] }
        let accounts = Vault.accounts(for: host)
        guard !accounts.isEmpty else { return [] }

        var items: [ActionItem] = [.separator]
        for user in accounts {
            items.append(ActionItem(title: "Remplir avec \(user)", symbol: "key",
                                    action: { [weak self] in
                                        self?.fill(host: host, user: user)
                                    }))
        }
        return items
    }

    /// « Remplir avec… », depuis le menu du cadenas. Ce geste-là désigne la connexion
    /// entière et non un champ : il pose les deux.
    private func fill(host: String, user: String) {
        guard let webView = currentTab?.webView else { return }
        fill(host: host, user: user, field: .both, in: webView)
    }
}
