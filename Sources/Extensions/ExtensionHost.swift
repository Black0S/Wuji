import AppKit
import WebKit

/// Les extensions web : ce qui est installé sur la machine, et ce qui tourne ici.
///
/// **Wuji ne distribue pas d'extensions et n'en télécharge aucune.** Il lit ce que
/// l'App Store a déjà posé sur la machine pour Safari, et ce qu'on lui désigne à la main.
/// C'est la seule façon d'en avoir sans devenir soi-même un magasin — avec sa modération,
/// ses mises à jour et sa chaîne de confiance à tenir.
///
/// Le contrôleur est créé au premier accès et vit aussi longtemps que l'application : il
/// doit être posé sur la configuration de **chaque** vue web, avant sa création. Une vue
/// qui ne le porte pas est invisible pour les extensions — leurs scripts de contenu ne s'y
/// posent pas, et l'onglet n'existe pas dans `browser.tabs`.
@MainActor
final class ExtensionHost {

    /// Une ligne de la page des extensions : ce qu'on a trouvé, et ce qu'il en est advenu.
    ///
    /// **Seulement ce qui s'active.** Une application se découpe couramment en plusieurs
    /// extensions dont une seule est du web ; les autres — une extension Safari native, un
    /// paquet illisible — n'ont pas de ligne ici. Une ligne qui ne peut ni s'activer, ni
    /// s'épingler, ni rien faire n'est pas une ligne : c'est une note de bas de page qui
    /// occupe la place d'un réglage. Ce qui a été trouvé et laissé se dit **au moment de
    /// l'ajout**, où la question se pose, et pas une fois pour toutes dans la liste.
    struct Entry {
        let id: String
        let name: String
        /// « Extension de « Noir » », « Dossier · /chemin ».
        let origin: String
        var isEnabled = false
        var version: String?
        var summary: String?
        /// Ce qui a échoué au chargement, en français. Une extension activée qui ne tourne
        /// pas doit le dire : sans cette ligne, on croit à une fonction cassée du
        /// navigateur alors que c'est le paquet qui a été refusé.
        var failure: String?
        /// Ce que l'extension demande : permissions nommées, puis hôtes visés.
        var permissions: [String] = []
        var hosts: [String] = []
        var isPinned = false
        /// Chargée **maintenant**, ce qui n'est pas la même chose qu'activée : entre les
        /// deux il y a la lecture du paquet, qui prend un instant et peut échouer.
        var isLoaded = false
        /// L'icône du manifeste, encodée pour la page interne. `nil` quand l'extension n'en
        /// déclare pas — la page pose alors une initiale, plutôt qu'un cadre vide.
        var icon: String?
    }

    let controller: WKWebExtensionController

    /// Ce qu'on a trouvé au dernier balayage, dossiers ouverts à la main compris.
    private(set) var installed: [InstalledExtension] = []
    /// Ce qui tourne, par identifiant.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private var failures: [String: String] = [:]
    /// Les icônes déjà lues, par identifiant — chaîne vide pour « cette extension n'en a
    /// pas ». La page se redessine à chaque changement d'état ; relire et réencoder un
    /// fichier par ligne à chaque fois serait payer le disque pour une image qui ne bouge
    /// pas entre deux balayages.
    private var icons: [String: String] = [:]
    /// Les chargements en vol, par identifiant.
    ///
    /// **Deux chargements de la même extension en produiraient deux contextes**, dont un
    /// que plus personne ne tiendrait. Le cas s'obtient sans effort : cocher, décocher,
    /// recocher avant que le paquet soit lu — la lecture est asynchrone, et rien d'autre
    /// ne dit qu'elle est en cours.
    private var loading: Set<String> = []
    /// Une notification par tour de boucle, et pas une par extension chargée.
    private var changeScheduled = false

    var loaded: [WKWebExtensionContext] { Array(contexts.values) }

    /// Prévenu dès que la liste change — au chargement, à l'activation, à l'échec.
    var onChange: (() -> Void)?

