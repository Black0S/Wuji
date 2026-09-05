import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Ouvrir le coffre avec Touch ID.
///
/// **Il faut dire tout de suite ce que cela suppose.** Touch ID ne rend pas une clé : il
/// authentifie. Pour qu'un doigt ouvre le coffre, la clé doit dormir quelque part que
/// l'Enclave sécurisée garde — et sur macOS, cet endroit est le **trousseau du système**,
/// avec un contrôle d'accès biométrique. Il n'y a pas d'autre porte : c'est la seule API
/// qui existe, et c'est celle que tous les gestionnaires de mots de passe empruntent.
///
/// Ce qui va dans le trousseau, et ce qui n'y va **jamais** :
///
/// - Y va : **trente-deux octets**, la clé du coffre de Wuji. Seuls, ils n'ouvrent rien —
///   il faut aussi le fichier `coffre.json`, qui est ailleurs.
/// - N'y va pas : aucun identifiant, aucun mot de passe de site, aucun nom d'hôte. Le
///   contenu du coffre reste chiffré dans son fichier, et Wuji ne lit toujours rien de ce
///   que Safari ou l'app Mots de passe y ont rangé.
///
/// **C'est optionnel, et éteint par défaut.** Le mot de passe maître ouvre toujours le
/// coffre ; Touch ID n'est qu'un raccourci, qu'on allume soi-même et qui s'éteint en une
/// ligne — l'éteindre efface l'élément. Quelqu'un qui refuse que Wuji touche au trousseau
/// pour quelque raison que ce soit n'a rien à faire : il ne s'y passera rien.
///
/// **`biometryCurrentSet` et pas `biometryAny`.** Ajouter une empreinte au Mac invalide
/// l'élément, et le coffre redemande le mot de passe maître. C'est voulu : sans cela,
/// quelqu'un qui aurait la machine déverrouillée cinq minutes pourrait ajouter son propre
/// doigt et ouvrir le coffre pour toujours.
@MainActor
enum Biometrics {

    private static let service = "Wuji — clé du coffre"
    /// Deux comptes pour deux protections : l'élément gardé par l'Enclave, et celui du
    /// repli. Les distinguer par leur nom évite d'avoir à interroger leur contrôle d'accès
    /// pour savoir lequel on a — une question qui, elle, demanderait un doigt.
    private static let sealedAccount = "coffre"
    private static let softAccount = "coffre-logiciel"

    /// Ce qui garde la clé, une fois qu'elle est confiée.
    enum Protection {
        /// L'Enclave sécurisée : la clé n'est rendue **que** contre une empreinte
        /// reconnue, et aucun code ne peut la lire sans elle.
        case secureEnclave
        /// Le trousseau ordinaire, plus une vérification du doigt faite par Wuji.
        ///
        /// **C'est plus faible, et il faut le dire.** L'empreinte est bien vérifiée par le
        /// système, mais la clé n'y est pas liée : elle est protégée comme n'importe quel
        /// élément du trousseau — une autre application qui la demanderait déclencherait la
        /// demande d'autorisation de macOS, ce qui arrête quelqu'un au clavier, pas du code
        /// qui tourne déjà sous votre compte.
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
        if exists(softAccount) { return .softwareGate }
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

        // Le repli, **assumé et annoncé** : la clé est rangée comme n'importe quel élément
        // du trousseau, et c'est Wuji qui demandera le doigt avant de la lire.
        var query = base(softAccount)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = key
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess ? .softwareGate : nil
    }

    @discardableResult
    static func disable() -> Bool {
        let a = SecItemDelete(base(sealedAccount) as CFDictionary) == errSecSuccess
        let b = SecItemDelete(base(softAccount) as CFDictionary) == errSecSuccess
        return a || b
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
            return await Self.read(service: service, account: softAccount, reason: reason)
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
