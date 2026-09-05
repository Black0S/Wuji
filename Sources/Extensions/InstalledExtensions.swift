import Foundation

/// Ce qu'on a trouvé sur la machine, avant d'en charger quoi que ce soit.
///
/// Une extension pour Safari achetée sur l'App Store n'est pas un fichier qu'on
/// installe : c'est une application ordinaire, posée dans `/Applications`, qui **porte**
/// l'extension dans son paquet — un `.appex` rangé sous `Contents/PlugIns`, avec le
/// `manifest.json` de l'extension web dans ses ressources. C'est ce fichier qu'on
/// cherche, et rien d'autre : sa présence est ce qui distingue une extension web d'une
/// extension Safari native, que WebKit ne sait pas charger ici.
///
/// **Rien n'est copié.** L'extension est lue là où elle est, dans le paquet de son
/// application hôte — donc elle suit ses mises à jour de l'App Store, et la désinstaller
/// se fait en jetant l'application, comme on s'y attend.
struct InstalledExtension: Identifiable, Sendable {

    /// Là d'où l'extension vient, et ce que la page doit en dire.
    enum Origin: Sendable {
        /// Un `.appex` dans le paquet d'une application ; la chaîne est le nom de
        /// l'application hôte, celui qu'on lit dans le Finder.
        case appExtension(host: String)
        /// Un dossier décompressé, ouvert à la main.
        case folder
    }

    /// L'identifiant du paquet pour un `.appex`, le chemin pour un dossier. Il est écrit
    /// dans les réglages : il doit survivre à une mise à jour de l'extension, ce que ni le
    /// nom affiché ni la version ne garantissent.
    let id: String
    var name: String
    /// Le nom du `.appex` ou du dossier, tel qu'il est sur le disque.
    ///
    /// Il ne sert qu'à départager : une application peut porter **plusieurs** extensions
    /// web, et rien n'oblige leurs noms affichés à différer.
    let fileName: String
    let url: URL
    /// Ce que l'utilisateur a désigné : l'application, ou le dossier. C'est ce chemin qui
    /// est retenu dans les réglages — pas celui du `.appex`, qui est un détail de rangement
    /// interne à l'application et que sa mise à jour peut déplacer.
    let source: URL
    let origin: Origin
    /// Le fichier d'icône que le manifeste déclare, s'il en déclare un.
    ///
    /// **C'est ce qui rend deux morceaux d'une même application distinguables.** « Noir »
    /// et « Noir for Web Apps » viennent du même paquet, portent presque le même nom, et
    /// n'ont que leur icône pour dire laquelle on regarde — c'est déjà comme cela qu'on les
    /// reconnaît dans les réglages de Safari.
    let iconFile: URL?

    /// L'extension est-elle un paquet d'application ? WebKit a deux portes d'entrée, et
    /// celle des `.appex` est la seule qui sache lire les ressources d'un paquet signé.
    var isAppExtension: Bool {
        if case .appExtension = origin { return true }
        return false
    }

    var hostName: String {
        switch origin {
        case .appExtension(let host): return host
        case .folder:                 return url.deletingLastPathComponent().lastPathComponent
        }
    }
}

/// Un morceau d'application qui *est* une extension, et que Wuji ne peut pas charger.
///
/// **On le nomme à l'ajout, et on ne le liste pas.** Une application se découpe couramment
/// en plusieurs extensions dont une seule est une extension web : Noir en livre deux pour
/// Safari, « Noir » et « Noir for Web Apps », et seule la seconde est du web. Ne rien dire de
/// la première laisse croire à un ajout raté — on a désigné l'application qui porte
/// visiblement ce qu'on cherchait, et il ne s'est rien passé de lisible. La nommer au moment
/// où l'on ajoute répond à la question là où elle se pose ; lui donner une ligne dans les
/// réglages mettrait un interrupteur qui ne commande rien à côté de ceux qui commandent.
struct RejectedExtension: Sendable {

    enum Reason: Sendable, Equatable {
        /// `com.apple.Safari.extension` : du code compilé, que seul Safari sait charger.
        case native
        /// Un manifeste est là, mais le paquet ne se laisse pas lire.
        case unreadable
    }

