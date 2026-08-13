import AppKit

/// La fenêtre de réglages : sidebar de sections à gauche, panneau à droite.
///
/// Même vocabulaire que le navigateur — surface en retrait à gauche, contenu à droite,
/// tout en flat. C'est la seule façon que les deux fenêtres se ressemblent sans qu'on ait
/// à le décréter : elles partagent les mêmes tokens.
@MainActor
final class SettingsWindow: NSWindow {

    private let settings: Settings
    private let sidebar = NSView()
    private let pane = NSView()
    private var sectionButtons: [SectionButton] = []
    private var current: Section = .appearance

    enum Section: String, CaseIterable {
        case general, appearance, privacy, search, websites, advanced

        var title: String {
            switch self {
            case .general:    return "Général"
            case .appearance: return "Apparence"
            case .privacy:    return "Confidentialité"
            case .search:     return "Recherche"
            case .websites:   return "Sites web"
            case .advanced:   return "Avancé"
            }
        }

        var symbol: String {
            switch self {
            case .general:    return "gearshape"
            case .appearance: return "circle.lefthalf.filled"
            case .privacy:    return "hand.raised"
            case .search:     return "magnifyingglass"
            case .websites:   return "globe"
            case .advanced:   return "slider.horizontal.3"
            }
        }
    }

    init(settings: Settings) {
        self.settings = settings
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Réglages"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        center()

        let root = NSView(frame: contentLayoutRect)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true

        sidebar.wantsLayer = true
        root.addSubview(sidebar)

        pane.wantsLayer = true
        root.addSubview(pane)

        for section in Section.allCases {
            let button = SectionButton(section: section)
            button.onClick = { [weak self] in self?.select(section) }
            sidebar.addSubview(button)
            sectionButtons.append(button)
        }

        contentView = root
        layoutSelf()
        select(.appearance)
    }

    override var canBecomeKey: Bool { true }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutSelf()
    }

    private func layoutSelf() {
        guard let root = contentView else { return }
        root.layer?.backgroundColor = Tokens.chromeBackground.cgColor

        let sidebarWidth: CGFloat = 176
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: root.bounds.height)
        sidebar.layer?.backgroundColor = Tokens.sidebarBackground.cgColor

        var y = root.bounds.height - Tokens.Chrome.trafficLights
        for button in sectionButtons {
            y -= Tokens.Chrome.rowHeight
            button.frame = NSRect(x: Tokens.Space.s, y: y,
                                  width: sidebarWidth - Tokens.Space.s * 2,
                                  height: Tokens.Chrome.rowHeight)
        }

        pane.frame = NSRect(x: sidebarWidth, y: 0,
                            width: root.bounds.width - sidebarWidth, height: root.bounds.height)
    }

    // MARK: - Sections

    private func select(_ section: Section) {
        current = section
        sectionButtons.forEach { $0.isSelected = $0.section == section }
        pane.subviews.forEach { $0.removeFromSuperview() }

        let builder = PaneBuilder(width: pane.bounds.width, title: section.title)
        switch section {
        case .general:    buildGeneral(builder)
        case .appearance: buildAppearance(builder)
        case .privacy:    buildPrivacy(builder)
        case .search:     buildSearch(builder)
        case .websites:   buildWebsites(builder)
        case .advanced:   buildAdvanced(builder)
        }
        let content = builder.finish(height: pane.bounds.height)
        pane.addSubview(content)
    }

    private func buildGeneral(_ pane: PaneBuilder) {
        pane.text(title: "Page de démarrage",
                  value: settings.homepage) { [weak self] in self?.settings.homepage = $0 }
    }

    private func buildAppearance(_ pane: PaneBuilder) {
        pane.radios(title: "Thème",
                    options: Settings.Theme.allCases.map(\.label),
                    selected: Settings.Theme.allCases.firstIndex(of: settings.theme) ?? 2) { [weak self] index in
            self?.settings.theme = Settings.Theme.allCases[index]
        }
        pane.toggle(title: "Interface toujours visible",
                    subtitle: "Désactive l'escamotage automatique. Nécessaire pour la navigation au clavier seul et VoiceOver.",
                    isOn: settings.alwaysVisibleUI) { [weak self] in self?.settings.alwaysVisibleUI = $0 }
        pane.slider(title: "Délai d'escamotage",
                    subtitle: "Temps avant que l'interface disparaisse une fois le curseur éloigné.",
                    value: settings.hideDelay, range: 0...2, unit: "s") { [weak self] in
            self?.settings.hideDelay = $0
        }
    }

    private func buildPrivacy(_ pane: PaneBuilder) {
        pane.toggle(title: "Autoriser l'inspection Safari",
                    subtitle: "Ouvre l'inspecteur web d'Apple sur les pages de Wuji. Aucun inspecteur maison n'est prévu.",
                    isOn: settings.safariInspection) { [weak self] in self?.settings.safariInspection = $0 }
        pane.note("Adblock, session privée et anti-pistage arrivent en J3. Rien n'est affiché ici tant que rien ne fonctionne.")
    }

    private func buildSearch(_ pane: PaneBuilder) {
        pane.popup(title: "Moteur de recherche",
                   options: Settings.SearchEngine.allCases.map(\.label),
                   selected: Settings.SearchEngine.allCases.firstIndex(of: settings.searchEngine) ?? 0) { [weak self] index in
            self?.settings.searchEngine = Settings.SearchEngine.allCases[index]
        }
    }

    private func buildWebsites(_ pane: PaneBuilder) {
        pane.slider(title: "Zoom par défaut",
                    subtitle: "Appliqué à toutes les pages.",
                    value: settings.pageZoom, range: 0.5...2, unit: "×") { [weak self] in
            self?.settings.pageZoom = $0
        }
    }

    private func buildAdvanced(_ pane: PaneBuilder) {
        pane.note("Les seuils de révélation, réglables sans recompiler — c'est le sujet de la semaine 2 du spike.")
        pane.toggle(title: "Bord haut et bord gauche", subtitle: "Candidat C. Marche aussi à la souris.",
                    isOn: settings.edgeEnabled) { [weak self] in self?.settings.edgeEnabled = $0 }
        pane.toggle(title: "Overscroll", subtitle: "Candidat A. Sans effet sur une page non défilable.",
                    isOn: settings.overscrollEnabled) { [weak self] in self?.settings.overscrollEnabled = $0 }
        pane.toggle(title: "Trois doigts", subtitle: "Candidat B. En conflit possible avec Mission Control.",
                    isOn: settings.threeFingerEnabled) { [weak self] in self?.settings.threeFingerEnabled = $0 }
        pane.slider(title: "Zone de déclenchement", subtitle: "Distance au bord qui révèle l'interface.",
                    value: settings.revealZone, range: 2...24, unit: "pt") { [weak self] in
            self?.settings.revealZone = $0
        }
        pane.slider(title: "Zone de maintien",
                    subtitle: "Plus large que la zone de déclenchement : c'est l'hystérésis qui empêche le clignotement.",
                    value: settings.keepZone, range: 40...240, unit: "pt") { [weak self] in
            self?.settings.keepZone = $0
        }
    }
}

