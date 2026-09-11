import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Ouvrir le coffre avec Touch ID.
///
/// **Il faut dire tout de suite ce que cela suppose.** Touch ID ne rend pas une clé : il
/// authentifie. Pour qu'un doigt ouvre le coffre, la clé doit dormir quelque part de gardé —
/// et sur macOS, le seul endroit vraiment gardé est l'Enclave sécurisée, qu'on atteint par
/// le trousseau du système avec un contrôle d'accès biométrique. C'est la seule API qui
/// existe, et c'est celle que tous les gestionnaires de mots de passe empruntent.
///
/// **Elle demande un droit qu'une copie compilée ici n'a pas** — `keychain-access-groups`,
/// que seule une signature portant un identifiant d'équipe peut déclarer. Mesuré :
/// `errSecMissingEntitlement`. D'où deux chemins, et ils ne protègent pas pareil.
///
/// Ce qui est confié, dans les deux cas : **trente-deux octets**, la clé du coffre. Seuls,
/// ils n'ouvrent rien — il faut aussi `coffre.json`, qui est ailleurs. Aucun identifiant,
/// aucun mot de passe de site, aucun nom d'hôte ne quitte jamais le coffre chiffré, et Wuji
/// ne lit toujours rien de ce que Safari ou l'app Mots de passe ont rangé de leur côté.
///
/// **C'est optionnel, et éteint par défaut.** Le mot de passe maître ouvre toujours le
/// coffre ; Touch ID n'est qu'un raccourci, qu'on allume soi-même et qui s'éteint en une
/// ligne — l'éteindre efface la clé confiée. Qui ne veut rien de tout cela n'a rien à
/// faire : il ne se passera rien.
///
/// **`biometryCurrentSet` et pas `biometryAny`.** Ajouter une empreinte au Mac invalide
/// l'élément, et le coffre redemande le mot de passe maître. C'est voulu : sans cela,
/// quelqu'un qui aurait la machine déverrouillée cinq minutes pourrait ajouter son propre
/// doigt et ouvrir le coffre pour toujours.
@MainActor
enum Biometrics {

    private static let service = "Wuji — clé du coffre"
    /// L'élément gardé par l'Enclave. C'est le seul que Wuji dépose dans le trousseau, et
    /// seulement là où le système l'accepte — voir `enable(key:)`.
    private static let sealedAccount = "coffre"
    /// L'ancien élément du repli, gardé ici pour une seule raison : l'effacer.
    private static let legacyAccount = "coffre-logiciel"

    /// Le repli, quand l'Enclave n'est pas accessible : un fichier à nous.
    ///
    /// **Il a quitté le trousseau, et il faut dire pourquoi.** Le trousseau attache chaque
    /// élément à l'application qui l'a créé, reconnue à sa signature. Une application
    /// compilée ici est signée *ad hoc* : son empreinte change à chaque compilation —
    /// mesuré, deux compilations d'affilée donnent deux empreintes — et le système ne
    /// reconnaît donc jamais Wuji d'un lancement à l'autre. Il demandait le mot de passe du
    /// trousseau **à chaque déverrouillage**, et « Toujours autoriser » n'autorisait que la
    /// version en cours d'exécution. Un coffre dont la promesse est de ne jamais faire appel
    /// au mot de passe du Mac le réclamait ainsi plus souvent que n'importe quoi d'autre —
    /// et apprenait au passage à approuver les demandes du trousseau sans les lire, ce qui
    /// est pire que la barrière que cela achetait.
    ///
    /// **Ce qu'on perd, exactement.** Une autre application qui aurait voulu cette clé
    /// déclenchait une demande d'autorisation ; elle ne la déclenche plus. Cela arrêtait
    /// quelqu'un au clavier, jamais du code tournant déjà sous votre compte — qui, lui,
    /// pouvait aussi bien lire le fichier du coffre. Sur une version signée avec une
    /// identité stable, rien de tout cela ne s'applique : l'Enclave prend la clé, et le
    /// trousseau ne demande rien.
    /// Le dossier se passe de l'extérieur pour la même raison que celui de `Storage` : un
    /// essai qui vérifie qu'on sait ranger une clé ne doit pas écraser la vraie.
    static var directory: URL = Storage.directory

    private static var softFile: URL {
        directory.appendingPathComponent("coffre-touchid.bin")
    }

