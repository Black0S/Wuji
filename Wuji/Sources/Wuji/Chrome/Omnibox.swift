import AppKit

/// Ce que l'omnibox peut proposer. L'ordre du tableau est l'ordre affiché, et il compte :
/// **les onglets ouverts passent avant tout le reste.**
enum OmniboxResult {
    case tab(index: Int, title: String, subtitle: String, icon: NSImage?)
    case url(URL)
    case search(String)

    var title: String {
        switch self {
        case .tab(_, let title, _, _): return title
        case .url(let url):            return url.absoluteString
        case .search(let query):       return query
        }
    }

    var subtitle: String {
        switch self {
        case .tab(_, _, let subtitle, _): return subtitle
        case .url:                        return "Ouvrir l'adresse"
        case .search:                     return "Rechercher"
        }
    }

    /// La favicon du site quand on l'a. Sinon un glyphe monochrome : le type se lit à la
    /// forme, jamais à une couleur (spec §4.6).
    var icon: NSImage? {
        switch self {
        case .tab(_, _, _, let icon): return icon
        default:                      return nil
        }
    }

    var fallbackGlyph: String {
        switch self {
        case .tab:    return "square.on.square"
        case .url:    return "arrow.up.right"
        case .search: return "magnifyingglass"
        }
    }

    var isTab: Bool {
        if case .tab = self { return true }
        return false
    }
}

@MainActor
protocol OmniboxDelegate: AnyObject {
    func omnibox(_ omnibox: Omnibox, resultsFor query: String) -> [OmniboxResult]
    func omnibox(_ omnibox: Omnibox, didActivate result: OmniboxResult)
    func omniboxDidDismiss(_ omnibox: Omnibox)
}

/// La palette. Point d'entrée principal du navigateur : adresse, recherche, et surtout
/// les onglets déjà ouverts, qui doivent se retrouver plus vite au clavier qu'à la souris.
@MainActor
final class Omnibox: ThemedView, NSTextFieldDelegate {

    weak var delegate: OmniboxDelegate?

    private let card = NSView()
    private let field = NSTextField()
    private let separator = NSView()
    private let rowsContainer = NSView()

    /// Ce qui est affiché : des en-têtes de groupe et des résultats. La sélection ne
    /// circule que sur les résultats — un en-tête n'est pas activable.
    private enum Entry {
        case header(String)
        case result(Int)
    }

    private var results: [OmniboxResult] = []
    private var entries: [Entry] = []
    private var rows: [Int: OmniboxRow] = [:]
    private var headers: [NSTextField] = []
    private var selection = 0

    private static let cardWidth: CGFloat = 560
    private static let fieldHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 40
    private static let headerHeight: CGFloat = 26
    private static let maxResults = 8

    /// Le champ est pré-rempli avec l'URL courante — pratique pour l'éditer, désastreux
    /// pour les résultats : filtrer sur cette URL masque tous les onglets ouverts, donc
    /// exactement ce qu'on vient chercher. Tant que rien n'est tapé, la requête est
    /// considérée comme vide.
    private var isSeeded = false

    var isOpen: Bool { !isHidden }

    nonisolated(unsafe) private var escapeMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        build()

        // `cancelOperation:` n'arrive pas jusqu'au délégué depuis l'éditeur de champ :
        // l'éditeur l'absorbe pour restaurer la valeur précédente. On intercepte donc
        // la touche en amont — ce qui ferme aussi la palette quand le focus n'est plus
        // dans le champ.
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
        applyColors()

        // Marge identique en haut et en bas de la liste. Auparavant elle n'existait qu'en
        // bas : la première ligne venait toucher le séparateur, et le déséquilibre se
        // voyait d'autant plus qu'il n'y avait qu'un seul résultat.
        let listPadding = Tokens.Space.s
        let contentHeight = entries.reduce(0) { total, entry in
            switch entry {
            case .header: return total + Self.headerHeight
            case .result: return total + Self.rowHeight
            }
        }
        let listHeight = entries.isEmpty ? 0 : contentHeight + listPadding * 2
        let cardHeight = Self.fieldHeight + listHeight

        // La palette vit dans la zone de contenu : ses coordonnées commencent déjà après
        // la sidebar et sous la barre du haut. Elle ne peut donc jamais les recouvrir.
        let cardTop = bounds.height - Tokens.Space.l
        card.frame = NSRect(x: (bounds.width - Self.cardWidth) / 2,
                            y: cardTop - cardHeight,
                            width: Self.cardWidth,
                            height: cardHeight)

        field.frame = NSRect(x: Tokens.Space.l,
                             y: cardHeight - Self.fieldHeight + (Self.fieldHeight - 24) / 2,
                             width: Self.cardWidth - Tokens.Space.l * 2,
                             height: 24)

        // Le séparateur marque la frontière entre le champ et la liste : tout en haut de
        // la zone de liste, et la marge vient après lui.
        separator.isHidden = entries.isEmpty
        separator.frame = NSRect(x: 0, y: listHeight - 1, width: Self.cardWidth, height: 1)

        rowsContainer.frame = NSRect(x: 0, y: 0, width: Self.cardWidth, height: listHeight)