    let name: String
    let fileName: String
    let reason: Reason

    /// La phrase entière, pour quand c'est la seule chose qu'on a à dire.
    var explanation: String {
        switch reason {
        case .native:
            return "est une extension Safari native, que WebKit ne sait pas charger hors de Safari"
        case .unreadable:
            return "porte un paquet que Wuji n'a pas su lire"
        }
    }

    /// Les deux mots, pour quand elle vient après une bonne nouvelle.
    var shortReason: String {
        switch reason {
        case .native:     return "extension Safari native"
        case .unreadable: return "paquet illisible"
        }
    }
}

/// Ce qu'un chemin désigné a livré : ce qui est utilisable, et ce qui ne l'est pas.
struct FoundExtensions: Sendable {
    var usable: [InstalledExtension] = []
    var rejected: [RejectedExtension] = []

    var isEmpty: Bool { usable.isEmpty && rejected.isEmpty }

    static func + (lhs: FoundExtensions, rhs: FoundExtensions) -> FoundExtensions {
        FoundExtensions(usable: lhs.usable + rhs.usable, rejected: lhs.rejected + rhs.rejected)
    }
}

/// Le balayage du disque.
enum InstalledExtensions {

    /// Où l'on regarde. `/Applications` d'abord — c'est là que l'App Store installe —,
    /// puis le dossier personnel, pour ce qu'on a rangé chez soi.
    ///
    /// `/System/Applications` n'y est pas : Apple n'y livre aucune extension web, et le
    /// parcourir coûterait une centaine de paquets pour rien.
    /// Les deux dossiers où macOS range les extensions d'une application. `PlugIns` est
    /// l'emplacement historique et celui de toutes les extensions Safari ; `Extensions`
    /// est apparu avec les App Intents et peut en porter aussi.
    private static let extensionDirectories = ["Contents/PlugIns", "Contents/Extensions"]