    /// La pierre tombale de l'ancien élément du trousseau.
    ///
    /// **Parce qu'on ne peut pas toujours l'effacer.** Mesuré : un binaire signé autrement
    /// que celui qui a posé l'élément reçoit `-25244`, « Invalid attempt to change the owner
    /// of this item », et l'élément survit. Une copie compilée ici change de signature à
    /// chaque compilation : Wuji ne peut donc pas garantir la suppression de ce qu'une
    /// version précédente a déposé. Sans cette trace, éteindre Touch ID n'aurait pas tenu —
    /// l'élément resté au trousseau aurait continué de répondre « oui, c'est allumé » au
    /// lancement suivant.
    private static var tombstone: URL {
        directory.appendingPathComponent("coffre-touchid.ancien-efface")
    }

    /// Reste-t-il, malgré tout, un ancien élément dans le trousseau ?
    ///
    /// La page des réglages le dit quand c'est le cas : c'est un secret de plus dans le
    /// trousseau de quelqu'un, et il a le droit de savoir qu'il est là et que Wuji ne s'en
    /// sert plus. Il s'enlève depuis « Trousseaux d'accès », en cherchant le nom du service.
    static var leftoverInKeychain: Bool {
        guard exists(legacyAccount) else { return false }
        // Tant que la clé n'a pas déménagé, l'élément sert encore : ce n'est pas un reste,
        // c'est la clé. Le dire avant l'heure ferait chercher un problème qui n'existe pas.
        return FileManager.default.fileExists(atPath: softFile.path)
            || FileManager.default.fileExists(atPath: tombstone.path)
    }

    /// Ce qui garde la clé, une fois qu'elle est confiée.
    enum Protection {
        /// L'Enclave sécurisée : la clé n'est rendue **que** contre une empreinte
        /// reconnue, et aucun code ne peut la lire sans elle.
        case secureEnclave
        /// Un fichier de Wuji, plus une vérification du doigt faite par Wuji.
        ///
        /// **C'est plus faible, et il faut le dire.** L'empreinte est bien vérifiée par le
        /// système, mais la clé n'y est pas liée : elle est dans un fichier que votre compte
        /// peut lire. Du code tournant déjà sous ce compte la lirait — comme il lirait le
        /// fichier du coffre, d'ailleurs. Ce que cela ne protège pas, c'est ce que le
        /// trousseau ne protégeait pas non plus une fois l'autorisation donnée.
        ///
        /// Ce repli n'existe que parce que le premier chemin exige un droit
        /// (`keychain-access-groups`) qu'une application signée ad-hoc n'a pas : la version
        /// publiée, signée Developer ID, prend l'autre.
        case softwareGate
    }

