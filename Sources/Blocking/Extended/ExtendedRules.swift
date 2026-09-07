import Foundation

/// Les règles que le format de WebKit ne sait pas porter.
///
/// **Ce que le bloqueur de contenu ne peut pas dire.** Mesuré sur le compilateur du
/// système : `WKContentRuleListStore` n'accepte qu'une action cosmétique, `css-display-none`,
/// et elle ne pose que `display:none`. Pas de style arbitraire, pas de sélecteur qui lit du
/// texte ou du style calculé, pas d'exécution de code — les types inventés sont refusés, et
/// le refus emporte la liste entière. Le dépôt `Wuji-Rules-List` consigne donc à part, sous
/// forme structurée, ce qu'il a dû écarter : c'est ce que ce fichier lit.
///
/// **Et c'est un autre mécanisme, qu'il faut nommer comme tel.** Les listes compilées
/// filtrent dans le processus réseau et ne coûtent rien à la page. Ces règles-ci demandent
/// du style injecté, du DOM inspecté, du code exécuté : elles arrivent après coup, elles se
/// laissent détecter, et elles coûtent quelque chose sur chaque page qui en porte. Wuji les
/// applique parce qu'elles réparent ce que les listes seules laissent — cadres vides,
/// murs anti-bloqueur — mais elles se coupent d'un interrupteur, et le README dit le prix.
struct ExtendedRules: Sendable {

    /// Une déclaration de style posée sur un sélecteur — `#$#` en syntaxe AdGuard.
    ///
    /// **Le décodage est explicite, et ce n'est pas une préférence de style.** Swift ne se
    /// sert *pas* de la valeur par défaut d'une propriété quand la clé manque : il refuse.
    /// Une annexe dont une entrée n'écrit pas `excluded` aurait donc fait tomber la liste
    /// entière, silencieusement, et l'on aurait cherché longtemps pourquoi les règles d'une
    /// liste n'arrivaient pas. Le format du dépôt peut changer sans nous casser.
    struct Style: Decodable, Sendable {
        var domains: [String] = []
        var excluded: [String] = []
        let selector: String
        let declarations: String
        var extended = false
        var exception = false

        init(domains: [String] = [], excluded: [String] = [], selector: String,
             declarations: String, extended: Bool = false, exception: Bool = false) {
            self.domains = domains; self.excluded = excluded; self.selector = selector
            self.declarations = declarations; self.extended = extended; self.exception = exception
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
            excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
            selector = try c.decode(String.self, forKey: .selector)
            declarations = try c.decodeIfPresent(String.self, forKey: .declarations) ?? ""
            extended = try c.decodeIfPresent(Bool.self, forKey: .extended) ?? false
            exception = try c.decodeIfPresent(Bool.self, forKey: .exception) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case domains, excluded, selector, declarations, extended, exception
        }
    }

    /// Un sélecteur que le CSS seul ne sait pas résoudre — `:contains()`, `:upward()`,
    /// `:xpath()`… Ceux qui n'emploient que du CSS natif sont déjà partis dans la liste
    /// compilée ; ceux-ci restent parce qu'ils mêlent au moins une pseudo-classe étendue.
    struct Procedural: Decodable, Sendable {
        var domains: [String] = []
        var excluded: [String] = []
        let selector: String
        var exception = false

        init(domains: [String] = [], excluded: [String] = [], selector: String,
             exception: Bool = false) {
            self.domains = domains; self.excluded = excluded
            self.selector = selector; self.exception = exception
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
            excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
            selector = try c.decode(String.self, forKey: .selector)
            exception = try c.decodeIfPresent(Bool.self, forKey: .exception) ?? false
        }

        private enum CodingKeys: String, CodingKey { case domains, excluded, selector, exception }
    }

    /// Une primitive nommée à exécuter dans la page — `set-constant`, `set-cookie`…
    ///
    /// **Nommée, et c'est ce qui la rend acceptable.** Le dépôt ne consigne pas le
    /// JavaScript libre des listes : cinq cent trente-neuf occurrences comptées, aucune
    /// retenue. Exécuter du code arbitraire venu d'une liste serait donner à son auteur ce
    /// qu'on refuse à une extension. Une primitive nommée, elle, est écrite ici, lisible,
    /// et ne fait que ce que son nom dit.
    struct Scriptlet: Decodable, Sendable {
        var domains: [String] = []
        var excluded: [String] = []
        let name: String
        var args: [String] = []
        var syntax = ""
        var exception = false

        init(domains: [String] = [], excluded: [String] = [], name: String,
             args: [String] = [], syntax: String = "", exception: Bool = false) {
            self.domains = domains; self.excluded = excluded; self.name = name
            self.args = args; self.syntax = syntax; self.exception = exception
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
            excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
            syntax = try c.decodeIfPresent(String.self, forKey: .syntax) ?? ""
            exception = try c.decodeIfPresent(Bool.self, forKey: .exception) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case domains, excluded, name, args, syntax, exception
        }
    }

