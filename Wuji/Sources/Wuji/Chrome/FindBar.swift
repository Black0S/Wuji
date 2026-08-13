import AppKit

@MainActor
protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, didChange query: String)
    func findBarDidRequestNext(_ bar: FindBar)
    func findBarDidRequestPrevious(_ bar: FindBar)
    func findBarDidClose(_ bar: FindBar)
}

/// La barre de recherche dans la page, en pilule flottante au-dessus du contenu.
///
/// Elle vit dans la zone de contenu, donc elle ne peut jamais recouvrir la sidebar ni la
/// barre du haut — on ne perd pas de vue où l'on est.
@MainActor
final class FindBar: ThemedView, NSTextFieldDelegate {

    weak var delegate: FindBarDelegate?

    private let pill = NSView()
    private let field = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let close = NSButton()

    private static let pillWidth: CGFloat = 380
    private static let pillHeight: CGFloat = 40

    var isOpen: Bool { !isHidden }

    nonisolated(unsafe) private var escapeMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        build()

        // Même raison que dans la palette : l'éditeur de champ absorbe `cancelOperation:`
        // pour restaurer la valeur précédente, la touche n'arrive jamais au délégué.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                self.dismiss()
                return true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Seule la pilule intercepte les clics : la page reste utilisable pendant la recherche.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        let local = convert(point, from: superview)
        return pill.frame.contains(local) ? super.hitTest(point) : nil
    }

    private func build() {
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Tokens.Radius.pill
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: pill)
        addSubview(pill)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.placeholderString = "Rechercher dans la page"
        field.delegate = self
        pill.addSubview(field)

        counter.font = .systemFont(ofSize: 12, weight: .regular)
        counter.alignment = .right
        pill.addSubview(counter)

        configure(previous, symbol: "chevron.up", label: "Résultat précédent")
        configure(next, symbol: "chevron.down", label: "Résultat suivant")
        configure(close, symbol: "xmark", label: "Fermer la recherche")
    }

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(buttonAction(_:))
        pill.addSubview(button)
    }

    override func layout() {
        super.layout()
        pill.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        pill.layer?.borderColor = Tokens.chromeHairline.cgColor
        field.textColor = Tokens.textPrimary
        counter.textColor = Tokens.textSecondary
        [previous, next, close].forEach { $0.contentTintColor = Tokens.textSecondary }

        pill.frame = NSRect(x: bounds.width - Self.pillWidth - Tokens.Space.l,
                            y: bounds.height - Self.pillHeight - Tokens.Space.m,
                            width: Self.pillWidth, height: Self.pillHeight)

        let size: CGFloat = 24
        let y = (Self.pillHeight - size) / 2
        var x = Self.pillWidth - Tokens.Space.s - size
        close.frame = NSRect(x: x, y: y, width: size, height: size)
        x -= size
        next.frame = NSRect(x: x, y: y, width: size, height: size)
        x -= size
        previous.frame = NSRect(x: x, y: y, width: size, height: size)

        let counterWidth: CGFloat = 56
        x -= counterWidth + Tokens.Space.xs
        counter.frame = NSRect(x: x, y: (Self.pillHeight - 16) / 2, width: counterWidth, height: 16)

        field.frame = NSRect(x: Tokens.Space.m, y: (Self.pillHeight - 18) / 2,
                             width: x - Tokens.Space.m - Tokens.Space.s, height: 18)
    }

    // MARK: - Ouverture / fermeture

    func present(in window: NSWindow?) {
        isHidden = false
        // Une vue masquée ne reçoit pas de passe de mise en page : sans ça, le champ a
        // encore un cadre vide au moment où on lui donne le focus, et il le refuse.
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss() {
        guard isOpen else { return }
        isHidden = true
        field.stringValue = ""
        counter.stringValue = ""
        window?.makeFirstResponder(nil)
        delegate?.findBarDidClose(self)
    }

    var query: String { field.stringValue }

    /// `total` à `nil` tant qu'on ne sait pas encore compter.
    func show(position: Int, total: Int?) {
        guard !field.stringValue.isEmpty else {
            counter.stringValue = ""
            return
        }
        guard let total, total > 0 else {
            counter.stringValue = "aucun"
            return
        }
        counter.stringValue = "\(position)/\(total)"
    }

    // MARK: - Actions

    @objc private func buttonAction(_ sender: NSButton) {
        switch sender {
        case previous: delegate?.findBarDidRequestPrevious(self)
        case next:     delegate?.findBarDidRequestNext(self)
        case close:    dismiss()
        default:       break
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        delegate?.findBar(self, didChange: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.findBarDidRequestNext(self)
            return true
        case #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.moveUp(_:)):
            delegate?.findBarDidRequestPrevious(self)
            return true
        case #selector(NSResponder.moveDown(_:)):
            delegate?.findBarDidRequestNext(self)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}
