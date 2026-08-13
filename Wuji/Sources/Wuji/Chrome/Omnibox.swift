import AppKit

/// Ce que l'omnibox peut proposer. L'ordre du tableau est l'ordre affiché, et il compte :
/// **les onglets ouverts passent avant tout le reste**, parce que la thèse à éprouver est
/// que l'omnibox remplace la barre d'onglets.
enum OmniboxResult {
    case tab(index: Int, title: String, subtitle: String)
    case url(URL)
    case search(String)

    var title: String {
        switch self {
        case .tab(_, let title, _):  return title
        case .url(let url):          return url.absoluteString
        case .search(let query):     return query
        }
    }

    var subtitle: String {
        switch self {
        case .tab(_, _, let subtitle): return subtitle
        case .url:                     return "Ouvrir l'adresse"
        case .search:                  return "Rechercher avec DuckDuckGo"
        }
    }

    /// Monochrome : le type se lit à la forme du glyphe, jamais à une couleur (spec §4.6).
    var glyph: String {
        switch self {
        case .tab:    return "macwindow"
        case .url:    return "arrow.up.right"
        case .search: return "magnifyingglass"
        }
    }
}

@MainActor
protocol OmniboxDelegate: AnyObject {
    func omnibox(_ omnibox: Omnibox, resultsFor query: String) -> [OmniboxResult]
    func omnibox(_ omnibox: Omnibox, didActivate result: OmniboxResult)
    func omniboxDidDismiss(_ omnibox: Omnibox)
}

/// La palette modale. Point d'entrée unique quand l'interface est masquée — donc la seule
/// vue du prototype qui a le droit d'être soignée : tout le reste est jetable, celle-ci est
/// la maquette exécutable de ce que J2 doit livrer.
@MainActor
final class Omnibox: NSView, NSTextFieldDelegate {

    weak var delegate: OmniboxDelegate?

    private let card = NSView()
    private let field = NSTextField()
    private let separator = NSView()
    private let rowsContainer = NSView()

    private var results: [OmniboxResult] = []
    private var rows: [OmniboxRow] = []
    private var selection = 0

    /// Le champ est pré-rempli avec l'URL courante — pratique pour l'éditer, désastreux
    /// pour les résultats : filtrer sur cette URL masque tous les onglets ouverts, donc
    /// exactement ce qu'on vient chercher à `⌘L`.
    ///
    /// Tant que rien n'a été tapé, la requête est considérée comme vide : on voit ses
    /// onglets. À la première frappe, le texte pré-rempli est remplacé et le filtre prend.
    private var isSeeded = false

    private static let cardWidth: CGFloat = 560
    private static let fieldHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 40
    private static let maxRows = 6

    var isOpen: Bool { !isHidden }

    nonisolated(unsafe) private var escapeMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        build()

        // `cancelOperation:` n'arrive pas jusqu'au délégué depuis l'éditeur de champ :
        // l'éditeur l'absorbe pour restaurer la valeur précédente. On intercepte donc
        // la touche en amont — ce qui a l'avantage de fermer la palette même quand le
        // focus n'est plus dans le champ.
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

