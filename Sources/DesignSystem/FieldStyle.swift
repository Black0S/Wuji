import AppKit

/// Un champ de saisie aux mesures du design system.
///
/// `NSTextField` pose son texte en haut de son cadre et le colle au bord gauche : dans une
/// carte flat, ça se voit immédiatement — le texte flotte au-dessus de sa boîte au lieu
/// d'y être posé. Cette cellule le recentre verticalement et lui donne une marge, en
/// dessin **comme en édition**, sinon le texte saute au moment où l'on clique dedans.
final class InsetTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { InsetTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    var contentInset: CGFloat {
        get { (cell as? InsetTextFieldCell)?.contentInset ?? 0 }
        set { (cell as? InsetTextFieldCell)?.contentInset = newValue }
    }

    /// Une étiquette qui se centre **verticalement** dans son cadre.
    ///
    /// `NSTextField` pose son texte en haut du cadre qu'on lui donne. Le réflexe est de
    /// lui donner un cadre à la hauteur du texte et de le centrer soi-même — mais cette
    /// hauteur est une estimation, et il reste toujours un point ou deux d'écart avec le
    /// glyphe d'à côté. Ici c'est la cellule qui centre, sur la hauteur réelle du texte.
    static func label(_ text: String = "", size: CGFloat = 13,
                      weight: NSFont.Weight = .regular,
                      alignment: NSTextAlignment = .left) -> InsetTextField {
        let field = InsetTextField(labelWithString: text)
        field.contentInset = 0
        field.font = .systemFont(ofSize: size, weight: weight)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Une étiquette qui se replie sur plusieurs lignes. Elle ne se centre pas : un
    /// paragraphe se lit depuis son coin haut gauche, et le centrage vertical de la
    /// cellule ferait flotter la première ligne.
    static func wrapping(_ text: String = "", size: CGFloat = 12) -> InsetTextField {
        let field = InsetTextField(wrappingLabelWithString: text)
        field.contentInset = 0
        field.font = .systemFont(ofSize: size)
        field.isSelectable = false
        return field
    }
}

/// Un champ de saisie **dans une boîte dessinée** : bord, coin arrondi, fond en retrait.
///
/// Le champ bordé du système apporte son propre dessin — un cadre gris, un liseré bleu au
/// focus — qui ne ressemble à rien d'autre dans cette application. On le débarrasse de son
/// habillage et on pose la boîte nous-mêmes, comme l'interrupteur des réglages est dessiné
/// plutôt qu'emprunté.
@MainActor
final class BoxedField: ThemedView {

    private let field: NSTextField

    /// ⏎ dans le champ. Un formulaire qui ne se valide qu'au clic fait taper puis viser.
    var onSubmit: (() -> Void)?

    init(placeholder: String, isSecure: Bool = false) {
        field = isSecure ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Le curseur est-il dans ce champ ? Sert à savoir où ⏎ doit mener.
    var isEditing: Bool { field.currentEditor() != nil }

    func focus() { window?.makeFirstResponder(field) }

    @objc private func submit() { onSubmit?() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Tokens.selectionFill.cgColor
        layer?.borderColor = Tokens.chromeHairline.cgColor
        field.textColor = Tokens.textPrimary
    }
}

private final class InsetTextFieldCell: NSTextFieldCell {

    var contentInset: CGFloat = 10

    private func centred(_ frame: NSRect) -> NSRect {
        let height = cellSize(forBounds: frame).height
        return NSRect(x: frame.minX + contentInset,
                      y: frame.midY - height / 2,
                      width: max(0, frame.width - contentInset * 2),
                      height: height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: centred(cellFrame), in: controlView)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centred(rect), in: controlView,
                     editor: editor, delegate: delegate, start: start, length: length)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centred(rect), in: controlView,
                   editor: editor, delegate: delegate, event: event)
    }
}
