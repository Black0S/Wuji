import CoreLocation

/// L'autorisation de position, côté système.
///
/// **Deux portes, et il faut passer les deux.** Le site demande la position à Wuji, et
/// Wuji doit lui-même être autorisé par macOS — accorder la première sans la seconde donne
/// exactement ce qu'on a vu : l'utilisateur dit oui, et la page reçoit un refus qu'elle
/// attribue à l'utilisateur.
///
/// La demande système n'est faite qu'au moment où quelqu'un dit oui à un site. Un
/// navigateur qui réclame la position au premier lancement, avant que personne l'ait
/// demandée, apprend à dire oui sans lire.
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    /// Les demandes en attente de la réponse du système. Plusieurs onglets peuvent
    /// demander en même temps, et la boîte système n'apparaît qu'une fois.
    private var pending: [(Bool) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Le système laissera-t-il Wuji connaître la position ? La réponse peut demander un
    /// aller-retour par une boîte de dialogue, d'où le rappel.
    func authorize(_ completion: @escaping (Bool) -> Void) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            completion(true)
        case .denied, .restricted:
            // Rien à négocier ici : seul le panneau Confidentialité de macOS peut revenir
            // là-dessus, et redemander en boucle ne ferait qu'agacer.
            completion(false)
        default:
            pending.append(completion)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Vrai quand c'est macOS qui bloque, et non l'utilisateur de Wuji : le message à
    /// afficher n'est pas le même.
    var isBlockedBySystem: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Le statut est relu depuis notre propre gestionnaire : passer celui du rappel à
        // travers l'isolation ferait franchir une frontière à un objet qui n'est pas fait
        // pour ça, et le compilateur a raison de le refuser.
        MainActor.assumeIsolated {
            let status = self.manager.authorizationStatus
            guard status != .notDetermined else { return }
            let granted = status == .authorizedAlways || status == .authorized
            let waiting = pending
            pending = []
            waiting.forEach { $0(granted) }
        }
    }
}
