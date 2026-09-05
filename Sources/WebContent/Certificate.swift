import CryptoKit
import Foundation
import Security

/// Ce qu'on peut dire d'un certificat, et rien de plus.
///
/// **Le cadenas affirmait « chiffré » sans dire par qui.** C'est pourtant la seule question
/// qui compte : le chiffrement garantit que personne ne lit entre vous et le serveur, pas
/// que le serveur soit celui qu'il prétend. C'est l'autorité qui l'atteste, et son nom
/// mérite d'être lisible.
///
/// Rien n'est deviné ici. Si le système ne rend pas une information, elle n'est pas
/// affichée — un « inconnu » vaut mieux qu'un nom plausible.
enum Certificate {

    /// Une ligne du détail : ce qu'on dit, et ce qu'on en dit.
    ///
    /// Le couple plutôt qu'une phrase toute faite : la valeur est ce qu'on copie, et
    /// l'étiquette ce qui permet de savoir quoi. Une chaîne unique aurait obligé chaque
    /// appelant à la recouper pour en tirer l'une ou l'autre.
    struct Detail {
        let label: String
        let value: String
    }

    // MARK: - Le résumé

    /// Deux ou trois lignes lisibles : à qui le certificat a été délivré, par qui, et
    /// jusqu'à quand. C'est ce que montre la page d'erreur d'un certificat refusé, où l'on
    /// décide en trois secondes.
    static func describe(_ trust: SecTrust?) -> [String] {
        guard let leaf = leaf(of: trust) else { return [] }
        var lines: [String] = []
        if let subject = SecCertificateCopySubjectSummary(leaf) as String? {
            lines.append("Délivré à \(subject)")
        }
        if let authority = issuerName(of: trust) {
            lines.append("Par \(authority)")
        }
        if let until = date(kSecOIDX509V1ValidityNotAfter, in: leaf) {
            lines.append("Valable jusqu'au \(long.string(from: until))")
        }
        return lines
    }

    // MARK: - Le détail

    /// Un groupe de lignes, avec de quoi le nommer dans un menu.
    struct Section {
        let title: String
        let symbol: String
        let details: [Detail]
    }

    /// Ce que le système sait dire de ce certificat, **groupé**.
    ///
    /// Le détail existait en une seule liste : onze lignes à plat, dont une empreinte de
    /// quatre-vingt-quinze caractères qui étirait le menu jusqu'au bord de l'écran. Ce
    /// n'était pas trop d'information, c'était la mauvaise forme — on ne lit pas un
    /// certificat en entier, on y cherche une chose. Cinq entrées au premier niveau, le
    /// reste derrière celle qu'on ouvre.
    ///
    /// Chaque valeur est lue dans le certificat. Ce que `Security` ne rend pas est absent
    /// plutôt que rempli d'un tiret : une ligne vide se lit comme une ligne fausse — et un
    /// groupe qui se retrouve vide ne s'affiche pas du tout.
    static func sections(_ trust: SecTrust?) -> [Section] {
        guard let leaf = leaf(of: trust) else { return [] }
        var sections: [Section] = []

        func section(_ title: String, _ symbol: String, _ details: [Detail?]) {
            let kept = details.compactMap { $0 }
            guard !kept.isEmpty else { return }
            sections.append(Section(title: title, symbol: symbol, details: kept))
        }
        func line(_ label: String, _ value: String?) -> Detail? {
            guard let value, !value.isEmpty else { return nil }
            return Detail(label: label, value: value)
        }

        // **L'identité, et les autres noms qu'elle couvre.** C'est ce qui explique un
        // cadenas sur une adresse qui n'est pas celle du champ « délivré à ».
        let subject = SecCertificateCopySubjectSummary(leaf) as String?
        var identity = [line("Délivré à", subject),
                        line("Organisation",
                             field(kSecOIDOrganizationName, in: leaf, from: kSecOIDX509V1SubjectName))]
        // Le nom principal figure aussi dans la liste des autres noms : l'y laisser
        // afficherait « Délivré à github.com » puis « Couvre aussi github.com », qui se lit
        // comme une redondance et non comme une information.
        identity += (subjectAlternativeNames(of: leaf) ?? [])
            .filter { $0 != subject }
            .map { line("Couvre aussi", $0) }
        section("Identité", "person.text.rectangle", identity)

        let from = date(kSecOIDX509V1ValidityNotBefore, in: leaf)
        let until = date(kSecOIDX509V1ValidityNotAfter, in: leaf)
        section("Validité", "calendar", [
            line("Depuis le", from.map(long.string(from:))),
            line("Jusqu'au", until.map(long.string(from:))),
            // Le compte des jours, parce que c'est la forme sous laquelle un certificat
            // pose problème : « expire dans trois jours » se comprend, une date demande de
            // faire la soustraction soi-même.
            line("Reste", until.flatMap(remaining))
        ])

        section("Chiffrement", "key", [
            line("Signature", algorithm(of: leaf)),
            line("Clé publique", publicKey(of: leaf)),
            line("Numéro de série", serial(of: leaf))
        ])

        // L'empreinte se lit par groupes de huit octets : c'est ainsi qu'on la compare à
        // celle qu'un serveur affiche, et une ligne de quatre-vingt-quinze caractères ne se
        // compare pas, elle se survole.
        if let print = fingerprint(trust) {
            let bytes = print.split(separator: ":").map(String.init)
            let rows = stride(from: 0, to: bytes.count, by: 8).map {
                Detail(label: "", value: bytes[$0..<min($0 + 8, bytes.count)].joined(separator: ":"))
            }
            sections.append(Section(title: "Empreinte SHA-256", symbol: "checkmark.shield",
                                    details: rows))
        }

        // La chaîne dit **qui atteste de qui**, et c'est la seule vue qui montre l'autorité
        // qu'on finit par croire sur parole.
        if let trust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           chain.count > 1 {
            let rows = chain.enumerated().compactMap { index, certificate -> Detail? in
                guard let name = SecCertificateCopySubjectSummary(certificate) as String? else {
                    return nil
                }
                return Detail(label: "", value: index == 0 ? name : String(repeating: " ", count: index * 2) + "↳ " + name)
            }
            section("Chaîne de confiance", "link", rows)
        }
        return sections
    }

