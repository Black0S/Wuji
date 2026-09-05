import CommonCrypto
import CryptoKit
import Foundation

/// Le coffre de Wuji : ses identifiants, chiffrés, chez lui.
///
/// **Wuji ne touche plus au trousseau de macOS.** Ni pour lire, ni pour écrire, ni pour
/// ranger sa propre clé — un coffre dont la clé dort ailleurs n'est pas un coffre, c'est un
/// renvoi. Ce qui est ici est à Wuji : un fichier, chiffré, que rien d'autre sur la machine
/// ne sait ouvrir.
///
/// **Ce que ce choix coûte, et il faut le dire.** macOS a un trousseau, et il est meilleur
/// que tout ce qu'on écrira jamais : déverrouillé avec la session, sauvegardé par Time
/// Machine, synchronisé par iCloud, inspectable par son propriétaire. En le quittant, on
/// perd tout cela — et surtout, **un mot de passe maître oublié est un coffre perdu.** Il
/// n'y a pas de récupération : c'est ce que « chiffré » veut dire. En échange, rien de ce
/// que Wuji garde ne dépend d'un compte Apple, d'iCloud, ou d'une autorisation que le
/// système peut redemander.
///
/// **La forme.** Un mot de passe maître, dérivé en clé par PBKDF2-HMAC-SHA512 — 210 000
/// tours, la recommandation de l'OWASP, mesurée ici à 120 ms : assez pour qu'une attaque
/// par dictionnaire coûte cher, assez peu pour qu'on ne le sente pas. La clé chiffre le
/// contenu en AES-256-GCM, qui authentifie autant qu'il chiffre : un fichier modifié d'un
/// octet est refusé au lieu de rendre n'importe quoi.
///
/// **La clé ne touche jamais le disque.** Elle vit en mémoire, le temps de la session, et
/// disparaît au verrouillage. Le fichier, lui, ne contient que du sel, un compte de tours
/// et un bloc scellé — aucun des trois ne dit quoi que ce soit sans le mot de passe.
@MainActor
enum Vault {

    /// Un identifiant. `created` sert à départager deux imports du même compte, et à ne
    /// rien perdre en silence quand un fichier extérieur en apporte un plus récent.
    struct Entry: Codable, Equatable {
        var host: String
        var user: String
        var password: String
        var created: Date = Date()
    }

    /// Ce que le fichier contient. Versionné : le jour où les tours ou l'algorithme
    /// changent, un ancien coffre doit encore s'ouvrir — sans quoi une mise à jour du
    /// navigateur perdrait les mots de passe, ce qu'aucune raison ne justifie.
    private struct File: Codable {
        var version = 1
        var kdf = "pbkdf2-hmac-sha512"
        var iterations: Int
        var salt: Data
        /// `SealedBox.combined` : nonce, chiffré et marque d'authenticité d'un seul tenant.
        var box: Data
    }

    // MARK: - L'état

    /// La clé du moment. **Rien d'autre ne sort d'ici.**
    private static var key: SymmetricKey?
    /// Le contenu déchiffré, tant que le coffre est ouvert.
    private static var entries: [Entry] = []
    /// Le même contenu, rangé par hôte puis par compte.
    ///
    /// **Parce que la lecture est mille fois plus fréquente que l'écriture.** La complétion
    /// interroge le coffre à chaque frappe ; un parcours du tableau coûtait 270 µs sur deux
    /// mille identifiants, mesuré — pour une réponse qui en demande moins d'une. L'index se
    /// refait à chaque modification, ce qui coûte le même parcours **une fois**, au moment
    /// où l'on enregistre : le seul instant où personne n'attend.
    private static var index: [String: [String: String]] = [:]
    private static var header: (iterations: Int, salt: Data)?

    static var isUnlocked: Bool { key != nil }

    /// Le coffre a-t-il déjà été créé ? La question précède toutes les autres : on ne
    /// demande pas un mot de passe maître à quelqu'un qui n'en a jamais posé.
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Le dossier du coffre — remplaçable, et il le faut : un essai qui vérifie qu'on sait
    /// créer un coffre écraserait sinon le vrai, et détruirait les mots de passe de
    /// quelqu'un pour prouver qu'on sait les garder.
    static var folder: URL = Storage.directory

