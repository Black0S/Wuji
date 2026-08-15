import AppKit

/// Les tokens du design system (spec §5), juste ce qu'il faut pour le prototype.
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

    /// La sidebar est en retrait par rapport au contenu, pas en avant : elle est le cadre,
    /// la page est le sujet. D'où un fond plus sourd que la barre du haut — en clair comme
    /// en sombre, sinon les deux surfaces fusionnent et la colonne disparaît.
    static let sidebarBackground = dynamic(light: hex(0xF5F5F7), dark: hex(0x141416))

    /// La ligne sélectionnée, elle, ressort — seul élément surélevé de la sidebar.
    static let rowSelected = dynamic(light: hex(0xFFFFFF), dark: hex(0x2C2C2E))
    /// Le filet de 1 px est structurel, pas décoratif (spec §4.2) : sans lui, une pilule
    /// blanche opaque posée sur une page blanche disparaît.
    static let chromeHairline = dynamic(light: hex(0x000000, alpha: 0.12),
                                        dark: hex(0xFFFFFF, alpha: 0.16))
    static let textPrimary = dynamic(light: hex(0x1D1D1F), dark: hex(0xFFFFFF))
    /// #6E6E73 et non #8E8E93 : ce dernier tombe à 3,26:1 sur blanc, sous le seuil AA (spec §4.4).
    static let textSecondary = dynamic(light: hex(0x6E6E73), dark: hex(0x8E8E93))

    /// Sélection dans une liste. En monochrome, la sélection ne peut pas être une teinte :
    /// c'est un écart de valeur, et il doit rester lisible sous « Différencier sans couleur ».
    static let selectionFill = dynamic(light: hex(0x000000, alpha: 0.07),
                                       dark: hex(0xFFFFFF, alpha: 0.10))
    static let separator = dynamic(light: hex(0x000000, alpha: 0.08),
                                   dark: hex(0xFFFFFF, alpha: 0.10))

    // MARK: - Couleur sémantique de sécurité (spec §4.3)

    /// Une seule famille, réservée exclusivement à la sécurité, jamais utilisée ailleurs.
    /// Les teintes « permission active » et « session privée » de la spec §4.3 arriveront
    /// avec les fonctionnalités qu'elles signalent.
    enum Security {
        static let insecure = dynamic(light: hex(0xC7302B), dark: hex(0xE0554F))
        static let width: CGFloat = 3
    }

    // MARK: - Lignes de liste

    /// Les mesures d'une ligne, partout : sidebar, panneau des espaces, feuille d'action.
    ///
    /// Elles existent pour qu'une surface ajoutée demain n'ait aucun nombre à inventer.
    /// Deux hauteurs seulement, et la règle qui les sépare : **une liste qu'on parcourt
    /// respire, un menu qu'on vise est dense.** Tout le reste est commun, sinon deux
    /// listes côte à côte n'alignent ni leurs glyphes ni leurs textes.
    enum Row {
        /// Listes que l'on parcourt : onglets, dossiers, espaces.
        static let height: CGFloat = 34
        /// Menus et feuilles d'action, où l'on vise une entrée précise.
        static let compact: CGFloat = 32
        /// Écart vertical entre deux lignes. Sans lui, le contour de la ligne active vient
        /// toucher le fond de la survolée, et deux surfaces collées se lisent comme une.
        static let gap: CGFloat = 3
        static let radius: CGFloat = 8
        /// Marge horizontale à l'intérieur d'une ligne.
        static let inset: CGFloat = 12
        static let glyph: CGFloat = 15
        /// Entre le glyphe et le texte.
        static let glyphGap: CGFloat = 12
        /// Décalage d'un niveau de profondeur.
        static let indent: CGFloat = 16
    }

    /// Les mesures d'une carte flottante : palette, panneau, feuille, confirmation.
    enum Card {
        static let radius = Radius.card
        /// Marge autour de la pile de lignes.
        static let padding: CGFloat = 8
        /// Marge des blocs de texte — titre, message, champ.
        static let textInset: CGFloat = 16
    }

    // MARK: - Métriques du chrome

    /// Une seule source de vérité pour la disposition du chrome. Chaque vue qui calculait
    /// sa propre position finissait par se superposer à une autre — c'est exactement ce
    /// qui est arrivé entre la barre d'adresse et la barre d'onglets.
    enum Chrome {
        static let sidebarWidth: CGFloat = 202
        /// Assez haute pour une cible de clic confortable, pas plus : la barre du haut
        /// est un cadre, pas un panneau. Chaque point de hauteur est pris à la page.
        static let topBarHeight: CGFloat = 38
        /// Hauteur réservée aux feux de circulation en haut de la sidebar. macOS les place
        /// lui-même : tout ce qui commence au-dessus passe dessous.
        static let trafficLights: CGFloat = 44

        /// Le contenu s'arrondit à l'angle où la sidebar et la barre du haut se rejoignent.
        /// Sidebar et barre partagent la même couleur : sans cette courbe, leur jonction
        /// formerait un angle droit dur au milieu de la fenêtre. La courbe est ce qui les
        /// fait lire comme un seul cadre continu plutôt que comme deux bandes collées.
        static let contentCorner: CGFloat = 10
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

    /// Résout une couleur dynamique contre une apparence précise.
    ///
    /// Nécessaire dès qu'une couleur quitte AppKit — `underPageBackgroundColor` de WebKit,
    /// par exemple. Une couleur dynamique posée hors d'un contexte de dessin se résout
    /// contre l'apparence courante du moment, qui n'est pas encore celle qu'on vient de
    /// choisir : elle reste alors figée sur la valeur précédente.
    @MainActor
    static func resolve(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
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
