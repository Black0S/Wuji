import AppKit

/// Une vue qui se redessine quand le thème change.
///
/// Nécessaire à cause d'une asymétrie d'AppKit facile à manquer : un `NSColor` dynamique
/// affecté à `textColor` ou `contentTintColor` se résout **à chaque affichage**, donc il
/// suit le thème tout seul. Le même `NSColor` converti en `CGColor` pour un
/// `layer.backgroundColor` est résolu **une seule fois**, au moment de l'affectation, et
/// reste figé.
///
/// Sans ce rafraîchissement, passer en thème clair laisse tous les fonds en sombre
/// pendant que les textes basculent : on obtient du texte noir sur fond noir. Le symptôme
/// est spectaculaire, la cause est invisible à la relecture.
///
/// Toute vue qui pose une couleur dans son `layer` hérite d'ici.
class ThemedView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }
}
