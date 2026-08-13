import AppKit

/// Les tokens du design system (spec §5), juste ce qu'il faut pour le spike.
/// Tout en flat : aucune surface translucide, la profondeur vient de la valeur et de l'ombre.
enum Tokens {

    // MARK: - Grille 8 pt

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let pill: CGFloat = 12
        static let card: CGFloat = 16
    }

    // MARK: - Palette

    /// Fond des surfaces de chrome. Opaque : c'est toute la décision « flat ».
    static let chromeBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x1C1C1E))
    /// Le filet de 1 px est structurel, pas décoratif (spec §4.2) : sans lui, une pilule
    /// blanche opaque posée sur une page blanche disparaît.
    static let chromeHairline = dynamic(light: hex(0x000000, alpha: 0.12),
                                        dark: hex(0xFFFFFF, alpha: 0.16))
    static let textPrimary = dynamic(light: hex(0x1D1D1F), dark: hex(0xFFFFFF))
    /// #6E6E73 et non #8E8E93 : ce dernier tombe à 3,26:1 sur blanc, sous le seuil AA (spec §4.4).
    static let textSecondary = dynamic(light: hex(0x6E6E73), dark: hex(0x8E8E93))

    // MARK: - Couleur sémantique de sécurité (spec §4.3)

    /// Une seule famille, réservée exclusivement à la sécurité, jamais utilisée ailleurs.
    enum Security {
        static let insecure = dynamic(light: hex(0xC7302B), dark: hex(0xE0554F))
        static let permission = dynamic(light: hex(0xB2761B), dark: hex(0xD99A3A))
        static let privateSession = dynamic(light: hex(0x6B4FA8), dark: hex(0x9A7FD1))
        static let width: CGFloat = 3
    }

    // MARK: - Élévation — 3 niveaux maximum

    /// Ombre douce du chrome flottant au-dessus du contenu.
    @MainActor
    static func applyChromeShadow(to view: NSView) {
        view.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
    }

    // MARK: - Outils

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
