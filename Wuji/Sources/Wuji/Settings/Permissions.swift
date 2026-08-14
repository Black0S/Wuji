import Foundation

/// Les autorisations accordées aux sites : caméra, micro, position.
///
/// **Une décision par site, gardée jusqu'à ce qu'on la change.** Redemander à chaque visite
/// use la vigilance : on finit par accepter sans lire, ce qui est exactement ce qu'un
/// site abusif attend. Une décision se prend une fois, se retrouve dans les réglages, et
/// se révoque d'un clic.
///
/// **Le refus est le défaut.** Tant que rien n'a été décidé, la demande est présentée ;
/// tant qu'elle n'a pas été acceptée, rien ne s'allume.
@MainActor
final class Permissions {

    enum Kind: String, CaseIterable, Codable {
        case camera, microphone, both, location

        var label: String {
            switch self {
            case .camera:     return "la caméra"
            case .microphone: return "le micro"
            case .both:       return "la caméra et le micro"
            case .location:   return "votre position"
            }
        }
    }

    struct Decision: Codable {
        var host: String
        var kind: Kind
        var isAllowed: Bool
        var decided: Date
    }

    private(set) var decisions: [Decision] = []
    var onChange: (() -> Void)?

    private let store = UserDefaults.standard
    private let key = "sitePermissions"

    init() {
        guard let data = store.data(forKey: key),
              let stored = try? JSONDecoder().decode([Decision].self, from: data) else { return }
        decisions = stored
    }

    /// Ce qui a déjà été décidé pour ce site, s'il y a lieu.
    ///
    /// Une autorisation donnée pour les deux appareils vaut pour chacun pris à part : avoir
    /// accepté la caméra **et** le micro rend absurde de redemander pour le micro seul.
    func decision(host: String, kind: Kind) -> Bool? {
        if let exact = decisions.last(where: { $0.host == host && $0.kind == kind }) {
            return exact.isAllowed
        }
        // La position ne se déduit de rien : elle n'est pas un appareil de capture, et
        // avoir accepté la caméra ne dit rien de l'envie d'être localisé.
        if kind != .both, kind != .location,
           let both = decisions.last(where: { $0.host == host && $0.kind == .both }) {
            return both.isAllowed
        }
        return nil
    }

    func remember(host: String, kind: Kind, isAllowed: Bool) {
        decisions.removeAll { $0.host == host && $0.kind == kind }
        decisions.append(Decision(host: host, kind: kind, isAllowed: isAllowed, decided: Date()))
        save()
    }

    func forget(host: String, kind: String?) {
        decisions.removeAll { $0.host == host && (kind == nil || $0.kind.rawValue == kind) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(decisions) {
            store.set(data, forKey: key)
        }
        onChange?()
    }
}
