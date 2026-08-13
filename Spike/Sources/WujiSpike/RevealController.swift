import AppKit

/// La révélation à l'intention.
///
/// Quatre candidats coexistent ici et se combinent (ou s'isolent) au menu, parce que le
/// seul moyen de trancher est de vivre avec chacun. Le compteur par source est
/// l'instrument : à la fin de la semaine 3, on regarde lequel a réellement servi.
///
/// Rappel du problème : deux doigts vers le haut sur trackpad, **c'est le défilement de
/// la page**. Le geste des maquettes entre en collision frontale avec la lecture.
@MainActor
final class RevealController: RevealGestureDelegate {

    enum State { case immersive, revealed }

    /// Bande haute qui déclenche la révélation (candidat C).
    private let revealZone: CGFloat = 6
    /// Zone de maintien, plus haute que la bande de déclenchement : c'est l'hystérésis.
    /// Sans elle, le chrome clignote dès que la main tremble à la frontière.
    private let keepZone: CGFloat = 96
    /// Délai avant escamotage, pour ne pas punir un aller-retour du curseur.
    private let hideDelay: TimeInterval = 0.35

    private(set) var state: State = .revealed
    /// Candidat C, activable/désactivable comme les autres pour pouvoir les isoler.
    var isEdgeEnabled = true

    private var hideWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var monitor: Any?

    private unowned let window: SpikeWindow

    /// Ce qui apparaît et disparaît. La sidebar et la barre du haut bougent **ensemble** :
    /// ce n'est pas un second système d'auto-masquage pour la sidebar, c'est le même
    /// comportement appliqué à une vue de plus.
    var applyChrome: (_ visible: Bool, _ animated: Bool) -> Void = { _, _ in }

    /// Ce qui interdit l'escamotage. Aujourd'hui : la palette ouverte. Demain : un menu
    /// déroulé, un téléchargement en cours, un champ de formulaire en édition. Une seule
    /// porte, pour ne pas se retrouver avec quatre conditions éparpillées.
    var shouldStayRevealed: () -> Bool = { false }

    /// Instrumentation pour le journal de frictions de la semaine 3.
    private(set) var revealCounts: [RevealSource: Int] = [:]

    init(window: SpikeWindow) {
        self.window = window
        // On démarre chrome visible, et non en immersif : au premier lancement, une page
        // nue sans le moindre repère est le scénario qui fait désinstaller en trente
        // secondes (spec §4.5). Le premier mouvement de souris l'escamote.
        apply(.revealed, animated: false)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Candidat C : le curseur au bord haut

    private func handle(_ event: NSEvent) {
        guard isEdgeEnabled, event.window === window, let content = window.contentView else { return }
        // Coordonnées AppKit : origine en bas à gauche, donc le haut est la valeur maximale.
        let distanceFromTop = content.bounds.height - event.locationInWindow.y
        let distanceFromLeft = event.locationInWindow.x

        // Deux bords, parce qu'il y a deux surfaces : la barre en haut, la sidebar à
        // gauche. Viser la sidebar par le bord haut serait un détour absurde.
        let atEdge = distanceFromTop <= revealZone || distanceFromLeft <= revealZone
        let insideKeep = distanceFromTop <= keepZone || distanceFromLeft <= Tokens.Chrome.sidebarWidth

        if atEdge {
            reveal(from: .edge)
        } else if !insideKeep {
            scheduleHide()
        } else if state == .revealed {
            cancelHide()   // dans la zone de maintien : on reste ouvert
        }
    }

    // MARK: - Candidats A et B

    func gesture(_ source: RevealSource, requestsReveal: Bool) {
        if requestsReveal {
            reveal(from: source)
            // Un geste n'a pas de curseur qui « reste dans la zone » : sans escamotage
            // programmé, le chrome ne repartirait jamais.
            scheduleHide(after: 2.5)
        } else {
            hideNow()
        }
    }

    // MARK: - Transitions

    func reveal(from source: RevealSource) {
        cancelHide()
        guard state == .immersive else { return }
        revealCounts[source, default: 0] += 1
        apply(.revealed, animated: true)
    }

    func hideNow() {
        cancelHide()
        // Ne jamais escamoter le chrome pendant que l'utilisateur écrit dans la palette.
        guard state == .revealed, !shouldStayRevealed() else { return }
        apply(.immersive, animated: true)
    }

    private func scheduleHide(after delay: TimeInterval? = nil) {
        guard state == .revealed else { return }
        cancelHide()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hideWorkItem = nil
                self?.hideNow()
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? hideDelay), execute: item)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func apply(_ newState: State, animated: Bool) {
        state = newState
        let visible = newState == .revealed
        window.setTrafficLights(visible: visible, animated: animated)
        applyChrome(visible, animated)
    }

    // MARK: - Journal

    func summary() -> String {
        let lines = RevealSource.allCases.map { source in
            "  \(source.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(revealCounts[source] ?? 0)"
        }
        return (["[spike] révélations par source :"] + lines).joined(separator: "\n")
    }
}
