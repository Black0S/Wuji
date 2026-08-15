import Foundation

/// Un script utilisateur, au format que tout le monde utilise depuis Greasemonkey.
///
/// **Pas de moteur maison.** L'en-tête `// ==UserScript==` est un standard de fait vieux de
/// vingt ans : les scripts qu'on trouve en ligne le respectent, et un format à nous
/// n'aurait servi qu'à les rendre inutilisables ici.
///
/// Ce qui est lu de l'en-tête est ce dont l'injection a besoin — où, quand, sous quel nom.
/// Le reste (`@grant`, `@require`, `@resource`) demande une API d'extension que Wuji n'a
/// pas ; les scripts qui en dépendent ne fonctionneront pas, et il vaut mieux le dire que
/// de les charger à moitié.
struct UserScript: Codable, Identifiable {
    var id: UUID
    var name: String
    var version: String
    var descriptionText: String
    /// Motifs de correspondance, façon `@match` ou `@include`.
    var patterns: [String]
    var excludes: [String]
    /// `document-start`, `document-end` ou `document-idle`.
    var runAt: String
    var isEnabled: Bool
    /// L'adresse d'où il vient, quand il vient d'ailleurs. Sert à le mettre à jour.
    var source: URL?
    var added: Date

    /// Analyse l'en-tête. Un script sans en-tête reste valable : il s'appliquera partout,
    /// comme le veut la convention.
    init(id: UUID = UUID(), text: String, source: URL? = nil) {
        self.id = id
        self.source = source
        added = Date()
        isEnabled = true

        var name = source?.lastPathComponent ?? "Script"
        var version = ""
        var description = ""
        var patterns: [String] = []
        var excludes: [String] = []
        var runAt = "document-end"

        var inHeader = false
        text.enumerateLines { line, stop in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.contains("==UserScript==") { inHeader = true; return }
            if line.contains("==/UserScript==") { stop = true; return }
            guard inHeader, line.hasPrefix("//") else { return }

            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@"), let space = body.firstIndex(of: " ") else { return }
            let key = String(body[body.startIndex..<space])
            let value = body[space...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }

            switch key {
            case "@name":        name = value
            case "@version":     version = value
            case "@description": description = value
            case "@match", "@include": patterns.append(value)
            case "@exclude", "@exclude-match": excludes.append(value)
            case "@run-at":      runAt = value
            default: break
            }
        }

        self.name = name
        self.version = version
        descriptionText = description
        // Sans `@match`, le script vaut partout : c'est la convention, et la refuser
        // casserait la moitié des scripts publiés.
        self.patterns = patterns.isEmpty ? ["*"] : patterns
        self.excludes = excludes
        self.runAt = runAt
    }

    /// Le script s'applique-t-il à cette adresse ?
    ///
    /// Les motifs mélangent deux syntaxes voisines — celle des extensions (`*://*.site.com/*`)
    /// et l'ancienne, plus lâche. On les traite pareil : une expression avec `*` pour joker,
    /// ancrée aux deux bouts. C'est ce que font les gestionnaires existants.
    func matches(_ url: URL) -> Bool {
        let address = url.absoluteString
        guard !excludes.contains(where: { Self.matches(pattern: $0, address: address) }) else {
            return false
        }
        return patterns.contains { Self.matches(pattern: $0, address: address) }
    }

    private static func matches(pattern: String, address: String) -> Bool {
        guard pattern != "*", pattern != "<all_urls>" else { return true }
        // Le motif est littéral sauf ses jokers : on échappe tout, puis on rend leur sens
        // aux `*`. Sans ça, un point dans un nom de domaine accepterait n'importe quoi.
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        let range = NSRange(address.startIndex..., in: address)
        return regex.firstMatch(in: address, range: range) != nil
    }
}