    /// **Un seul avertissement par tour de boucle.**
    ///
    /// Le démarrage en émettait un par balayage puis un par extension chargée, et chacun
    /// rafraîchissait la barre et rechargeait les pages ouvertes. Ils arrivent dans le même
    /// tour : les regrouper ne retarde rien et divise le travail par leur nombre.
    private func notifyChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeScheduled = false
                self.onChange?()
            }
        }
    }

    private unowned let settings: Settings

    init(settings: Settings, delegate: any WKWebExtensionControllerDelegate) {
        self.settings = settings
        // La configuration par défaut est persistante : le stockage d'une extension —
        // `storage.local`, ses cookies — survit au redémarrage, ce qu'une extension
        // suppose toujours. Une configuration éphémère la ferait repartir de zéro chaque
        // matin, sans que rien ne le dise.
        controller = WKWebExtensionController(configuration: .default())
        controller.delegate = delegate
    }

    // MARK: - Cycle de vie

    /// Balaye la machine, puis charge ce qui a été activé.
    func start() {
        migrateIfNeeded()
        rescan { [weak self] in
            guard let self else { return }
            for entry in installed where settings.enabledExtensions.contains(entry.id) {
                load(entry)
            }
        }
    }

    /// Relit ce qui a été désigné.
    ///
    /// **Le disque n'est plus parcouru.** Wuji ouvrait `/Applications` à chaque ouverture de
    /// la page et proposait tout ce qu'il y trouvait. C'était commode, et cela dressait sans
    /// qu'on l'ait demandée la liste de ce qui est installé sur l'ordinateur — pour un
    /// navigateur qui promet de ne rien apprendre de plus que nécessaire, la commodité ne
    /// payait pas ce prix. On désigne, il regarde ; il ne regarde rien d'autre.
    ///
    /// Une source disparue ne fait pas d'erreur, elle sort de la liste — c'est ce qui arrive
    /// quand on jette l'application, et l'annoncer comme une panne serait accuser le
    /// navigateur d'un rangement.
    func rescan(then finish: (@MainActor () -> Void)? = nil) {
        let sources = settings.extensionSources
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) {
                sources.reduce(FoundExtensions()) {
                    $0 + InstalledExtensions.resolve(URL(fileURLWithPath: $1))
                }
            }.value

            let entries = found.usable
            installed = entries
            // Les icônes suivent le paquet : une mise à jour de l'application peut en
            // changer, et rien ne coûte moins que de les relire une fois par balayage.
            icons.removeAll(keepingCapacity: true)
            // Une extension chargée dont le paquet a disparu quitte le moteur : la laisser
            // tourner ferait vivre du code qui n'est plus nulle part, et la page ne pourrait
            // plus l'éteindre — sa ligne n'existe plus.
            let known = Set(entries.map(\.id))
            for id in contexts.keys where !known.contains(id) { unload(id: id) }

            notifyChange()
            finish?()
        }
    }

    /// Ajoute ce qu'on vient de désigner : une application, un `.appex`, un dossier.
    ///
    /// Rend **tout** ce que le chemin portait : ce qui a été ajouté, et ce qui a été refusé
    /// avec sa raison. Une application se découpe couramment en plusieurs extensions dont
    /// une seule est du web ; taire les autres laisse croire à un ajout raté.
    @discardableResult
    func add(source url: URL) -> FoundExtensions {
        let found = InstalledExtensions.resolve(url)
        guard !found.usable.isEmpty else { return found }
        let path = url.standardizedFileURL.path
        if !settings.extensionSources.contains(path) { settings.extensionSources.append(path) }
        for entry in found.usable where !installed.contains(where: { $0.id == entry.id }) {
            installed.append(entry)
        }
        notifyChange()
        return found
    }

    /// **Retirer une extension retire ce qu'on avait désigné.** Une application porte
    /// parfois deux extensions web ; les deux s'en vont avec elle, parce que c'est
    /// l'application qui a été ajoutée et que garder l'une sans l'autre laisserait une ligne
    /// que plus rien ne rattache à une source.
    func remove(id: String) {
        guard let entry = installed.first(where: { $0.id == id }) else { return }
        let path = entry.source.standardizedFileURL.path
        settings.extensionSources.removeAll { $0 == path }
        for gone in installed where gone.source.standardizedFileURL.path == path {
            setEnabled(false, id: gone.id)
            failures[gone.id] = nil
        }
        installed.removeAll { $0.source.standardizedFileURL.path == path }
        notifyChange()
    }

    /// Retrouve, **une seule fois**, l'application qui porte une extension déjà activée.
    ///
    /// Sans cela, passer du balayage automatique à la désignation ferait disparaître de la
    /// liste des extensions que personne n'a retirées — et « mes extensions ont disparu » est
    /// le pire message qu'une mise à jour puisse faire passer. Ne tourne que si aucune source
    /// n'est enregistrée alors que des extensions le sont : c'est exactement l'état laissé
    /// par la version précédente, et il ne se reproduit pas.
    func migrateIfNeeded() {
        guard settings.extensionSources.isEmpty, !settings.enabledExtensions.isEmpty else {
            return
        }
        let enabled = Set(settings.enabledExtensions)
        let sources = InstalledExtensions.scanForMigration()
            .filter { enabled.contains($0.id) }
            .map { $0.source.standardizedFileURL.path }
        settings.extensionSources = Array(Set(sources)).sorted()
    }


    // MARK: - Activer, éteindre

    func isEnabled(_ id: String) -> Bool { settings.enabledExtensions.contains(id) }

    // MARK: - Épingler

    func isPinned(_ id: String) -> Bool { settings.pinnedExtensions.contains(id) }

    /// Épingler ou décrocher. **Seule une extension chargée peut l'être** : une icône
    /// posée dans la barre pour quelque chose qui ne tourne pas serait un bouton mort, et
    /// on n'a même pas son icône à afficher tant que le paquet n'a pas été lu.
    func setPinned(_ pinned: Bool, id: String) {
        guard pinned else {
            settings.pinnedExtensions.removeAll { $0 == id }
            notifyChange()
            return
        }
        guard contexts[id] != nil, !settings.pinnedExtensions.contains(id) else { return }
        settings.pinnedExtensions.append(id)
        notifyChange()
    }

    /// Les contextes épinglés, dans l'ordre de la barre. Une extension éteinte depuis
    /// qu'on l'a épinglée disparaît d'ici sans qu'on efface le réglage : la rallumer la
    /// remet où elle était.
    var pinned: [WKWebExtensionContext] {
        settings.pinnedExtensions.compactMap { contexts[$0] }
    }

    /// Ce qui tourne sans être épinglé — le contenu du menu du bouton.
    var unpinned: [WKWebExtensionContext] {
        contexts.filter { !settings.pinnedExtensions.contains($0.key) }.map(\.value)
    }

    func setEnabled(_ enabled: Bool, id: String) {
        if enabled {
            guard !settings.enabledExtensions.contains(id) else { return }
            settings.enabledExtensions.append(id)
            if let entry = installed.first(where: { $0.id == id }) { load(entry) }
        } else {
            settings.enabledExtensions.removeAll { $0 == id }
            // Une extension décochée pendant qu'elle se lit ne doit pas arriver après coup :
            // le chargement en vol vérifie l'état avant de poser son contexte.
            unload(id: id)
            // Épinglée puis éteinte, elle laisserait une icône qui ne pilote plus rien.
            settings.pinnedExtensions.removeAll { $0 == id }
        }
        notifyChange()
    }

    /// Charge une extension, et lui accorde ce que son manifeste demande.
    ///
    /// **L'accord est donné une fois, à l'activation, et il porte sur ce qui était
    /// affiché.** L'alternative — poser la question à chaque appel d'API — noierait la
    /// décision sous des bulles au moment où l'on regarde une page, c'est-à-dire au pire
    /// moment pour lire une liste d'hôtes. Ce qui est demandé en plus, après coup, passe
    /// bien par une question : voir `promptForPermissions` du côté de l'application.
    private func load(_ entry: InstalledExtension) {
        guard contexts[entry.id] == nil, !loading.contains(entry.id) else { return }
        loading.insert(entry.id)
        failures[entry.id] = nil

        Task { @MainActor in
            defer { loading.remove(entry.id) }
            do {
                let webExtension = try await make(entry)
                // La lecture du paquet a pris du temps, et l'état a pu changer pendant :
                // décochée entre-temps, ou chargée par un autre chemin. Charger quand même
                // poserait dans le moteur une extension que plus rien ne tient.
                guard settings.enabledExtensions.contains(entry.id),
                      contexts[entry.id] == nil else { return }
                let context = WKWebExtensionContext(for: webExtension)
                // L'identifiant décide où WebKit range le stockage de l'extension. Celui du
                // paquet est stable d'une version à l'autre ; un UUID tiré au lancement
                // aurait vidé `storage.local` à chaque démarrage.
                context.uniqueIdentifier = entry.id
                grant(webExtension.requestedPermissions,
                      patterns: webExtension.allRequestedMatchPatterns, to: context)

                try controller.load(context)
                contexts[entry.id] = context
                notifyChange()
            } catch {
                // L'erreur est gardée sous l'identifiant : la page la montre en face de la
                // ligne concernée, plutôt que dans une bulle qui s'en va.
                failures[entry.id] = Self.explain(error)
                notifyChange()
            }
        }
    }

    func make(_ entry: InstalledExtension) async throws -> WKWebExtension {
        if entry.isAppExtension, let bundle = Bundle(url: entry.url) {
            return try await WKWebExtension(appExtensionBundle: bundle)
        }
        return try await WKWebExtension(resourceBaseURL: entry.url)
    }

    /// Retire une extension du moteur.
    ///
    /// **L'échec est retenu, pas avalé.** Un déchargement qui échoue laisse l'extension
    /// dans le moteur alors que l'interface la dit éteinte : c'est exactement le genre
    /// d'écart qu'on ne remarque qu'après avoir cherché ailleurs pendant une heure.
    private func unload(id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        do {
            try controller.unload(context)
            failures[id] = nil
        } catch {
            failures[id] = "Déchargement refusé : " + Self.explain(error)
        }
    }

    /// Accorde une liste de permissions et d'hôtes à un contexte.
    ///
    /// Sans date d'expiration : une permission qui expire seule redemanderait la question
    /// un jour au hasard, sans que rien n'ait changé du côté de l'extension. Elle se retire
    /// en éteignant l'extension, ce qui est le geste qu'on cherche quand on veut la
    /// reprendre.
    func grant(_ permissions: Set<WKWebExtension.Permission>,
               patterns: Set<WKWebExtension.MatchPattern>,
               to context: WKWebExtensionContext) {
        for permission in permissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in patterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    /// Ce qu'une extension demanderait, lu **avant** de la charger.
    ///
    /// C'est ce qu'on affiche pour demander l'accord : le manifeste est analysé, rien
    /// n'est encore posé dans le moteur, et refuser ne laisse aucune trace.
    func requested(id: String) async -> (permissions: [String], hosts: [String])? {
        guard let entry = installed.first(where: { $0.id == id }),
              let webExtension = try? await make(entry) else { return nil }
        return (webExtension.requestedPermissions.map(\.rawValue).sorted(),
                webExtension.allRequestedMatchPatterns.map(\.string).sorted())
    }

    // MARK: - Ce que la page doit afficher

    /// Les lignes de la page : ce qui a été trouvé, et ce qu'il en est advenu.
    var listing: [Entry] { installed.map(entry(for:)) }

    private func entry(for item: InstalledExtension) -> Entry {
        let origin: String
        switch item.origin {
        case .appExtension(let host): origin = "Extension de « \(host) »"
        case .folder:                 origin = "Dossier · " + item.url.path
        }
        var entry = Entry(id: item.id, name: item.name, origin: origin,
                          isEnabled: isEnabled(item.id))
        entry.failure = failures[item.id]
        entry.isPinned = isPinned(item.id)
        entry.icon = icon(for: item)
        guard let context = contexts[item.id] else { return entry }
        entry.isLoaded = true
        let webExtension = context.webExtension
        entry.version = webExtension.displayVersion
        entry.summary = webExtension.displayDescription
        entry.permissions = webExtension.requestedPermissions
            .map(\.rawValue).sorted()
        entry.hosts = webExtension.allRequestedMatchPatterns
            .map(\.string).sorted()
        return entry
    }

    /// L'icône déclarée par le manifeste, lue une fois puis gardée.
    private func icon(for item: InstalledExtension) -> String? {
        if let cached = icons[item.id] { return cached.isEmpty ? nil : cached }
        let uri = InstalledExtensions.iconDataURI(for: item)
        icons[item.id] = uri ?? ""
        return uri
    }

    /// L'action d'une extension pour l'onglet courant — l'icône et son éventuelle bulle.
    func action(for tab: (any WKWebExtensionTab)?, in context: WKWebExtensionContext) -> WKWebExtension.Action? {
        context.action(for: tab)
    }

    /// Ce qu'un échec de chargement veut dire, en français.
    ///
    /// **Les codes de WebKit sont exacts et illisibles.** « Erreur 3 du domaine
    /// WKWebExtensionErrorDomain » ne dit pas s'il faut réessayer, mettre à jour ou
    /// renoncer ; ces trois-là le disent, et le reste tombe sur le message d'origine
    /// plutôt que sur une phrase inventée.
    static func explain(_ error: any Error) -> String {
        let error = error as NSError
        guard error.domain == WKWebExtension.errorDomain,
              let code = WKWebExtension.Error.Code(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .resourceNotFound:
            return "Un fichier annoncé par le manifeste est absent du paquet."
        case .invalidResourceCodeSignature:
            return "La signature du paquet ne correspond pas à son contenu."
        case .invalidManifest, .invalidManifestEntry:
            return "Le manifeste de cette extension n'est pas lisible."
        case .unsupportedManifestVersion:
            return "Cette version de manifeste n'est pas gérée par WebKit."
        case .invalidBackgroundPersistence:
            return "Le mode d'exécution de fond demandé n'est pas disponible."
        case .invalidArchive:
            return "L'archive de l'extension est illisible."
        case .invalidDeclarativeNetRequestEntry:
            return "Les règles de blocage déclarées par l'extension sont invalides."
        default:
            return error.localizedDescription
        }
    }
}