    var styles: [Style] = []
    var procedural: [Procedural] = []
    var scriptlets: [Scriptlet] = []

    var count: Int { styles.count + procedural.count + scriptlets.count }
    var isEmpty: Bool { count == 0 }

    /// Ce que le fichier publié contient. Le filtrage HTML (`$$`) est lu puis laissé de
    /// côté : il demande de réécrire la réponse avant que WebKit ne l'analyse, ce qu'aucune
    /// interface publique n'offre. Cent dix-neuf règles dans tout le dépôt.
    private struct File: Decodable {
        var styles: [Style] = []
        var procedural: [Procedural] = []
        var scriptlets: [Scriptlet] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            styles = try c.decodeIfPresent([Style].self, forKey: .styles) ?? []
            procedural = try c.decodeIfPresent([Procedural].self, forKey: .procedural) ?? []
            scriptlets = try c.decodeIfPresent([Scriptlet].self, forKey: .scriptlets) ?? []
        }

        private enum CodingKeys: String, CodingKey { case styles, procedural, scriptlets }
    }

    /// Lit un fichier `Extended-<Nom>.json`. Rend `nil` s'il n'est pas lisible : une liste
    /// dont l'annexe est cassée garde ses règles compilées, qui sont l'essentiel.
    static func decode(_ data: Data) -> ExtendedRules? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return ExtendedRules(styles: file.styles, procedural: file.procedural,
                             scriptlets: file.scriptlets)
    }

    static func merged(_ parts: [ExtendedRules]) -> ExtendedRules {
        ExtendedRules(styles: parts.flatMap(\.styles),
                      procedural: parts.flatMap(\.procedural),
                      scriptlets: parts.flatMap(\.scriptlets))
    }
}

/// À quels sites une règle s'applique.
///
/// **La règle du domaine, telle que les listes l'écrivent.** Un domaine listé vaut pour
/// lui-même et pour ses sous-domaines : `interia.pl` couvre `poczta.interia.pl`, et c'est
/// pourquoi les exclusions existent — la même règle s'écarte de la boîte aux lettres. On
/// remonte donc les étiquettes de l'hôte une à une, sans jamais s'arrêter au suffixe
/// public : ce sont les auteurs des listes qui décident de la portée, pas nous.
enum DomainScope {

    /// `www.a.exemple.fr` → `www.a.exemple.fr`, `a.exemple.fr`, `exemple.fr`, `fr`.
    static func candidates(of host: String) -> [String] {
        let hôte = host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
        var résultat = host == hôte ? [host] : [host, hôte]
        var reste = Substring(hôte)
        while let point = reste.firstIndex(of: ".") {
            reste = reste[reste.index(after: point)...]
            if !reste.isEmpty { résultat.append(String(reste)) }
        }
        return résultat
    }

    /// La règle vaut-elle pour cet hôte ? `domains` vide veut dire « partout ».
    static func matches(domains: [String], excluded: [String], host: String,
                        candidates: Set<String>) -> Bool {
        if !excluded.isEmpty, excluded.contains(where: { candidates.contains($0) }) {
            return false
        }
        if domains.isEmpty { return true }
        return domains.contains { candidates.contains($0) }
    }
}

extension ExtendedRules {

    /// Les pseudo-classes que WebKit sait résoudre lui-même. Le reste demande le moteur.
    ///
    /// **Mesuré sur le compilateur, pas lu dans une documentation.** `:has()`, `:is()`,
    /// `:where()`, `:nth-child()`, `::before` sont acceptés et appliqués ; `:has-text()`,
    /// `:matches-css()`, `:upward()`, `:xpath()` sont refusés — et le refus emporte la
    /// liste entière, pas seulement la règle.
    static let nativePseudos: Set<String> = [
        "has", "not", "is", "where", "scope", "root", "empty", "lang", "dir", "any-link",
        "first-child", "last-child", "only-child", "first-of-type", "last-of-type",
        "only-of-type", "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type",
        "hover", "focus", "focus-within", "focus-visible", "active", "visited", "link",
        "checked", "disabled", "enabled", "required", "optional", "read-only", "read-write",
        "before", "after", "first-line", "first-letter", "placeholder", "selection", "part",
        "slotted", "host", "host-context", "target", "defined", "in-range", "out-of-range"
    ]

    /// Le sélecteur tient-il tout entier dans ce que WebKit sait faire ?
    static func isNativeSelector(_ selector: String) -> Bool {
        let motif = #":(-abp-[a-z-]+|[a-zA-Z][a-zA-Z0-9-]*)"#
        guard let regex = try? NSRegularExpression(pattern: motif) else { return true }
        let plage = NSRange(selector.startIndex..., in: selector)
        for m in regex.matches(in: selector, range: plage) {
            guard let r = Range(m.range(at: 1), in: selector) else { continue }
            if !nativePseudos.contains(String(selector[r]).lowercased()) { return false }
        }
        return true
    }
}
