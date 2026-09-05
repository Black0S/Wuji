import Foundation

/// Faire entrer dans Wuji ce que l'app **Mots de passe** de macOS garde.
///
/// **Aucun navigateur tiers ne peut lire ce trousseau-là directement, et Wuji non plus.**
/// Les identifiants de Safari et de l'app Mots de passe vivent dans le trousseau iCloud,
/// sous des groupes d'accès qui appartiennent à Apple — `com.apple.cfnetwork` et ses
/// voisins. Les lire demande un droit `keychain-access-groups` sur un groupe d'Apple, qu'un
/// éditeur tiers n'obtient pas. Mesuré ici : une requête sur les éléments synchronisés
/// rend `errSecItemNotFound`, et Wuji ne voit que ce qu'il a lui-même rangé. Chrome et
/// Firefox sont logés à la même enseigne, et font exactement ce que fait ce fichier.
///
/// Reste donc la porte que le système ouvre volontairement : **l'export**. L'app Mots de
/// passe écrit un fichier CSV, Wuji le lit et range chaque ligne dans le trousseau sous son
/// propre nom. Ce qui est importé se comporte ensuite comme ce qu'on y a mis soi-même.
///
/// **Ce fichier est en clair.** C'est le prix de la seule porte disponible, et il faut le
/// dire au moment où on le franchit : il traîne sinon dans les téléchargements, lisible par
/// tout ce qui tourne sur la machine. Wuji ne le supprime pas — effacer un fichier qu'on ne
/// nous a pas demandé d'effacer est une perte de données —, il rappelle de le faire.
enum PasswordImport {

    /// Une ligne retenue. Le secret n'est jamais journalisé ni affiché : il traverse ce
    /// type pour aller au trousseau, et rien d'autre.
    struct Credential: Equatable {
        let host: String
        let user: String
        let password: String
    }

    struct Result: Equatable {
        var credentials: [Credential] = []
        /// Les lignes lues et écartées : sans hôte lisible, sans compte, ou sans secret.
        /// On les compte pour pouvoir le dire — « 42 importés » sans reste laisse croire
        /// que le fichier n'en contenait que 42.
        var skipped: Int = 0
    }

    /// Les en-têtes qu'on sait reconnaître.
    ///
    /// L'app Mots de passe écrit `Title,URL,Username,Password,Notes,OTPAuth` ; Chrome écrit
    /// `name,url,username,password` ; Firefox `url,username,password`. Ce sont les mêmes
    /// trois colonnes sous trois noms, et les chercher par leur nom plutôt que par leur
    /// position rend le lecteur indifférent à l'ordre — que ces trois-là n'ont pas en
    /// commun.
    private static let urlNames = ["url", "urls", "website", "site", "web site", "login_uri"]
    private static let userNames = ["username", "user", "login", "login_username",
                                    "account", "identifiant", "utilisateur"]
    private static let passwordNames = ["password", "login_password", "mot de passe"]

    /// Lit un export CSV.
    ///
    /// Rien n'est deviné : sans en-tête reconnaissable, on ne rend rien. Prendre « la
    /// deuxième colonne » parce qu'elle ressemble à une adresse importerait un jour des
    /// notes personnelles à la place des identifiants.
    static func parse(_ text: String) -> Result {
        let rows = rows(of: text)
        guard let header = rows.first else { return Result() }

        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let urlColumn = names.firstIndex(where: { urlNames.contains($0) }),
              let userColumn = names.firstIndex(where: { userNames.contains($0) }),
              let passwordColumn = names.firstIndex(where: { passwordNames.contains($0) })
        else { return Result() }

        var result = Result()
        for row in rows.dropFirst() {
            // Une ligne vide en fin de fichier n'est pas une ligne écartée : c'est le
            // retour à la ligne final, que tout éditeur ajoute.
            if row.count == 1, row[0].trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let field: (Int) -> String = { row.indices.contains($0) ? row[$0] : "" }
            guard let host = host(from: field(urlColumn)) else { result.skipped += 1; continue }
            let user = field(userColumn).trimmingCharacters(in: .whitespaces)
            let password = field(passwordColumn)
            guard !user.isEmpty, !password.isEmpty else { result.skipped += 1; continue }
            result.credentials.append(Credential(host: host, user: user, password: password))
        }
        return result
    }

    /// L'hôte d'une adresse d'export.
    ///
    /// Les exports mélangent les formes : `https://exemple.fr/connexion`, `exemple.fr`,
    /// parfois `http://exemple.fr:8080`. On rend l'hôte seul, sans port ni chemin — c'est
    /// la clé sous laquelle le trousseau range, et c'est ce que `securityOrigin` rendra
    /// quand la page s'ouvrira.
    static func host(from value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URLComponents(string: text)?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    // MARK: - L'écriture

    /// Écrit un export au format que tout le monde relit.
    ///
    /// Les colonnes sont celles de l'app Mots de passe — un fichier écrit ici se réimporte
    /// donc dans Safari, dans Chrome, ou dans Wuji, sans conversion. Tout champ est cité :
    /// c'est toujours valide, et cela évite d'avoir à décider si celui-ci contient une
    /// virgule alors qu'un mot de passe en contient souvent une.
    static func csv(_ credentials: [Credential]) -> String {
        let quote: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Title,URL,Username,Password,Notes,OTPAuth"]
        for credential in credentials {
            lines.append([quote(credential.host), quote("https://" + credential.host),
                          quote(credential.user), quote(credential.password),
                          quote(""), quote("")].joined(separator: ","))
        }
        // Le retour final : un fichier texte qui n'en a pas se lit mal dans la moitié des
        // outils qui le rouvriront.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Le lecteur CSV

    /// Découpe le texte en lignes de champs, selon RFC 4180.
    ///
    /// **Écrit à la main, et il le fallait.** Un mot de passe contient des virgules, des
    /// guillemets et parfois des retours à la ligne ; couper sur les virgules donnerait des
    /// secrets tronqués — et un secret tronqué qui entre dans le trousseau est pire qu'un
    /// import raté, parce qu'il ne se voit qu'à la prochaine connexion.
    static func rows(of text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                guard character == "\"" else { field.append(character); continue }
                // Un guillemet doublé à l'intérieur d'un champ cité vaut un guillemet.
                if let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    quoted = false
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:   quoted = true
            case ",":                        endField()
            // **`\r\n` est un seul `Character` en Swift.** Une chaîne Swift compte en
            // grappes de graphèmes, et la paire retour-chariot/saut-de-ligne en forme une :
            // la tester comme deux caractères la manquait, et toute la ligne d'un fichier
            // écrit sous Windows finissait collée au dernier champ.
            case "\n", "\r\n", "\r":        endRow()
            default:                         field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