// MARK: - Construction du panneau

/// Empile les rangées de haut en bas. Chaque rangée : titre à gauche, contrôle à droite,
/// sous-titre sous le titre — la structure de la maquette.
@MainActor
private final class PaneBuilder {

    private let container = NSView()
    private let width: CGFloat
    private var cursor: CGFloat = 0

    init(width: CGFloat, title: String) {
        self.width = width
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Tokens.textPrimary
        header.frame = NSRect(x: Tokens.Space.xl, y: 0, width: width - Tokens.Space.xl * 2, height: 20)
        container.addSubview(header)
        cursor = 20 + Tokens.Space.xl
    }

    func finish(height: CGFloat) -> NSView {
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Empilé depuis le haut : on retourne les positions une fois la hauteur connue.
        let top = height - Tokens.Chrome.trafficLights
        for view in container.subviews {
            view.frame.origin.y = top - view.frame.origin.y - view.frame.height
        }
        return container
    }

    // MARK: Rangées

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = Tokens.textSecondary
        label.frame = NSRect(x: Tokens.Space.xl, y: cursor, width: width - Tokens.Space.xl * 2, height: 32)
        container.addSubview(label)
        cursor += 32 + Tokens.Space.m
    }

    func toggle(title: String, subtitle: String?, isOn: Bool, action: @escaping (Bool) -> Void) {
        let height = row(title: title, subtitle: subtitle)
        let control = NSSwitch()
        control.state = isOn ? .on : .off
        control.frame = NSRect(x: width - Tokens.Space.xl - 40, y: cursor, width: 40, height: 22)
        Handler.attach(to: control) { action(control.state == .on) }
        container.addSubview(control)
        cursor += height
    }

    func slider(title: String, subtitle: String?, value: CGFloat, range: ClosedRange<Double>,
                unit: String, action: @escaping (CGFloat) -> Void) {
        let height = row(title: title, subtitle: subtitle)
        let readout = NSTextField(labelWithString: "")
        readout.font = .systemFont(ofSize: 11, weight: .regular)
        readout.alignment = .right
        readout.textColor = Tokens.textSecondary
        readout.frame = NSRect(x: width - Tokens.Space.xl - 44, y: cursor + 2, width: 44, height: 14)
        readout.stringValue = String(format: "%.2f %@", value, unit)
        container.addSubview(readout)

        let control = NSSlider(value: Double(value), minValue: range.lowerBound,
                               maxValue: range.upperBound, target: nil, action: nil)
        control.isContinuous = true
        control.frame = NSRect(x: width - Tokens.Space.xl - 180, y: cursor + 18, width: 180, height: 20)
        Handler.attach(to: control) {
            readout.stringValue = String(format: "%.2f %@", control.doubleValue, unit)
            action(CGFloat(control.doubleValue))
        }
        container.addSubview(control)
        cursor += height
    }

    func popup(title: String, options: [String], selected: Int, action: @escaping (Int) -> Void) {
        let height = row(title: title, subtitle: nil)
        let control = NSPopUpButton(frame: NSRect(x: width - Tokens.Space.xl - 160, y: cursor,
                                                  width: 160, height: 24))
        control.addItems(withTitles: options)
        control.selectItem(at: selected)
        Handler.attach(to: control) { action(control.indexOfSelectedItem) }
        container.addSubview(control)
        cursor += height
    }

    func radios(title: String, options: [String], selected: Int, action: @escaping (Int) -> Void) {
        let height = row(title: title, subtitle: nil)
        var x = width - Tokens.Space.xl - CGFloat(options.count) * 92
        var buttons: [NSButton] = []
        for (index, option) in options.enumerated() {
            let button = NSButton(radioButtonWithTitle: option, target: nil, action: nil)
            button.frame = NSRect(x: x, y: cursor, width: 88, height: 20)
            button.state = index == selected ? .on : .off
            Handler.attach(to: button) {
                buttons.forEach { $0.state = $0 === button ? .on : .off }
                action(index)
            }
            container.addSubview(button)
            buttons.append(button)
            x += 92
        }
        cursor += height
    }

    func text(title: String, value: String, action: @escaping (String) -> Void) {
        let height = row(title: title, subtitle: nil)
        let field = NSTextField(string: value)
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: width - Tokens.Space.xl - 260, y: cursor, width: 260, height: 22)
        Handler.attach(to: field) { action(field.stringValue) }
        container.addSubview(field)
        cursor += height
    }

    /// Titre + sous-titre. Renvoie la hauteur consommée par la rangée.
    private func row(title: String, subtitle: String?) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = Tokens.textPrimary
        label.frame = NSRect(x: Tokens.Space.xl, y: cursor, width: width * 0.5, height: 18)
        container.addSubview(label)

        guard let subtitle else { return 18 + Tokens.Space.xl }

        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = Tokens.textSecondary
        detail.frame = NSRect(x: Tokens.Space.xl, y: cursor + 20, width: width * 0.52, height: 28)
        container.addSubview(detail)
        return 18 + 28 + Tokens.Space.xl
    }
}