    /// Cliquer à côté de la palette la referme — et le clic ne doit pas atteindre la page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(local) { dismiss() }
    }

    private func build() {
        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.card
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = false
        Tokens.applyChromeShadow(to: card)
        addSubview(card)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17, weight: .regular)
        field.placeholderString = "Rechercher ou saisir une adresse"
        field.delegate = self
        card.addSubview(field)

        separator.wantsLayer = true
        card.addSubview(separator)

        rowsContainer.wantsLayer = true
        card.addSubview(rowsContainer)

        applyColors()
    }

    override func layout() {
        super.layout()
        let visibleRows = min(results.count, Self.maxRows)
        let listHeight = visibleRows == 0 ? 0 : CGFloat(visibleRows) * Self.rowHeight + Tokens.Space.s
        let cardHeight = Self.fieldHeight + listHeight

        // La palette vit dans la zone de contenu : ses coordonnées commencent déjà après
        // la sidebar et sous la barre du haut. Elle ne peut donc jamais les recouvrir —
        // on ne perd pas de vue ce qu'on est en train de quitter.
        let cardTop = bounds.height - Tokens.Space.l
        card.frame = NSRect(
            x: (bounds.width - Self.cardWidth) / 2,
            y: cardTop - cardHeight,
            width: Self.cardWidth,
            height: cardHeight
        )

        field.frame = NSRect(x: Tokens.Space.l,
                             y: cardHeight - Self.fieldHeight + (Self.fieldHeight - 24) / 2,
                             width: Self.cardWidth - Tokens.Space.l * 2,
                             height: 24)

        separator.isHidden = visibleRows == 0
        separator.frame = NSRect(x: 0, y: listHeight - Tokens.Space.xs,
                                 width: Self.cardWidth, height: 1)

        rowsContainer.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: listHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Tokens.Space.s,
                               y: listHeight - Tokens.Space.xs - CGFloat(index + 1) * Self.rowHeight,
                               width: Self.cardWidth - Tokens.Space.s * 2,
                               height: Self.rowHeight)
        }
    }

    override func updateLayer() {
        applyColors()
    }

    private func applyColors() {
        card.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        card.layer?.borderColor = Tokens.chromeHairline.cgColor
        separator.layer?.backgroundColor = Tokens.separator.cgColor
        field.textColor = Tokens.textPrimary
    }

    // MARK: - Ouverture / fermeture

    func present(in window: NSWindow?, seed: String) {
        isHidden = false
        isSeeded = !seed.isEmpty
        field.stringValue = seed
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        refresh()
    }

    func dismiss() {
        guard isOpen else { return }
        isHidden = true
        field.stringValue = ""
        results = []
        window?.makeFirstResponder(nil)
        delegate?.omniboxDidDismiss(self)
    }

    // MARK: - Résultats

    private func refresh() {
        let query = isSeeded ? "" : field.stringValue
        results = delegate?.omnibox(self, resultsFor: query) ?? []
        selection = 0
        rebuildRows()
        needsLayout = true
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = results.prefix(Self.maxRows).enumerated().map { index, result in
            let row = OmniboxRow(result: result)
            row.isSelected = index == selection
            row.onClick = { [weak self] in self?.activate(index: index) }
            rowsContainer.addSubview(row)
            return row
        }
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
        for (index, row) in rows.enumerated() { row.isSelected = index == selection }
    }

    private func activate(index: Int) {
        guard results.indices.contains(index) else { return }
        let result = results[index]
        dismiss()
        delegate?.omnibox(self, didActivate: result)
    }

    // MARK: - Clavier

    func controlTextDidChange(_ notification: Notification) {
        isSeeded = false
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):     move(by: 1);  return true
        case #selector(NSResponder.moveUp(_:)):       move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            // Rien tapé : ↵ ne doit pas basculer sur le premier onglet de la liste par
            // surprise. On referme, c'est le seul comportement non ambigu.
            if isSeeded { dismiss() } else { activate(index: selection) }
            return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
}

/// Une ligne de résultat. Hauteur 40, glyphe, titre, sous-titre en gris secondaire.
@MainActor
private final class OmniboxRow: NSView {

    var onClick: (() -> Void)?

    var isSelected = false {
        didSet { needsDisplay = true; needsLayout = true }
    }

    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(result: OmniboxResult) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 2
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(systemSymbolName: result.glyph, accessibilityDescription: nil)
        glyph.contentTintColor = Tokens.textSecondary
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)

        title.stringValue = result.title
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = Tokens.textPrimary
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        subtitle.stringValue = result.subtitle
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = Tokens.textSecondary
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.alignment = .right
        addSubview(subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor

        let glyphSize: CGFloat = 16
        glyph.frame = NSRect(x: Tokens.Space.m, y: (bounds.height - glyphSize) / 2,
                             width: glyphSize, height: glyphSize)

        let textLeft = Tokens.Space.m + glyphSize + Tokens.Space.m
        let subtitleWidth = min(220, bounds.width * 0.4)
        title.frame = NSRect(x: textLeft, y: (bounds.height - 18) / 2,
                             width: bounds.width - textLeft - subtitleWidth - Tokens.Space.l,
                             height: 18)
        subtitle.frame = NSRect(x: bounds.width - subtitleWidth - Tokens.Space.m,
                                y: (bounds.height - 16) / 2,
                                width: subtitleWidth, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
