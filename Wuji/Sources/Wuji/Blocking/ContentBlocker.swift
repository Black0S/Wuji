import WebKit

/// Le bloqueur de contenu.
///
/// Il compile une liste de règles une fois, et WebKit l'applique ensuite **dans le moteur**,
/// avant qu'une requête parte. Rien ne remonte jusqu'à l'application : c'est ce qui rend le
/// filtrage gratuit à l'usage, et c'est aussi pourquoi Wuji ne peut pas afficher de compteur
/// de « publicités bloquées ». On préfère ne rien annoncer que d'annoncer un chiffre inventé.
///
/// **La liste est écrite ici, pas empruntée.** Embarquer EasyList poserait deux problèmes :
/// sa licence impose des obligations qu'un prototype ne tient pas, et une liste tierce mise
/// à jour toute seule est exactement le genre de trafic que ce navigateur promet de ne pas
/// faire dans le dos. La liste de base vise les régies et les traceurs les plus répandus ;
/// l'abonnement à une liste externe viendra comme un geste explicite, jamais par défaut.
@MainActor
final class ContentBlocker {

    enum State {
        case off
        case compiling
        case active(rules: Int, skipped: Int)
        case failed(String)

        var summary: String {
            switch self {
            case .off:                       return "Désactivé"
            case .compiling:                 return "Compilation…"
            case .active(let rules, let skipped):
                let base = "\(rules) règle\(rules > 1 ? "s" : "") active\(rules > 1 ? "s" : "")"
                return skipped > 0 ? "\(base) · \(skipped) sans équivalent" : base
            case .failed(let reason):        return "Échec · \(reason)"
            }
        }
    }

    private(set) var state: State = .off
    var onChange: (() -> Void)?

    /// L'identifiant sous lequel WebKit garde la liste compilée. Recompiler avec le même
    /// identifiant remplace l'ancienne : c'est ce qui permet d'ajouter une exception sans
    /// laisser deux listes se contredire.
    private static let identifier = "wuji.filters"

    private unowned let settings: Settings
    private var controllers: [WKUserContentController] = []
    private var compiled: WKContentRuleList?

    init(settings: Settings) {
        self.settings = settings
    }

    /// Les vues web partagent une configuration, donc un seul contrôleur — mais on garde
    /// une liste : une fenêtre privée en aura le sien.
    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
        if let compiled { controller.add(compiled) }
    }

    /// Recompile et réapplique. Appelé au démarrage, et à chaque fois qu'un réglage change
    /// ce que la liste doit contenir — l'interrupteur général comme les sites exclus.
    func reload() {
        guard settings.blockingEnabled else {
            compiled = nil
            controllers.forEach { $0.removeAllContentRuleLists() }
            state = .off
            onChange?()
            return
        }

        state = .compiling
        onChange?()

        var output = FilterConverter.rules(from: BuiltinFilters.list)
        // Les sites exclus passent en dernier et annulent ce qui précède, exactement comme
        // une règle `@@` du format d'origine.
        for host in settings.blockingExceptions {
            output.rules.append([
                "trigger": ["url-filter": ".*", "if-domain": ["*\(host)"]],
                "action": ["type": "ignore-previous-rules"]
            ])
        }

        guard let data = try? JSONSerialization.data(withJSONObject: output.rules),
              let json = String(data: data, encoding: .utf8) else {
            state = .failed("règles illisibles")
            onChange?()
            return
        }

        let rules = output.rules.count
        let skipped = output.rejected
        WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: json) {
                [weak self] list, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        // On le dit plutôt que de laisser croire à une protection : un
                        // bloqueur qui échoue en silence est pire que pas de bloqueur.
                        self.state = .failed(error.localizedDescription)
                        self.onChange?()
                        return
                    }
                    guard let list else { return }
                    self.compiled = list
                    for controller in self.controllers {
                        controller.removeAllContentRuleLists()
                        controller.add(list)
                    }
                    self.state = .active(rules: rules, skipped: skipped)
                    self.onChange?()
                }
            }
    }

    // MARK: - Exceptions par site

    func isExcepted(_ url: URL?) -> Bool {
        guard let host = url?.host() else { return false }
        return settings.blockingExceptions.contains(host)
    }

    /// Le bloqueur casse parfois une page — un lecteur vidéo, une banque, un mur de
    /// paiement. Pouvoir l'éteindre **sur ce site seulement** évite d'avoir à choisir
    /// entre la page et la protection partout ailleurs.
    func toggleException(for url: URL?) {
        guard let host = url?.host() else { return }
        if let index = settings.blockingExceptions.firstIndex(of: host) {
            settings.blockingExceptions.remove(at: index)
        } else {
            settings.blockingExceptions.append(host)
        }
        reload()
    }
}
