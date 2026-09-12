import AppKit
import WebKit

/// Les règles à injection : ce qui est en service, et ce que chaque page reçoit.
extension AppDelegate {

    /// Aligne l'annexe sur les listes cochées.
    ///
    /// Rien n'est téléchargé quand l'interrupteur est fermé : une fonction coupée ne doit
    /// pas coûter de réseau, sans quoi la couper ne servirait qu'à moitié.
    func syncExtendedRules() {
        guard settings.injectedRulesEnabled, !settings.enabledRuleLists.isEmpty else {
            return extended.clear()
        }

        // **Rien n'est demandé à personne quand rien n'a changé.** On sait déjà, pour chaque
        // liste en service, si elle publie une annexe et sous quel nom : le retenir évite de
        // relire le catalogue à chaque lancement pour l'apprendre. Un navigateur qui
        // contacte un dépôt au démarrage doit avoir une raison, et « savoir ce qu'il sait
        // déjà » n'en est pas une.
        let voulus = settings.enabledRuleLists.map { id in
            ExtendedStore.Wanted(
                id: id,
                file: settings.extendedFiles[id].flatMap { $0.isEmpty ? nil : $0 },
                cache: ExtendedStore.cacheName(id, settings.ruleListVersions[id] ?? ""))
        }
        let tousConnus = settings.enabledRuleLists.allSatisfy { settings.extendedFiles[$0] != nil }
        if tousConnus, extended.loadCached(voulus) { return }

        Task { @MainActor in
            if ruleCatalog.isEmpty {
                ruleCatalog = (try? await RuleCatalog.fetch()) ?? []
            }
            guard !ruleCatalog.isEmpty else { return }
            let posées = Set(settings.enabledRuleLists)
            let listes = ruleCatalog.filter { posées.contains($0.id) }
            settings.batch {
                for liste in listes { settings.extendedFiles[liste.id] = liste.extendedFile ?? "" }
            }
            await extended.sync(listes)
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

        // **Dans tous les cadres, pas seulement le principal.** La moitié des encarts d'un
        // site vivent dans un `<iframe>` qu'il sert lui-même, et les règles écrites pour lui
        // ne les atteignaient pas. Chaque script vérifie chez qui il se réveille : le cadre
        // d'un tiers reçoit le code mais pas les règles, qui ne sont pas les siennes.
        if let moteur = CosmeticEngine.script(for: payload) {
            controller.addUserScript(WKUserScript(source: moteur, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .defaultClient))
        }
        if !payload.scriptlets.isEmpty {
            controller.addUserScript(WKUserScript(
                source: Scriptlets.script(for: payload.scriptlets, host: payload.host),
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }
}
