import AppKit

/// Une entrée de menu, décrite plutôt que construite.
///
/// `ActionItem` reste la monnaie commune de toute l'application : les menus se déclarent
/// en tableaux, et un seul endroit sait les transformer en `NSMenu`. Le jour où l'on
/// voudra la même liste ailleurs — une barre, une palette — c'est ce type qu'on relira,
/// pas trente appels à AppKit dispersés.
struct ActionItem {
    let title: String
    var symbol: String?
    /// Une image toute faite, quand l'entrée n'appartient pas à Wuji : l'icône d'une
    /// extension vient de son paquet, elle n'a pas de nom de symbole système.
    var image: NSImage?
    /// Le raccourci **tel qu'il s'affiche** : « ⌘T », « ⇧⌘B ». Il est relu par
    /// `NativeMenu` pour en tirer la touche et ses modificateurs — ce qui garantit que
    /// l'étiquette et la touche réelle ne peuvent pas diverger.
    var shortcut: String?
    var isEnabled = true
    var isDestructive = false
    var children: [ActionItem]?
    var action: (@MainActor () -> Void)?

    static let separator = ActionItem(title: "—", isEnabled: false)
    var isSeparator: Bool { title == "—" && action == nil && children == nil && !isEnabled }
}

/// Les menus de l'application, en `NSMenu`.
///
/// **Ils l'ont été, puis ne l'ont plus été, et le redeviennent.** Une feuille dessinée à
/// la main tenait la direction artistique d'un seul tenant ; elle refaisait aussi, moins
/// bien, ce que le système fait depuis quarante ans — le repli quand la place manque, la
/// navigation au clavier, VoiceOver, la répétition des touches, le survol qui traverse un
/// sous-menu en diagonale, le respect des réglages d'accessibilité. Un menu est le seul
/// endroit de l'interface où l'habitude vaut plus que la cohérence visuelle : on y vise
/// sans lire, avec des gestes appris ailleurs.
@MainActor
enum NativeMenu {

