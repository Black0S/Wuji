import AppKit

/// **Mode vertical.** La sidebar auto-masquée : le vertical sans la perte de place du
/// vertical (spec §4.1).
///
/// Elle vit dans la même couche de révélation que le reste du chrome — donc elle apparaît
/// et disparaît avec lui, sur les mêmes seuils. C'est le point important : ce n'est pas un
/// second système d'auto-masquage, c'est le même comportement appliqué à une vue de plus.
///
/// Comme `TabStrip`, elle ne connaît que des `TabSnapshot`, et les deux ne peuvent pas
/// se voir.
@MainActor
final class TabSidebar: NSView, TabsView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let surface = TabsStyle.makeSurface()
    private var rows: [TabRow] = []
    private let newButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(surface)

        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Nouvel onglet")
        newButton.title = "  Nouvel onglet"
        newButton.imagePosition = .imageLeading
        newButton.isBordered = false
        newButton.alignment = .left
        newButton.font = .systemFont(ofSize: 12, weight: .regular)
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
        rows.forEach { $0.removeFromSuperview() }
        rows = tabs.enumerated().map { index, snapshot in
            let row = TabRow(snapshot: snapshot, isSelected: index == selected)
            row.onSelect = { [weak self] in self?.onSelect?(index) }
            row.onClose = { [weak self] in self?.onClose?(index) }
            surface.addSubview(row)
            return row
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        TabsStyle.paint(surface)
        newButton.contentTintColor = Tokens.textSecondary

        // Le haut de la sidebar s'aligne sous le bandeau principal, pour ne pas lui
        // passer dessus ni passer sous les feux de circulation.
        let top = Tokens.Chrome.row1(in: bounds) - Tokens.Space.s
        let height = min(top - Tokens.Space.xl,
                         CGFloat(rows.count + 1) * TabsStyle.rowHeight + Tokens.Space.l)

        surface.frame = NSRect(x: Tokens.Space.l,
                               y: top - height,
                               width: TabsStyle.sidebarWidth,
                               height: height)

        let inner = TabsStyle.sidebarWidth - Tokens.Space.s * 2
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Tokens.Space.s,
                               y: height - Tokens.Space.s - CGFloat(index + 1) * TabsStyle.rowHeight,
                               width: inner,
                               height: TabsStyle.rowHeight)
        }
        newButton.frame = NSRect(x: Tokens.Space.m, y: Tokens.Space.s,
                                 width: inner, height: TabsStyle.rowHeight)
    }

    @objc private func newTab() { onNew?() }
}

/// Une ligne d'onglet dans la sidebar : titre, hôte en gris secondaire, fermeture.
@MainActor
private final class TabRow: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let host = NSTextField(labelWithString: "")
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

        host.stringValue = snapshot.host
        // Tronqué en tête, un hôte devient « ...ple.com » — illisible. La fin d'un nom de
        // domaine porte moins d'information que son début.
        host.font = .systemFont(ofSize: 10, weight: .regular)
        host.alignment = .right
        host.lineBreakMode = .byTruncatingTail
        addSubview(host)

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
        host.textColor = Tokens.textSecondary
        close.contentTintColor = Tokens.textSecondary

        let closeWidth: CGFloat = 18
        let hostWidth: CGFloat = 82
        label.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 15) / 2,
                             width: bounds.width - closeWidth - hostWidth - Tokens.Space.l,
                             height: 15)
        host.frame = NSRect(x: bounds.width - closeWidth - hostWidth - Tokens.Space.xs,
                            y: (bounds.height - 13) / 2, width: hostWidth, height: 13)
        close.frame = NSRect(x: bounds.width - closeWidth - Tokens.Space.xs,
                             y: (bounds.height - closeWidth) / 2,
                             width: closeWidth, height: closeWidth)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closeTab() { onClose?() }
}
