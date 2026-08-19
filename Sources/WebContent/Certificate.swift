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

    /// Deux ou trois lignes lisibles : à qui le certificat a été délivré, par qui, et
    /// jusqu'à quand.
    static func describe(_ trust: SecTrust?) -> [String] {
        guard let trust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return [] }

        var lines: [String] = []
        if let subject = SecCertificateCopySubjectSummary(leaf) as String? {
            lines.append("Délivré à \(subject)")
        }
        // L'autorité est le certificat suivant dans la chaîne : celui qui a signé le nôtre.
        if chain.count > 1, let issuer = SecCertificateCopySubjectSummary(chain[1]) as String? {
            lines.append("Par \(issuer)")
        }
        if let until = expiry(of: leaf) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateFormat = "d MMMM yyyy"
            lines.append("Valable jusqu'au \(formatter.string(from: until))")
        }
        return lines
    }

    /// La date de fin de validité, lue dans le certificat lui-même.
    ///
    /// `SecCertificateCopyValues` rend un dictionnaire de dictionnaires, et la date y est
    /// exprimée en secondes depuis 2001 — l'époque d'Apple, pas celle d'Unix. Confondre les
    /// deux décale la réponse de trente et un ans.
    private static func expiry(of certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter as String
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil)
                as? [String: Any],
              let entry = values[key] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
