import Foundation

/// Fabrique les règles que Wuji écrit lui-même, dans le format de WebKit.
///
/// **Il n'y a qu'un seul format dans l'application.** Les règles livrées, celles que le
/// sélecteur d'élément produit et les exceptions par site sont toutes des objets
/// `WKContentRuleList` — écrits une fois, jamais traduits. C'est ce qui permet de donner le
/// fichier au moteur sans rien faire entre les deux, et ça retire du projet la seule pièce
/// qui devait suivre quinze ans de syntaxe Adblock et ses cas particuliers.
enum WebKitRule {

    /// Masquer un élément sur un site.
    static func hide(selector: String, on site: String) -> String {
        """
        {"action":{"selector":"\(escape(selector))","type":"css-display-none"},\
        "trigger":{"if-domain":["*\(escape(site))"],"url-filter":".*"}}
        """
    }

    /// Bloquer un domaine et ses sous-domaines.
    ///
    /// Le crochet final est ce qui empêche `exemple.com` d'attraper
    /// `exemple.com.autre-chose.net` : sans lui, la règle déborde sur des domaines qui ne
    /// lui appartiennent pas.
    static func block(domain: String) -> String {
        """
        {"action":{"type":"block"},\
        "trigger":{"url-filter":"^[^:]+://+([^:/]+\\\\.)?\(pattern(domain))[/:]"}}
        """
    }

    /// Lever la protection sur un site. `ignore-previous-rules` n'annule que ce qui le
    /// précède, donc ces règles doivent venir en dernier.
    static func exception(for site: String) -> String {
        """
        {"action":{"type":"ignore-previous-rules"},\
        "trigger":{"if-domain":["*\(escape(site))"],"url-filter":".*"}}
        """
    }

    /// Ce qu'une règle fait, en français, pour l'afficher sans montrer du JSON brut.
    ///
    /// Une règle reste lisible dans son fichier ; une liste de règles ne se lit pas en
    /// JSON. La page montre donc la phrase, et le texte exact juste en dessous.
    static func describe(_ rule: String) -> String {
        if let selector = value(of: "selector", in: rule), let site = domain(in: rule) {
            return "Masque « \(selector) » sur \(site)"
        }
        if rule.contains("ignore-previous-rules"), let site = domain(in: rule) {
            return "Laisse passer \(site)"
        }
        if let filter = value(of: "url-filter", in: rule) {
            let name = filter
                .replacingOccurrences(of: "^[^:]+://+([^:/]+\\\\.)?", with: "")
                .replacingOccurrences(of: "[/:]", with: "")
                .replacingOccurrences(of: "\\\\.", with: ".")
            return "Bloque \(name)"
        }
        return "Règle"
    }

    private static func value(of key: String, in rule: String) -> String? {
        guard let start = rule.range(of: "\"\(key)\":\"") else { return nil }
        let rest = rule[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func domain(in rule: String) -> String? {
        value(of: "if-domain", in: rule).map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
            ?? {
                guard let start = rule.range(of: "[\"*") else { return nil }
                let rest = rule[start.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end])
            }()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Seul le point a un sens à neutraliser dans un nom d'hôte.
    private static func pattern(_ domain: String) -> String {
        domain.replacingOccurrences(of: ".", with: "\\\\.")
    }
}