    /// Ce qui reste à courir, dit comme on se le demande.
    private static func remaining(until: Date) -> String? {
        guard let days = Calendar.current.dateComponents([.day], from: Date(), to: until).day
        else { return nil }
        if days < 0 { return "expiré depuis \(-days) jour\(-days > 1 ? "s" : "")" }
        if days == 0 { return "expire aujourd'hui" }
        return "\(days) jour\(days > 1 ? "s" : "")"
    }

    /// L'autorité, en une ligne qu'on lit sans ouvrir quoi que ce soit.
    ///
    /// L'organisation d'abord — « Sectigo Limited » — parce que le nom d'usage du
    /// certificat intermédiaire est un identifiant technique de soixante caractères qui
    /// n'apprend rien de plus au premier coup d'œil.
    static func authority(_ trust: SecTrust?) -> String? {
        guard let leaf = leaf(of: trust) else { return nil }
        return field(kSecOIDOrganizationName, in: leaf, from: kSecOIDX509V1IssuerName)
            ?? issuerName(of: trust)
    }

    /// L'empreinte SHA-256 du certificat, en hexadécimal.
    ///
    /// **C'est la seule façon de vérifier un certificat que personne n'atteste.** Pour un
    /// service qu'on héberge soi-même, l'empreinte est la question à poser au serveur — si
    /// elle correspond, c'est bien lui ; sinon, quelqu'un s'est intercalé. Une page qui
    /// propose d'accepter un certificat sans le montrer demande un blanc-seing.
    static func fingerprint(_ trust: SecTrust?) -> String? {
        guard let leaf = leaf(of: trust) else { return nil }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Lecture du certificat

    private static func leaf(of trust: SecTrust?) -> SecCertificate? {
        guard let trust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.first
    }

    /// Le nom de l'autorité.
    ///
    /// Le certificat suivant dans la chaîne quand il y en a un — c'est lui qui a signé le
    /// nôtre, et son nom d'usage est plus lisible que le champ « issuer ». Sinon on retombe
    /// sur ce que le certificat déclare lui-même, ce qui reste vrai pour un certificat
    /// auto-signé : il s'atteste tout seul, et le voir se dire sa propre autorité **est**
    /// l'information.
    private static func issuerName(of trust: SecTrust?) -> String? {
        guard let trust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        if chain.count > 1, let name = SecCertificateCopySubjectSummary(chain[1]) as String? {
            return name
        }
        return field(kSecOIDCommonName, in: leaf, from: kSecOIDX509V1IssuerName)
            ?? field(kSecOIDOrganizationName, in: leaf, from: kSecOIDX509V1IssuerName)
    }

    /// Une date de validité, lue dans le certificat lui-même.
    ///
    /// `SecCertificateCopyValues` rend un dictionnaire de dictionnaires, et la date y est
    /// exprimée en secondes depuis 2001 — l'époque d'Apple, pas celle d'Unix. Confondre les
    /// deux décale la réponse de trente et un ans.
    private static func date(_ oid: CFString, in certificate: SecCertificate) -> Date? {
        guard let entry = values(of: certificate, keys: [oid])?[oid as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Un champ nommé, cherché dans une section — le sujet ou l'émetteur.
    ///
    /// Ces sections sont des **listes** de couples clé/valeur, pas des dictionnaires : un
    /// certificat peut porter deux unités organisationnelles, et l'API rend l'ordre du
    /// certificat. On prend la première correspondance, comme le fait le système ailleurs.
    private static func field(_ oid: CFString, in certificate: SecCertificate,
                              from section: CFString) -> String? {
        guard let entry = values(of: certificate, keys: [section])?[section as String] as? [String: Any],
              let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        for part in parts where part[kSecPropertyKeyLabel as String] as? String == oid as String {
            if let value = part[kSecPropertyKeyValue as String] as? String { return value }
        }
        return nil
    }

    /// Les autres noms que ce certificat couvre.
    ///
    /// **C'est la question qu'on se pose sans le savoir.** Un certificat délivré à
    /// `exemple.fr` vaut souvent aussi pour `www.exemple.fr` et pour six autres noms : les
    /// voir, c'est comprendre pourquoi le cadenas est vert sur une adresse qui n'est pas
    /// celle du champ « délivré à ».
    private static func subjectAlternativeNames(of certificate: SecCertificate) -> [String]? {
        let key = kSecOIDSubjectAltName as String
        guard let entry = values(of: certificate,
                                 keys: [kSecOIDSubjectAltName])?[key] as? [String: Any],
              let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        // **La section ne contient pas que des noms.** Le premier élément dit si l'extension
        // est critique — étiquette « Critical », valeur « No » — et il se glissait dans la
        // liste : le certificat de github.com annonçait « No, github.com, www.github.com ».
        // On ne garde que ce qui est étiqueté comme un nom.
        let named: Set<String> = ["DNS Name", "IP Address", "URI", "Email Address"]
        let names = parts.compactMap { part -> String? in
            guard let label = part[kSecPropertyKeyLabel as String] as? String,
                  named.contains(label),
                  let value = part[kSecPropertyKeyValue as String] as? String else { return nil }
            return value
        }
        // Bornée : un certificat de CDN en porte parfois plus de cent, et la ligne devient
        // un mur qu'on ne lit plus.
        guard !names.isEmpty else { return nil }
        return names.count > 8 ? Array(names.prefix(8)) + ["+\(names.count - 8)"] : names
    }

    private static func algorithm(of certificate: SecCertificate) -> String? {
        let key = kSecOIDX509V1SignatureAlgorithm as String
        guard let entry = values(of: certificate,
                                 keys: [kSecOIDX509V1SignatureAlgorithm])?[key] as? [String: Any],
              let parts = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        // L'entrée porte l'identifiant brut de l'algorithme — « 1.2.840.113549.1.1.11 ».
        // Le nom courant se lit mieux, et la table est courte parce que le web ne signe
        // plus qu'avec une poignée d'algorithmes.
        for part in parts {
            guard let oid = part[kSecPropertyKeyValue as String] as? String else { continue }
            return named[oid] ?? oid
        }
        return nil
    }

    /// La clé publique : son type et sa taille. Une clé RSA de 1024 bits et une de 4096
    /// n'offrent pas la même chose, et c'est invisible partout ailleurs.
    private static func publicKey(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any] else { return nil }
        let bits = attributes[kSecAttrKeySizeInBits as String] as? Int
        // Les constantes de `Security` sont des `CFString` : la comparaison se fait sur
        // leur forme chaîne, sinon le motif d'un `switch` ne correspond à rien et le type
        // ressort tel quel — « 42 », qui ne dit rien à personne.
        let raw = attributes[kSecAttrKeyType as String] as? String
        var type = raw
        if raw == kSecAttrKeyTypeRSA as String { type = "RSA" }
        if raw == kSecAttrKeyTypeECSECPrimeRandom as String { type = "ECDSA" }
        switch (type, bits) {
        case let (type?, bits?): return "\(type) \(bits) bits"
        case let (type?, .none): return type
        case let (.none, bits?): return "\(bits) bits"
        default:                 return nil
        }
    }

    /// Le numéro de série, en hexadécimal — c'est sous cette forme qu'une autorité le
    /// publie, et donc la seule sous laquelle il se compare.
    private static func serial(of certificate: SecCertificate) -> String? {
        guard let data = SecCertificateCopySerialNumberData(certificate, nil) as Data? else {
            return nil
        }
        return data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func values(of certificate: SecCertificate, keys: [CFString]) -> [String: Any]? {
        SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [String: Any]
    }

    /// Les identifiants d'algorithme qu'on rencontre encore sur le web.
    private static let named: [String: String] = [
        "1.2.840.113549.1.1.11": "SHA-256 avec RSA",
        "1.2.840.113549.1.1.12": "SHA-384 avec RSA",
        "1.2.840.113549.1.1.13": "SHA-512 avec RSA",
        "1.2.840.113549.1.1.10": "RSASSA-PSS",
        "1.2.840.113549.1.1.5":  "SHA-1 avec RSA",
        "1.2.840.10045.4.3.2":   "SHA-256 avec ECDSA",
        "1.2.840.10045.4.3.3":   "SHA-384 avec ECDSA",
        "1.2.840.10045.4.3.4":   "SHA-512 avec ECDSA"
    ]

    private static let long: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}