/// Petit relais cible/action, pour garder les fermetures près de la déclaration du contrôle.
@MainActor
private final class Handler: NSObject {
    private static var retained: [Handler] = []
    private let block: () -> Void

    private init(block: @escaping () -> Void) { self.block = block }

    static func attach(to control: NSControl, block: @escaping () -> Void) {
        let handler = Handler(block: block)
        retained.append(handler)
        control.target = handler
        control.action = #selector(fire)
    }

    @objc private func fire() { block() }
}

/// Une section dans la sidebar des réglages.
@MainActor
private final class SectionButton: NSView {

    let section: SettingsWindow.Section
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsLayout = true } }

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(section: SettingsWindow.Section) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.pill - 4
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
        label.stringValue = section.title
        label.font = .systemFont(ofSize: 13, weight: .regular)
        [glyph, label].forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.backgroundColor = isSelected ? Tokens.rowSelected.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = Tokens.chromeHairline.cgColor
        glyph.contentTintColor = isSelected ? Tokens.textPrimary : Tokens.textSecondary
        label.textColor = isSelected ? Tokens.textPrimary : Tokens.textSecondary

        glyph.frame = NSRect(x: Tokens.Space.s, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: Tokens.Space.s + 14 + Tokens.Space.s, y: (bounds.height - 16) / 2,
                             width: bounds.width - 40, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
