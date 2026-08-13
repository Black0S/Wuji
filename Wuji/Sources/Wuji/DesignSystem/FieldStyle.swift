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