        var cursor = listHeight - listPadding
        var headerIndex = 0
        for entry in entries {
            switch entry {
            case .header:
                cursor -= Self.headerHeight
                if headers.indices.contains(headerIndex) {
                    headers[headerIndex].frame = NSRect(x: Tokens.Space.l + Tokens.Space.xs,
                                                        y: cursor + 6,
                                                        width: Self.cardWidth - Tokens.Space.l * 2,
                                                        height: 14)
                }
                headerIndex += 1
            case .result(let index):
                cursor -= Self.rowHeight
                rows[index]?.frame = NSRect(x: Tokens.Space.s, y: cursor,
                                            width: Self.cardWidth - Tokens.Space.s * 2,
                                            height: Self.rowHeight)
            }
        }
    }

    private func applyColors() {
        card.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        card.layer?.borderColor = Tokens.chromeHairline.cgColor
        separator.layer?.backgroundColor = Tokens.separator.cgColor
        field.textColor = Tokens.textPrimary
        headers.forEach { $0.textColor = Tokens.textSecondary }
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
        entries = []
        window?.makeFirstResponder(nil)
        delegate?.omniboxDidDismiss(self)
    }

    // MARK: - Résultats

    private func refresh() {
        let query = isSeeded ? "" : field.stringValue
        results = Array((delegate?.omnibox(self, resultsFor: query) ?? []).prefix(Self.maxResults))
        selection = 0
        rebuild()
        needsLayout = true
    }

    private func rebuild() {
        rows.values.forEach { $0.removeFromSuperview() }
        rows = [:]
        headers.forEach { $0.removeFromSuperview() }
        headers = []
        entries = []

        // Deux groupes seulement : ce qui est déjà ouvert, et ce qui ne l'est pas. Au-delà,
        // les titres coûteraient plus de lecture qu'ils n'en font gagner.
        let tabs = results.indices.filter { results[$0].isTab }
        let others = results.indices.filter { !results[$0].isTab }

        if !tabs.isEmpty {
            appendHeader("Onglets ouverts")
            tabs.forEach { appendRow(at: $0) }
        }
        if !others.isEmpty {
            if !tabs.isEmpty { appendHeader("Suggestions") }
            others.forEach { appendRow(at: $0) }
        }
        updateSelection()
    }

    private func appendHeader(_ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Tokens.textSecondary
        rowsContainer.addSubview(label)
        headers.append(label)
        entries.append(.header(title))
    }

    private func appendRow(at index: Int) {
        let row = OmniboxRow(result: results[index])
        row.onClick = { [weak self] in self?.activate(index: index) }
        // Le survol déplace la sélection : sans ça, la souris met en évidence une ligne
        // pendant que `↵` en active une autre.
        row.onHover = { [weak self] in
            guard let self, self.selection != index else { return }
            self.selection = index
            self.updateSelection()
        }
        rowsContainer.addSubview(row)
        rows[index] = row
        entries.append(.result(index))
    }

    private func updateSelection() {
        for (index, row) in rows { row.isSelected = index == selection }
    }

    private func move(by delta: Int) {
        let order = entries.compactMap { entry -> Int? in
            if case .result(let index) = entry { return index }
            return nil
        }
        guard let current = order.firstIndex(of: selection), !order.isEmpty else { return }
        selection = order[(current + delta + order.count) % order.count]
        updateSelection()
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

/// Une ligne de résultat : favicon ou glyphe, titre, hôte, et le rappel `↵` sur la ligne
/// active — l'indice qui dit quoi faire sans avoir à l'expliquer.
@MainActor
private final class OmniboxRow: ThemedView {

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    var isSelected = false {
        didSet { needsLayout = true }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "↵")
    private var trackingArea: NSTrackingArea?

    init(result: OmniboxResult) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 2
        layer?.cornerCurve = .continuous

        if let favicon = result.icon {
            icon.image = favicon
        } else {
            icon.image = NSImage(systemSymbolName: result.fallbackGlyph, accessibilityDescription: nil)
            icon.contentTintColor = Tokens.textSecondary
        }
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        title.stringValue = result.title
        title.font = .systemFont(ofSize: 13, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        subtitle.stringValue = result.subtitle
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.alignment = .right
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(subtitle)

        hint.font = .systemFont(ofSize: 12, weight: .regular)
        hint.alignment = .center
        addSubview(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor
        // Le titre passe en medium quand la ligne est active : en monochrome, la graisse
        // est le second levier après la valeur de fond.
        title.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        title.textColor = Tokens.textPrimary
        subtitle.textColor = Tokens.textSecondary
        hint.textColor = Tokens.textSecondary
        hint.isHidden = !isSelected

        let iconSize: CGFloat = 16
        icon.frame = NSRect(x: Tokens.Space.m, y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)

        let hintWidth: CGFloat = isSelected ? 20 : 0
        hint.frame = NSRect(x: bounds.width - Tokens.Space.m - 20,
                            y: (bounds.height - 16) / 2, width: 20, height: 16)

        let left = Tokens.Space.m + iconSize + Tokens.Space.m
        let subtitleWidth = min(200, bounds.width * 0.35)
        subtitle.frame = NSRect(x: bounds.width - Tokens.Space.m - hintWidth - subtitleWidth,
                                y: (bounds.height - 16) / 2,
                                width: subtitleWidth, height: 16)
        title.frame = NSRect(x: left, y: (bounds.height - 18) / 2,
                             width: max(0, subtitle.frame.minX - left - Tokens.Space.s),
                             height: 18)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
