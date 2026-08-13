import AppKit

/// **Mode horizontal.** La barre d'onglets classique, en pilule flat sous la barre d'adresse.
///
/// Elle ne connaît que des `TabSnapshot` et ne peut pas voir `TabSidebar` : c'est la
/// garantie mécanique que les deux modes ne se contamineront pas (spec §6.1, règle 2).
@MainActor
final class TabStrip: NSView, TabsView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let surface = TabsStyle.makeSurface()
    private var items: [TabChip] = []
    private let newButton = NSButton()

    private static let maxWidth: CGFloat = 900
    private static let chipWidth: CGFloat = 160
    private static let newButtonWidth: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(surface)

        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Nouvel onglet")
        newButton.isBordered = false
        newButton.imagePosition = .imageOnly
        newButton.contentTintColor = Tokens.textSecondary
        newButton.target = self
        newButton.action = #selector(newTab)
        surface.addSubview(newButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return surface.frame.contains(local) ? super.hitTest(point) : nil
    }

    func update(tabs: [TabSnapshot], selected: Int) {
        items.forEach { $0.removeFromSuperview() }
        items = tabs.enumerated().map { index, snapshot in
            let chip = TabChip(snapshot: snapshot, isSelected: index == selected)
            chip.onSelect = { [weak self] in self?.onSelect?(index) }
            chip.onClose = { [weak self] in self?.onClose?(index) }
            surface.addSubview(chip)
            return chip
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        TabsStyle.paint(surface)
        newButton.contentTintColor = Tokens.textSecondary

        let count = CGFloat(max(items.count, 1))
        let chipWidth = min(Self.chipWidth, (Self.maxWidth - Self.newButtonWidth) / count)
        let surfaceWidth = min(Self.maxWidth, chipWidth * count + Self.newButtonWidth + Tokens.Space.s)

        // Second bandeau : sous la barre d'adresse, jamais dessus.
        surface.frame = NSRect(x: (bounds.width - surfaceWidth) / 2,
                               y: Tokens.Chrome.row2(in: bounds),
                               width: surfaceWidth,
                               height: TabsStyle.stripHeight)

        for (index, chip) in items.enumerated() {
            chip.frame = NSRect(x: Tokens.Space.xs + CGFloat(index) * chipWidth,
                                y: Tokens.Space.xs,
                                width: chipWidth - 2,
                                height: TabsStyle.stripHeight - Tokens.Space.s)
        }
        newButton.frame = NSRect(x: surfaceWidth - Self.newButtonWidth,
                                 y: 0, width: Self.newButtonWidth, height: TabsStyle.stripHeight)
    }

    @objc private func newTab() { onNew?() }
}

/// Un onglet dans la barre. En monochrome, l'onglet actif se distingue par un écart de
/// valeur et jamais par une teinte.
@MainActor
private final class TabChip: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let isSelected: Bool

    init(snapshot: TabSnapshot, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        label.stringValue = snapshot.isLoading ? "· \(snapshot.title)" : snapshot.title
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer l'onglet")
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.target = self
        close.action = #selector(closeTab)
        addSubview(close)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? Tokens.textPrimary : Tokens.textSecondary
        close.contentTintColor = Tokens.textSecondary

        let closeWidth: CGFloat = 20
        label.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 16) / 2,
                             width: bounds.width - closeWidth - Tokens.Space.m, height: 16)
        close.frame = NSRect(x: bounds.width - closeWidth - Tokens.Space.xs,
                             y: (bounds.height - closeWidth) / 2,
                             width: closeWidth, height: closeWidth)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closeTab() { onClose?() }
}