    static var url: URL { folder.appending(path: "coffre.json") }

    // MARK: - Ouvrir, fermer

    /// Crée le coffre. Échoue si un coffre existe déjà — l'écraser perdrait tout.
    @discardableResult
    static func create(master: String) -> Bool {
        guard !exists, master.count >= 8 else { return false }
        var salt = Data(count: 32)
        // `SecRandomCopyBytes` : le générateur du système, celui qui alimente aussi le
        // trousseau. Un sel tiré d'un `Int.random` rendrait les tours de dérivation
        // inutiles contre quelqu'un qui a déjà calculé les tables.
        let ok = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) == errSecSuccess
        }
        guard ok, let derived = derive(master, salt: salt, iterations: defaultIterations) else {
            return false
        }
        key = derived
        header = (defaultIterations, salt)
        entries = []
        return persist()
    }

    /// Ouvre le coffre. Rend `false` sur un mauvais mot de passe **et** sur un fichier
    /// abîmé : AES-GCM ne distingue pas les deux, et prétendre le contraire mentirait.
    @discardableResult
    static func unlock(master: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              let derived = derive(master, salt: file.salt, iterations: file.iterations),
              let sealed = try? AES.GCM.SealedBox(combined: file.box),
              let clear = try? AES.GCM.open(sealed, using: derived),
              let read = try? JSONDecoder().decode([Entry].self, from: clear) else {
            return false
        }
        key = derived
        header = (file.iterations, file.salt)
        entries = read
        reindex()
        return true
    }

    /// Ouvre avec une clé déjà dérivée — celle que l'Enclave sécurisée a rendue après un
    /// doigt reconnu.
    ///
    /// **Le mot de passe maître ne repasse pas par là.** Il n'est écrit nulle part, et
    /// Touch ID ne le retrouve pas : ce qui est confié à l'Enclave, c'est le résultat de la
    /// dérivation, pas ce qui l'a produite. Perdre le mot de passe maître reste donc perdre
    /// le coffre le jour où l'empreinte change — c'est le prix, et il est dit.
    @discardableResult
    static func unlock(key material: Data) -> Bool {
        guard material.count == 32,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return false }
        let candidate = SymmetricKey(data: material)
        guard let sealed = try? AES.GCM.SealedBox(combined: file.box),
              let clear = try? AES.GCM.open(sealed, using: candidate),
              let read = try? JSONDecoder().decode([Entry].self, from: clear) else {
            return false
        }
        key = candidate
        header = (file.iterations, file.salt)
        entries = read
        reindex()
        return true
    }

    /// La clé du moment, pour la confier à l'Enclave — **et pour rien d'autre**.
    ///
    /// Elle ne sort d'ici que vers `Biometrics`, qui l'écrit derrière un contrôle d'accès
    /// biométrique. Aucun autre appelant n'a de raison de la voir, et aucun ne la demande.
    static var keyMaterial: Data? {
        key.map { $0.withUnsafeBytes { Data($0) } }
    }

    /// Referme. La clé et le contenu quittent la mémoire ; le fichier reste.
    static func lock() {
        key = nil
        entries = []
        index = [:]
        header = nil
    }

    /// Change le mot de passe maître : nouveau sel, nouvelle clé, même contenu.
    @discardableResult
    static func changeMaster(to master: String) -> Bool {
        guard isUnlocked, master.count >= 8 else { return false }
        var salt = Data(count: 32)
        let ok = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) == errSecSuccess
        }
        guard ok, let derived = derive(master, salt: salt, iterations: defaultIterations) else {
            return false
        }
        key = derived
        header = (defaultIterations, salt)
        return persist()
    }

    // MARK: - Lire, écrire

    /// Les comptes connus pour cet hôte, **sans leur secret**.
    ///
    /// La distinction porte le reste : savoir *qu'il y a* un identifiant sert à proposer,
    /// et n'oblige pas à sortir le mot de passe. Coffre fermé, la réponse est vide — pas
    /// une erreur : on ne propose rien, et c'est tout ce que l'appelant a besoin de savoir.
    static func accounts(for host: String) -> [String] {
        guard isUnlocked, let accounts = index[host] else { return [] }
        return accounts.keys.sorted()
    }

    static func password(host: String, user: String) -> String? {
        guard isUnlocked else { return nil }
        return index[host]?[user]
    }

    /// Enregistre, ou remplace ce qui existait pour ce couple hôte/compte.
    @discardableResult
    static func save(host: String, user: String, password: String) -> Bool {
        guard isUnlocked, !host.isEmpty, !user.isEmpty, !password.isEmpty else { return false }
        if let index = entries.firstIndex(where: { $0.host == host && $0.user == user }) {
            entries[index].password = password
        } else {
            entries.append(Entry(host: host, user: user, password: password))
        }
        return persist()
    }

    /// Range plusieurs identifiants d'un coup, **et n'écrit le fichier qu'une fois**.
    ///
    /// Un import de deux cents lignes qui appellerait `save` deux cents fois chiffrerait et
    /// réécrirait tout le coffre à chaque ligne : deux cents chiffrements pour un résultat.
    /// Rend le nombre réellement rangé.
    @discardableResult
    static func saveAll(_ incoming: [Entry]) -> Int {
        guard isUnlocked else { return 0 }
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() { index[entry.host + "\u{1F}" + entry.user] = position }

        var written = 0
        for entry in incoming where !entry.host.isEmpty && !entry.user.isEmpty
            && !entry.password.isEmpty {
            let key = entry.host + "\u{1F}" + entry.user
            if let position = index[key] {
                entries[position].password = entry.password
            } else {
                index[key] = entries.count
                entries.append(entry)
            }
            written += 1
        }
        return persist() ? written : 0
    }

    @discardableResult
    static func remove(host: String, user: String) -> Bool {
        guard isUnlocked else { return false }
        let before = entries.count
        entries.removeAll { $0.host == host && $0.user == user }
        guard entries.count != before else { return false }
        return persist()
    }

    /// Tout ce que le coffre garde, trié pour l'affichage.
    static func all() -> [Entry] {
        guard isUnlocked else { return [] }
        return entries.sorted { ($0.host, $0.user) < ($1.host, $1.user) }
    }

    /// Jette le coffre entier. Irréversible, et c'est l'appelant qui le fait dire.
    @discardableResult
    static func destroy() -> Bool {
        lock()
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    // MARK: - Le chiffrement

    /// 210 000 tours : la recommandation de l'OWASP pour PBKDF2-HMAC-SHA512, mesurée à
    /// 120 ms sur cette machine. Le nombre est **écrit dans le fichier**, pas figé dans le
    /// code : l'augmenter un jour ne doit pas fermer les coffres d'hier.
    private static let defaultIterations = 210_000

    private static func derive(_ master: String, salt: Data, iterations: Int) -> SymmetricKey? {
        guard !master.isEmpty, !salt.isEmpty, iterations > 0 else { return nil }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { seed in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), master, master.utf8.count,
                    seed.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                    out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: bytes)
    }

    /// Écrit le fichier — **entièrement, à chaque fois**.
    ///
    /// Un coffre ne se modifie pas en place : la taille du chiffré trahirait ce qui change,
    /// et un fichier à moitié réécrit est un fichier perdu. Il est petit, la réécriture
    /// coûte un millième de seconde, et `.atomic` garantit qu'on ne le trouve jamais dans
    /// un état intermédiaire — une coupure de courant au mauvais moment ne coûte que la
    /// dernière écriture.
    /// Refait l'index. Appelé à chaque écriture et à chaque ouverture — jamais en lecture.
    private static func reindex() {
        index.removeAll(keepingCapacity: true)
        for entry in entries { index[entry.host, default: [:]][entry.user] = entry.password }
    }

    @discardableResult
    private static func persist() -> Bool {
        guard let key, let header else { return false }
        reindex()
        guard let clear = try? JSONEncoder().encode(entries),
              let sealed = try? AES.GCM.seal(clear, using: key),
              let combined = sealed.combined else { return false }
        let file = File(iterations: header.iterations, salt: header.salt, box: combined)
        guard let data = try? JSONEncoder().encode(file) else { return false }
        do {
            try FileManager.default.createDirectory(at: Storage.directory,
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
}