    /// Sous un bouton de barre, comme un menu contextuel de barre d'outils : le coin
    /// supérieur gauche du menu tombe sous le coin inférieur gauche du bouton. AppKit se
    /// charge de le rabattre si l'écran manque à droite ou en bas.
    static func popUp(_ items: [ActionItem], below view: NSView) {
        guard let menu = make(items) else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: view.bounds.minY - Tokens.Space.xs),
                   in: view)
    }

    /// À un point d'une vue — pour tout ce qui s'ouvre au clic droit.
    ///
    /// `appending` reçoit des `NSMenuItem` déjà faits. Une seule chose en produit : les
    /// entrées que WebKit fabrique lui-même pour le menu contextuel. Elles ne
    /// passent pas par `ActionItem` parce qu'elles n'ont ni symbole ni fermeture à nous
    /// donner — elles portent leur propre cible, et c'est très bien ainsi.
    static func popUp(_ items: [ActionItem], appending extra: [NSMenuItem] = [],
                      at point: NSPoint, in view: NSView) {
        guard let menu = make(items, appending: extra) else { return }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// Une saisie : la question, un champ, deux issues.
    ///
    /// `NSAlert` en feuille sur la fenêtre plutôt qu'une boîte flottante : le renommage
    /// porte sur quelque chose qu'on voit derrière, et une feuille garde le lien entre la
    /// question et son objet. Le bouton d'action est nommé par son verbe — « Renommer »,
    /// pas « OK » : on lit ce qu'on est en train de faire.
    static func prompt(title: String, value: String, confirm: String, in window: NSWindow?,
                       onConfirm: @escaping @MainActor (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Annuler")

        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        // Une seule ligne, qui défile : un titre de page long ne doit pas enrouler le champ
        // sur deux lignes au milieu d'une feuille.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        alert.accessoryView = field
        // Sans ça, le curseur reste sur le bouton : on tape et rien ne s'écrit.
        alert.window.initialFirstResponder = field

        let commit = { @MainActor (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            onConfirm(name)
        }

        guard let window else { return commit(alert.runModal()) }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { commit(response) }
        }
    }

    /// Demande un secret, avec confirmation quand on en pose un nouveau.
    ///
    /// **Un champ sécurisé et pas un champ ordinaire** : le mot de passe maître ouvre tout
    /// le coffre, et l'afficher en clair le montre à qui passe derrière — et à toute
    /// capture d'écran.
    ///
    /// **Deux champs quand on le crée, un seul quand on l'entre.** Un coffre chiffré n'a
    /// pas de récupération : une faute de frappe au moment de le créer le rendrait
    /// inouvrable, sans que rien ne le signale avant la prochaine ouverture. La
    /// confirmation est la seule chose qui protège de cela, et elle ne coûte qu'un champ.
    static func secret(title: String, message: String, confirm: String,
                       confirming: Bool, in window: NSWindow?,
                       onConfirm: @escaping @MainActor (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Annuler")

        let height: CGFloat = confirming ? 56 : 24
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        let first = NSSecureTextField(frame: NSRect(x: 0, y: confirming ? 32 : 0,
                                                    width: 280, height: 24))
        first.placeholderString = "Mot de passe maître"
        container.addSubview(first)

        var second: NSSecureTextField?
        if confirming {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "Confirmer"
            container.addSubview(field)
            first.nextKeyView = field
            second = field
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = first

        let commit = { @MainActor (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            let value = first.stringValue
            guard !value.isEmpty else { return }
            // La confirmation est vérifiée ici et pas plus loin : l'appelant range un
            // secret, il n'a pas à savoir qu'on l'a demandé deux fois.
            if let second, second.stringValue != value { return onConfirm("") }
            onConfirm(value)
        }

        guard let window else { return commit(alert.runModal()) }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { commit(response) }
        }
    }

    // MARK: - Construction

    /// Un menu vide n'est pas ouvert : AppKit afficherait un rectangle d'une ligne de haut,
    /// qui ne dit rien et se referme au premier clic.
    static func make(_ items: [ActionItem], appending extra: [NSMenuItem] = []) -> NSMenu? {
        guard items.contains(where: { !$0.isSeparator }) || !extra.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(build(item)) }
        if !extra.isEmpty, !items.isEmpty { menu.addItem(.separator()) }
        // Un `NSMenuItem` n'appartient qu'à un menu à la fois : WebKit rend des entrées
        // neuves à chaque appel, mais une copie coûte moins qu'un plantage le jour où il
        // se mettrait à les réutiliser.
        for item in extra { menu.addItem(item.copy() as? NSMenuItem ?? item) }
        return menu
    }

    private static func build(_ item: ActionItem) -> NSMenuItem {
        guard !item.isSeparator else { return .separator() }

        let (key, modifiers) = shortcut(item.shortcut)
        let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.isEnabled = item.isEnabled

        if let image = item.image {
            image.size = NSSize(width: 16, height: 16)
            entry.image = image
        } else if let symbol = item.symbol {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        // « Différencier sans couleur » vaut aussi ici : le rouge d'une entrée destructrice
        // s'ajoute au verbe, il ne le remplace pas.
        if item.isDestructive {
            entry.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.menuFont(ofSize: 0)])
        }

        if let children = item.children {
            entry.submenu = make(children) ?? NSMenu()
            return entry
        }

        if let action = item.action {
            let target = ActionTarget(action)
            entry.target = target
            entry.action = #selector(ActionTarget.fire)
            // L'entrée est le seul propriétaire de sa cible : `NSMenuItem.target` est une
            // référence faible, et sans cet ancrage la fermeture mourrait avant le clic.
            entry.representedObject = target
        }
        return entry
    }

    /// Le raccourci écrit, rendu à AppKit.
    ///
    /// **Une seule source pour l'étiquette et la touche.** Les deux se déclaraient
    /// séparément dans les menus dessinés à la main, et une entrée a fini par annoncer un
    /// raccourci qui n'était plus le bon — un libellé qui ment sur ce qu'il faut taper est
    /// pire que pas de libellé du tout. Ici la chaîne affichée *est* la déclaration.
    static func shortcut(_ text: String?) -> (String, NSEvent.ModifierFlags) {
        guard var text, !text.isEmpty else { return ("", []) }
        var modifiers: NSEvent.ModifierFlags = []
        let known: [(Character, NSEvent.ModifierFlags)] = [
            ("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)
        ]
        while let first = text.first, let match = known.first(where: { $0.0 == first }) {
            modifiers.insert(match.1)
            text.removeFirst()
        }
        // AppKit veut la touche en minuscule : la majuscule y ajoute un ⇧ implicite, et
        // « ⇧⌘T » se serait affiché « ⇧⇧⌘T ».
        return (text.lowercased(), modifiers)
    }
}

/// Le porteur d'une fermeture, pour qu'un `NSMenuItem` puisse en déclencher une.
///
/// `NSMenuItem` ne connaît que la paire cible/sélecteur. Plutôt que de faire de chaque
/// appelant une cible avec un `switch` sur des étiquettes, chaque entrée porte la sienne.
@MainActor
private final class ActionTarget: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func fire() { action() }
}