    /// La machine sait-elle lire un doigt, et est-ce configuré ?
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Le nom que le système donne à sa biométrie — on l'affiche tel quel plutôt que de
    /// dire « Touch ID » sur une machine qui, un jour, en aura une autre.
    static var name: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID:  return "Face ID"
        case .opticID: return "Optic ID"
        default:       return "Touch ID"
        }
    }

    /// La clé est-elle déjà confiée à l'Enclave ?
    ///
    /// **Sans demander le doigt.** Savoir qu'un élément existe ne doit pas coûter une
    /// empreinte : la page des réglages pose la question à chaque affichage, et un lecteur
    /// qui s'allumerait pour dessiner un interrupteur serait insupportable.
    static var isEnabled: Bool {
        protection != nil
    }

    /// Comment la clé est gardée, `nil` si elle ne l'est pas.
    static var protection: Protection? {
        if exists(sealedAccount) { return .secureEnclave }
        if FileManager.default.fileExists(atPath: softFile.path) { return .softwareGate }
        // L'ancien élément du trousseau compte encore : sa clé est bonne, elle n'a pas
        // encore déménagé. Éteindre Touch ID sans prévenir parce qu'on a changé d'endroit
        // serait retirer une fonction que personne n'a demandé à retirer.
        // L'ancien élément ne compte que tant qu'on n'a pas dit qu'on en avait fini.
        if exists(legacyAccount), !FileManager.default.fileExists(atPath: tombstone.path) {
            return .softwareGate
        }
        return nil
    }

    private static func exists(_ account: String) -> Bool {
        var query = base(account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // `interactionNotAllowed` veut dire « il est là, mais il faut s'authentifier » —
        // c'est-à-dire exactement ce qu'on cherchait à savoir.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Confie la clé du coffre à l'Enclave. Remplace ce qui s'y trouvait.
    @discardableResult
    static func enable(key: Data) -> Protection? {
        disable()

        // **Le bon chemin d'abord.** Il échoue avec `errSecMissingEntitlement` (-34018)
        // sur un paquet signé ad-hoc : un élément à contrôle biométrique demande le droit
        // `keychain-access-groups`, que seule une signature portant un identifiant d'équipe
        // peut déclarer. La version publiée l'a ; celle qu'on compile ici, non.
        if let access = SecAccessControlCreateWithFlags(
            nil,
            // `…ThisDeviceOnly` : la clé ne part pas dans une sauvegarde ni sur une autre
            // machine. Un coffre synchronisé sans qu'on l'ait demandé n'est plus un coffre.
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet, nil) {
            var query = base(sealedAccount)
            query[kSecAttrAccessControl as String] = access
            query[kSecValueData as String] = key
            if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return .secureEnclave }
        }

        // Le repli, **assumé et annoncé** : la clé est rangée dans un fichier à nous, lisible
        // par le seul compte de l'utilisateur, et c'est Wuji qui demandera le doigt avant de
        // la lire. Voir `softFile` pour ce que cela coûte et pourquoi c'est le bon échange.
        do {
            // On repart de zéro : s'il restait un ancien élément au trousseau, il vient
            // d'être écarté par `disable()`, et la pierre tombale reste posée.
            try key.write(to: softFile, options: [.atomic, .completeFileProtection])
            // Les droits POSIX explicitement, et pas seulement le masque du processus : un
            // fichier de clé lisible par le groupe n'est pas un fichier de clé.
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: softFile.path)
            return .softwareGate
        } catch {
            return nil
        }
    }

    @discardableResult
    static func disable() -> Bool {
        let a = SecItemDelete(base(sealedAccount) as CFDictionary) == errSecSuccess
        let b = (try? FileManager.default.removeItem(at: softFile)) != nil
        forgetLegacyItem()
        return a || b
    }

    /// Se débarrasse de l'ancien élément du trousseau — ou, à défaut, cesse de le compter.
    ///
    /// La suppression est tentée d'abord : elle réussit quand la signature qui l'a posé est
    /// encore reconnue. Quand elle échoue — le cas d'une copie recompilée —, on pose la
    /// pierre tombale, et Wuji n'ira plus jamais y lire. Ce qui reste au trousseau est dit
    /// dans les réglages plutôt que passé sous silence.
    static func forgetLegacyItem() {
        SecItemDelete(base(legacyAccount) as CFDictionary)
        if exists(legacyAccount) {
            try? Data().write(to: tombstone, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: tombstone)
        }
    }

    /// Sort la clé du trousseau et la range dans le fichier. Une seule fois, au premier
    /// déverrouillage qui suit la mise à jour.
    private static func moveOutOfKeychain(reason: String) async -> Data? {
        guard let clé = await Self.read(service: service, account: legacyAccount,
                                        reason: reason) else { return nil }
        try? clé.write(to: softFile, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: softFile.path)
        forgetLegacyItem()
        return clé
    }

    /// Demande le doigt, et rend la clé s'il est reconnu.
    ///
    /// **Hors de l'acteur principal.** `SecItemCopyMatching` bloque son fil pendant que la
    /// feuille de Touch ID est affichée : le faire ici figerait la fenêtre entière le temps
    /// que quelqu'un pose son doigt — c'est-à-dire précisément pendant qu'il regarde
    /// l'écran.
    static func key(reason: String) async -> Data? {
        switch protection {
        case .secureEnclave:
            // La lecture elle-même demande l'empreinte : c'est le système qui tranche, et
            // rien ne sort si le doigt n'est pas reconnu.
            return await Self.read(service: service, account: sealedAccount, reason: reason)
        case .softwareGate:
            // Ici c'est nous qui demandons, puis nous qui lisons. La différence est réelle
            // et elle est écrite dans les réglages, sur la ligne qui allume la fonction.
            guard await Self.verify(reason: reason) else { return nil }
            if let clé = try? Data(contentsOf: softFile) { return clé }
            // **Le déménagement, une fois.** La clé est encore dans le trousseau : la lire
            // coûte une dernière demande de mot de passe — celle-là est inévitable, on ne
            // peut pas sortir une clé de là sans franchir sa garde. Elle passe ensuite dans
            // le fichier, l'élément est effacé, et plus jamais rien n'est demandé.
            return await Self.moveOutOfKeychain(reason: reason)
        case nil:
            return nil
        }
    }

    /// Demande le doigt, sans rien lire.
    private nonisolated static func verify(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }

    /// La lecture elle-même, **hors de tout acteur** : la requête est construite là où elle
    /// est exécutée, ce qui évite de faire traverser un dictionnaire non `Sendable` d'un
    /// domaine d'isolement à l'autre.
    private nonisolated static func read(service: String, account: String,
                                         reason: String) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            // Une seule demande par déverrouillage : sans cela, macOS peut redemander le
            // doigt pour la même opération si elle s'étire.
            context.touchIDAuthenticationAllowableReuseDuration = 10

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return data
        }.value
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