    static var searchPaths: [URL] {
        var paths = [URL(fileURLWithPath: "/Applications")]
        if let home = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            paths.append(home)
        }
        return paths
    }

    /// Les extensions web portées par ce que l'on vient de désigner.
    ///
    /// **Wuji n'inventorie plus la machine.** Il parcourait `/Applications` à chaque
    /// ouverture de la page et proposait tout ce qu'il y trouvait. C'était commode et c'était
    /// une liste de ce qui est installé sur l'ordinateur, dressée sans qu'on l'ait demandée —
    /// pour un navigateur qui promet de ne rien apprendre de plus que nécessaire, la
    /// commodité ne payait pas ce prix-là. On désigne, il regarde ; il ne regarde rien
    /// d'autre.
    ///
    /// Le chemin donné peut être une application, un `.appex` seul, ou un dossier
    /// décompressé : ce sont les trois formes sous lesquelles une extension existe sur un
    /// disque, et demander laquelle on apporte serait demander de savoir.
    static func resolve(_ url: URL) -> FoundExtensions {
        if url.pathExtension == "appex" {
            return found(read(appex: url, host: url, source: url))
        }
        if url.pathExtension == "app" { return webExtensions(in: url) }
        guard let entry = folder(at: url) else { return FoundExtensions() }
        return FoundExtensions(usable: [entry])
    }

    /// Les extensions web d'une application.
    ///
    /// **Une application porte souvent plusieurs `.appex`, et une seule est l'extension
    /// web.** Noir en a cinq : une extension web, une extension Safari native, un
    /// gestionnaire d'intentions, un widget, des App Intents. Elles se ressemblent jusque
    /// dans leur nom de fichier — c'est le contenu qui tranche, et rien d'autre. Toutes sont
    /// examinées, aucune n'est devinée ; et quand il y en a deux qui marchent, les deux sont
    /// proposées.
    ///
    /// Les morceaux qui ne visent pas du tout le navigateur — widgets, intentions — sortent
    /// en silence : les nommer ferait passer chaque application pour un échec partiel.
    /// Ce qui est nommé, ce sont les extensions **de Safari** que Wuji ne peut pas prendre.
    static func webExtensions(in app: URL) -> FoundExtensions {
        let manager = FileManager.default
        var result = FoundExtensions()
        for folder in extensionDirectories {
            let bundles = (try? manager.contentsOfDirectory(
                at: app.appending(path: folder),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for appex in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where appex.pathExtension == "appex" {
                result = result + found(read(appex: appex, host: app, source: app))
            }
        }
        result.usable = disambiguate(result.usable)
        return result
    }

    /// Le balayage d'autrefois, gardé pour une seule chose : retrouver l'application qui
    /// porte une extension déjà activée, au premier lancement après le changement. Sans lui,
    /// les extensions en place disparaîtraient de la liste sans que personne les ait
    /// retirées — et « mes extensions ont disparu » est le pire message qu'une mise à jour
    /// puisse faire passer.
    static func scanForMigration() -> [InstalledExtension] {
        let manager = FileManager.default
        var found: [InstalledExtension] = []
        for directory in searchPaths {
            let apps = (try? manager.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
            for app in apps where app.pathExtension == "app" {
                found.append(contentsOf: webExtensions(in: app).usable)
            }
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.id).inserted }
    }

    /// Deux extensions du même hôte qui portent le même nom deviennent illisibles.
    ///
    /// Le cas arrive dès qu'une application livre deux extensions web dont les manifestes
    /// se nomment par une clé de localisation que les traductions livrées ne couvrent pas :
    /// elles retombent toutes deux sur le nom de l'application, et la page affiche deux
    /// lignes identiques qu'on ne peut pas départager. Le nom du `.appex` les sépare — il
    /// n'est pas beau, il est vrai.
    private static func disambiguate(_ entries: [InstalledExtension]) -> [InstalledExtension] {
        var count: [String: Int] = [:]
        for entry in entries { count[entry.name, default: 0] += 1 }
        return entries.map { entry in
            guard count[entry.name, default: 0] > 1 else { return entry }
            var renamed = entry
            renamed.name = "\(entry.name) (\(entry.fileName))"
            return renamed
        }
    }

    /// Le point d'extension d'une extension web pour Safari. Son voisin,
    /// `com.apple.Safari.extension`, désigne une extension **native** : du code compilé,
    /// que `WKWebExtension` ne sait pas charger. Les deux vivent côte à côte dans la même
    /// application et portent des noms de fichier interchangeables.
    private static let webExtensionPoint = "com.apple.Safari.web-extension"
    private static let nativeExtensionPoint = "com.apple.Safari.extension"

    /// Ce qu'un `.appex` s'est révélé être.
    private enum Verdict {
        case usable(InstalledExtension)
        case rejected(RejectedExtension)
        /// Un morceau qui ne vise pas le navigateur : widget, intentions, autre.
        case irrelevant
    }

    private static func found(_ verdict: Verdict) -> FoundExtensions {
        switch verdict {
        case .usable(let entry):     return FoundExtensions(usable: [entry])
        case .rejected(let refused): return FoundExtensions(rejected: [refused])
        case .irrelevant:            return FoundExtensions()
        }
    }

    /// Un `.appex` est-il une extension web, et sous quel nom ?
    ///
    /// **Deux conditions, et il faut les deux.** Le `manifest.json` dit qu'il y a une
    /// extension web à lire ; le point d'extension dit que c'est bien celle que Safari
    /// charge. Le premier seul laisserait passer un manifeste embarqué comme simple
    /// ressource par une extension native — le second seul manquerait les extensions
    /// décompressées, qui n'ont pas d'`Info.plist` du tout.
    private static func read(appex: URL, host: URL, source: URL) -> Verdict {
        let resources = appex.appending(path: "Contents/Resources")
        let manifest = resources.appending(path: "manifest.json")
        let hasManifest = FileManager.default.fileExists(atPath: manifest.path)
        let bundle = Bundle(url: appex)
        let point = bundle?.extensionPoint
        let fileName = appex.deletingPathExtension().lastPathComponent

        // Une extension Safari **native** : elle existe, elle s'affiche dans Safari, et
        // WebKit n'a aucune porte pour la charger ailleurs. C'est le second « Noir » de la
        // capture, et c'est le cas qu'il fallait cesser de passer sous silence.
        let hostLabel = (Bundle(url: host)?.displayName)
            ?? host.deletingPathExtension().lastPathComponent
        guard point != nativeExtensionPoint else {
            return .rejected(RejectedExtension(
                name: bundle?.displayName.flatMap { isGeneric($0) ? nil : $0 } ?? fileName,
                fileName: fileName, reason: .native))
        }
        // Widget, gestionnaire d'intentions, App Intents : rien à voir avec une page web.
        guard hasManifest || point == webExtensionPoint else { return .irrelevant }
        guard hasManifest, let bundle, let identifier = bundle.bundleIdentifier else {
            return .rejected(RejectedExtension(
                name: bundle?.displayName ?? fileName, fileName: fileName,
                reason: .unreadable))
        }
        // Un manifeste embarqué comme ressource par autre chose qu'une extension web.
        guard point.map({ $0 == webExtensionPoint }) ?? true else { return .irrelevant }

        let read = self.manifest(at: manifest)
        let hostName = hostLabel
        // **Le manifeste d'abord, le paquet ensuite.** Le nom du `.appex` est celui d'une
        // cible Xcode, et il vaut « Extension » tout court plus souvent qu'on ne croit —
        // trois lignes qui s'appelleraient toutes pareil ne se distinguent plus. Le nom
        // écrit dans le manifeste est celui que l'extension se donne.
        let name = read?.name
            ?? bundle.displayName.flatMap { isGeneric($0) ? nil : $0 }
            ?? hostName
        return .usable(InstalledExtension(id: identifier, name: name, fileName: fileName,
                                          url: appex, source: source,
                                          origin: .appExtension(host: hostName),
                                          iconFile: read?.icon))
    }

    /// Un nom qui ne nomme rien : celui d'une cible Xcode restée telle quelle. Il ne
    /// distingue pas deux extensions, donc on lui préfère le nom de l'application hôte.
    private static func isGeneric(_ name: String) -> Bool {
        ["extension", "safari extension", "web extension", "safari web extension",
         "mac extension", "ios extension"]
            .contains(name.lowercased())
    }

    // MARK: - Le manifeste

    /// Ce qu'on lit dans un `manifest.json` : de quoi nommer et de quoi montrer.
    private struct ManifestInfo {
        var name: String?
        var icon: URL?
    }

    /// Lit le manifeste une seule fois, pour le nom **et** l'icône.
    ///
    /// Deux lectures séparées du même fichier coûtaient deux ouvertures et deux analyses
    /// JSON par extension à chaque balayage ; il n'y a qu'un fichier, il n'y a qu'une
    /// lecture.
    private static func manifest(at url: URL) -> ManifestInfo? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let base = url.deletingLastPathComponent()
        let declared = json["name"] as? String
        let name = declared.flatMap {
            localised($0, in: base, defaultLocale: json["default_locale"] as? String)
        }
        return ManifestInfo(name: name, icon: icon(from: json, in: base))
    }

    /// Le nom déclaré dans le manifeste, **traduit s'il est une clé**.
    ///
    /// `__MSG_extension_name__` n'est pas un nom : c'est une entrée de
    /// `_locales/<langue>/messages.json`, que WebKit résout au chargement. Wuji doit la
    /// résoudre lui-même, parce qu'il affiche la ligne **avant** d'avoir chargé quoi que ce
    /// soit — et parce que le repli sur le nom de l'application hôte donne ici une réponse
    /// fausse : le paquet de Noir contient l'extension « Noir for Web Apps », qui se serait
    /// affichée « Noir », c'est-à-dire sous le nom de l'*autre* morceau de la même
    /// application. Deux lignes distinctes portant le même nom, à cause du repli censé les
    /// rendre lisibles.
    ///
    /// La langue de l'interface d'abord, celle du manifeste ensuite, l'anglais en dernier :
    /// c'est l'ordre de WebKit, et c'est celui qui donne le nom qu'on lit dans Safari.
    private static func localised(_ value: String, in resources: URL,
                                  defaultLocale: String?) -> String? {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), value.count > 8 else {
            return value
        }
        let key = String(value.dropFirst(6).dropLast(2))
        let locales: [String?] = [Locale.current.language.languageCode?.identifier,
                                  defaultLocale, "en"]
        var tried: Set<String> = []
        for locale in locales.compactMap({ $0 }) where tried.insert(locale).inserted {
            let file = resources.appending(path: "_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = json[key] as? [String: Any],
                  let message = entry["message"] as? String, !message.isEmpty else { continue }
            return message
        }
        return nil
    }

    /// L'icône que le manifeste déclare, choisie à la bonne taille.
    ///
    /// `icons` d'abord : c'est l'icône de l'extension elle-même, celle que Safari met dans
    /// sa liste. `action.default_icon` n'est qu'un repli — c'est l'icône du bouton de barre,
    /// souvent monochrome et pensée pour seize points de côté.
    private static func icon(from json: [String: Any], in base: URL) -> URL? {
        var candidates = sizes(json["icons"])
        if candidates.isEmpty {
            let action = (json["action"] ?? json["browser_action"] ?? json["page_action"])
                as? [String: Any]
            if let single = action?["default_icon"] as? String {
                candidates = [(0, single)]
            } else {
                candidates = sizes(action?["default_icon"])
            }
        }
        guard !candidates.isEmpty else { return nil }
        // La plus grande qui reste raisonnable : la page l'affiche sur vingt points, et un
        // écran Retina en veut quarante. Au-delà de 256 on transporte des kilo-octets pour
        // une vignette.
        let chosen = candidates.filter { $0.size <= 256 }.max(by: { $0.size < $1.size })
            ?? candidates.min(by: { $0.size < $1.size })
        guard let path = chosen?.path else { return nil }
        let file = base.appending(path: path)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static func sizes(_ value: Any?) -> [(size: Int, path: String)] {
        guard let table = value as? [String: Any] else { return [] }
        return table.compactMap { key, path in
            guard let path = path as? String, let size = Int(key) else { return nil }
            return (size, path)
        }
    }

    /// L'icône, prête à être posée dans une page interne.
    ///
    /// **Une URI de données et non un fichier.** Les pages `wuji://` n'ont aucun accès au
    /// disque, et leur en ouvrir un pour afficher une vignette ouvrirait bien plus que ça.
    /// Le fichier est lu en Swift, encodé, et la page ne reçoit que des octets.
    static func iconDataURI(for item: InstalledExtension) -> String? {
        guard let file = item.iconFile,
              let data = try? Data(contentsOf: file), !data.isEmpty,
              // Une icône de plus d'un demi-mégaoctet n'est pas une icône. La refuser
              // évite d'enfler la page interne d'un paquet mal fichu.
              data.count <= 512 * 1024 else { return nil }
        let type: String
        switch file.pathExtension.lowercased() {
        case "svg":          type = "svg+xml"
        case "jpg", "jpeg":  type = "jpeg"
        case "webp":         type = "webp"
        default:             type = "png"
        }
        return "data:image/\(type);base64," + data.base64EncodedString()
    }

    /// Une extension décompressée, désignée à la main. Le dossier doit porter un
    /// `manifest.json` à sa racine : c'est ce que WebKit demande, et le dire ici évite
    /// d'échouer plus tard avec un message qui parle de codes d'erreur.
    static func folder(at url: URL) -> InstalledExtension? {
        let file = url.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let read = manifest(at: file)
        return InstalledExtension(id: url.standardizedFileURL.path,
                                  name: read?.name ?? url.lastPathComponent,
                                  fileName: url.lastPathComponent, url: url,
                                  source: url.standardizedFileURL, origin: .folder,
                                  iconFile: read?.icon)
    }
}

private extension Bundle {
    /// Le nom qu'on lit dans le Finder, avec le repli qu'AppKit applique lui-même.
    var displayName: String? {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    /// Ce que le paquet dit être : `com.apple.Safari.web-extension`, `…widgetkit-extension`,
    /// `…intents-service`. `nil` quand le paquet ne le déclare pas — ce n'est alors pas un
    /// refus, seulement une absence d'information.
    var extensionPoint: String? {
        let declaration = object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        return declaration?["NSExtensionPointIdentifier"] as? String
    }
}
