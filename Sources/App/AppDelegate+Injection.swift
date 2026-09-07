import AppKit
import WebKit

/// Les règles à injection : ce qui est en service, et ce que chaque page reçoit.
extension AppDelegate {

    /// Aligne l'annexe sur les listes cochées.
    ///
    /// Rien n'est téléchargé quand l'interrupteur est fermé : une fonction coupée ne doit
    /// pas coûter de réseau, sans quoi la couper ne servirait qu'à moitié.
    func syncExtendedRules() {
        guard settings.injectedRulesEnabled else { return extended.clear() }
        Task { @MainActor in
            if ruleCatalog.isEmpty {
                ruleCatalog = (try? await RuleCatalog.fetch()) ?? []
            }
            let posées = Set(settings.enabledRuleLists)
            await extended.sync(ruleCatalog.filter { posées.contains($0.id) })
        }
    }

    /// Ce que cette adresse reçoit — ou rien, ce qui est le cas de presque toutes.
    ///
    /// **La pause d'un site vaut aussi ici.** Suspendre le blocage sur un site et continuer
    /// d'y injecter du style serait une pause qui n'en est pas une : c'est le même geste,
    /// pour la même raison — une page qui se casse se répare en levant tout.
    func injectionPayload(for url: URL?) -> ExtendedStore.Payload {
        guard settings.injectedRulesEnabled, !extended.isEmpty,
              let url, url.scheme?.hasPrefix("http") == true,
              let host = url.host(), !blocking.isPaused(host) else { return .init() }
        return extended.payload(for: host.lowercased())
    }

    /// Pose le moteur et les primitives sur l'onglet, pour l'adresse où il va.
    ///
    /// Deux mondes, et ce n'est pas un détail : le moteur cosmétique vit dans le monde de
    /// Wuji — il n'a rien à faire dans celui de la page, et la page n'a rien à y lire —,
    /// tandis qu'une primitive nommée doit s'exécuter **dans** le monde de la page, puisque
    /// son travail est d'y remplacer une propriété avant que les scripts du site ne la
    /// lisent. Poser la seconde dans un monde isolé la rendrait parfaitement inoffensive.
    func installInjectedRules(for url: URL?, in controller: WKUserContentController) {
        let payload = injectionPayload(for: url)
        guard !payload.isEmpty else { return }

        if let moteur = CosmeticEngine.script(for: payload) {
            controller.addUserScript(WKUserScript(source: moteur, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .defaultClient))
        }
        if !payload.scriptlets.isEmpty {
            controller.addUserScript(WKUserScript(source: Scriptlets.script(for: payload.scriptlets),
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
    }
}
