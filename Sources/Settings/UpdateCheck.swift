import Foundation

/// Y a-t-il une version plus récente ?
///
/// **C'est la première fois que Wuji parle à un serveur pour son propre compte**, et cela
/// mérite d'être encadré plutôt que glissé dans un coin. Le projet promet que rien ne part
/// de cette machine que vous n'ayez demandé ; une vérification automatique au démarrage
/// contredirait cette phrase. Elle est donc **éteinte par défaut**, et le bouton
/// « Vérifier » existe pour ceux qui préfèrent demander eux-mêmes.
///
/// Ce qui part : une requête GET, sans identifiant, sans numéro de série, et **sans dire
/// quelle version vous utilisez** — la comparaison se fait ici. GitHub exige un en-tête
/// d'agent : c'est « Wuji », sans plus, car « Wuji/0.1.0 » raconterait justement ce qu'on
/// ne veut pas raconter.
///
/// Ce qui ne se fait pas : télécharger, installer, redémarrer. Un navigateur qui se met à
/// jour tout seul est un navigateur qui exécute du code que personne n'a demandé. On dit
/// qu'une version existe, on ouvre sa page, et c'est la personne qui décide.
@MainActor
enum UpdateCheck {

    struct Release {
        let version: String
        let page: URL
    }

    /// L'adresse du dépôt, écrite une fois. Elle sert aussi au menu « À propos ».
    static let repository = URL(string: "https://github.com/Black0S/Wuji")!
    private static let endpoint =
        URL(string: "https://api.github.com/repos/Black0S/Wuji/releases/latest")!

    /// La version que porte cette application, telle qu'elle est écrite dans le paquet.
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Comparer

    /// Les nombres d'une version, extraits d'un texte quelconque.
    ///
    /// **Tolérant, parce que les étiquettes le sont.** Une release peut s'appeler `v0.2.0`,
    /// `0.2`, `V - 0.2.0` ou `Wuji 0.2.0 (bêta)` — la nôtre s'appelle aujourd'hui `latest`,
    /// ce qui ne dit aucune version. On prend la première suite de nombres séparés par des
    /// points, et rien d'autre.
    static func version(in text: String) -> [Int]? {
        guard let range = text.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else {
            return nil
        }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }

    /// `candidate` est-elle plus récente que `installed` ?
    ///
    /// Comparaison nombre par nombre, et non alphabétique : `0.10.0` vient après `0.9.0`,
    /// ce qu'un tri de chaînes affirme exactement à l'envers. Les longueurs inégales se
    /// complètent par des zéros — `1.2` et `1.2.0` sont la même version.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let neuf = version(in: candidate), let ici = version(in: installed) else {
            return false
        }
        for rang in 0..<max(neuf.count, ici.count) {
            let a = rang < neuf.count ? neuf[rang] : 0
            let b = rang < ici.count ? ici[rang] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Demander

    /// La dernière version publiée, ou `nil` si la question n'a pas pu être posée.
    ///
    /// L'étiquette d'abord, le titre ensuite : un dépôt bien tenu met la version dans le
    /// tag, mais celui-ci peut s'appeler `latest`, auquel cas le titre la porte.
    static func latest() async -> Release? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Wuji", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await Fetch.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let objet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let adresse = objet["html_url"] as? String, let page = URL(string: adresse)
        else { return nil }

        let étiquette = objet["tag_name"] as? String ?? ""
        let titre = objet["name"] as? String ?? ""
        guard let numéro = version(in: étiquette) ?? version(in: titre) else { return nil }
        return Release(version: numéro.map(String.init).joined(separator: "."), page: page)
    }
}
