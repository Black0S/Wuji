import AppKit

/// La fenêtre qui montre ce que le blocage fait.
///
/// **Une fenêtre, et pas un compteur dans la barre.** Un chiffre qui monte ne se vérifie
/// pas : il rassure sans rien prouver, et il pousse à gonfler ce qu'on compte pour que le
/// nombre soit joli. Une trace se lit — on voit ce qui est arrêté, sur quel site, et on
/// peut être en désaccord avec ce qu'on lit.
///
/// Elle ne s'ouvre que sur demande, et **rien n'est mesuré tant qu'elle n'a pas servi** au
/// sens où le journal est borné et vit en mémoire : fermer Wuji l'efface.
@MainActor
final class BlockLogWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let log: BlockingLog
    private var window: NSWindow?
    private var table: NSTableView?
    private var subtitle: NSTextField?
    private var note: NSTextField?
    /// Le rafraîchissement est différé d'un tour de boucle : une page qui rate quarante
    /// ressources d'affilée ne doit pas recharger la table quarante fois.
    private var refreshScheduled = false

    init(log: BlockingLog) {
        self.log = log
        super.init()
    }

    // MARK: - Ouverture

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Journal de blocage"
        // Le titre est dans la fenêtre, pas dans sa barre : l'écrire deux fois à dix
        // points d'écart le fait lire comme une erreur d'affichage.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Tokens.sidebarBackground
        window.minSize = NSSize(width: 420, height: 300)
        window.delegate = self
        window.center()
        window.contentView = makeContent()
        window.isReleasedWhenClosed = false
        self.window = window

        log.onChange = { [weak self] in self?.scheduleRefresh() }
        refresh()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// La largeur de repli suit la fenêtre : figée, elle laisserait une bande vide à droite
    /// dès qu'on agrandit.
    func windowDidResize(_ notification: Notification) {
        guard let width = window?.contentView?.bounds.width else { return }
        note?.preferredMaxLayoutWidth = width - 40
    }

    func windowWillClose(_ notification: Notification) {
        // On lâche tout : la fenêtre fermée ne doit plus rien coûter, pas même un appel
        // par entrée journalisée.
        log.onChange = nil
        window = nil
        table = nil
        subtitle = nil
        note = nil
    }

    /// Le journal est-il regardé ? Sert à ne poser les mesures sur les pages que si
    /// quelqu'un les lit.
    var isOpen: Bool { window != nil }

    // MARK: - Contenu

    private func makeContent() -> NSView {
        let root = Fill(color: Tokens.sidebarBackground)

        let title = label("Journal de blocage", size: 15, weight: .semibold, color: Tokens.textPrimary)
        let subtitle = label("", size: 11, weight: .regular, color: Tokens.textSecondary)
        self.subtitle = subtitle

        let clear = NSButton(title: "Effacer", target: self, action: #selector(clear))
        clear.bezelStyle = .accessoryBarAction
        clear.controlSize = .small
        clear.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // La réserve est dite en clair, dans la fenêtre, et pas dans une note de bas de
        // page qu'on n'ouvre jamais : une ressource peut manquer parce qu'on l'a refusée,
        // ou parce que le site l'a perdue. Wuji ne sait pas trancher, alors il ne tranche pas.
        let note = label("""
            Wuji note ce qu'il observe : une page refusée par une règle, un élément masqué, \
            un scriptlet posé, une ressource qui n'est jamais venue. WebKit ne dit pas ce \
            qu'il bloque — une ressource absente peut aussi être une panne du site.
            """, size: 11, weight: .regular, color: Tokens.textSecondary)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 4
        // Sans largeur de référence, un champ qui se replie annonce quand même la largeur
        // d'une seule ligne — et AppKit étire la fenêtre jusqu'à la lui donner. La fenêtre
        // sortait de l'écran par la droite à cause de cette seule phrase.
        note.preferredMaxLayoutWidth = 580
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.note = note

        let separator = Fill(color: Tokens.separator)
        separator.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, subtitle, clear, scroll, note, separator] { root.addSubview(view) }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),

            clear.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            clear.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -12),

            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        return root
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    // MARK: - Rafraîchissement

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        let count = log.entries.count
        subtitle?.stringValue = count == 0
            ? "Rien pour l'instant · cette session"
            : "\(count) évènement\(count > 1 ? "s" : "") · cette session"
        table?.reloadData()
    }

    @objc private func clear() {
        log.clear()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { log.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard log.entries.indices.contains(row) else { return nil }
        let entry = log.entries[row]
        let view = (tableView.makeView(withIdentifier: Row.identifier, owner: self) as? Row) ?? Row()
        view.identifier = Row.identifier
        view.show(entry)
        return view
    }

    /// Une surface d'une seule couleur, qui suit le thème. Dessinée plutôt que posée dans
    /// un calque : un `CGColor` dynamique se fige à l'affectation et reste au thème d'alors.
    private final class Fill: ThemedView {
        private let color: NSColor
        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            dirtyRect.fill()
        }
    }

    /// Une ligne de trace : l'heure, la nature, ce dont il s'agit, et où.
    private final class Row: NSView {
        static let identifier = NSUserInterfaceItemIdentifier("row")

        private let time = NSTextField(labelWithString: "")
        private let kind = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let host = NSTextField(labelWithString: "")

        private static let clock: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        init() {
            super.init(frame: .zero)
            // Une chasse fixe pour l'heure : sans elle, les secondes dansent d'une ligne à
            // l'autre et la colonne cesse d'être une colonne.
            time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            time.textColor = Tokens.textSecondary
            kind.font = .systemFont(ofSize: 10, weight: .medium)
            detail.font = .systemFont(ofSize: 12, weight: .regular)
            detail.textColor = Tokens.textPrimary
            detail.lineBreakMode = .byTruncatingMiddle
            host.font = .systemFont(ofSize: 11, weight: .regular)
            host.textColor = Tokens.textSecondary
            host.lineBreakMode = .byTruncatingHead
            host.alignment = .right

            for field in [time, kind, detail, host] {
                field.translatesAutoresizingMaskIntoConstraints = false
                addSubview(field)
            }
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            host.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

            NSLayoutConstraint.activate([
                time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                time.centerYAnchor.constraint(equalTo: centerYAnchor),
                kind.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 12),
                kind.widthAnchor.constraint(equalToConstant: 62),
                kind.centerYAnchor.constraint(equalTo: centerYAnchor),
                detail.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: 8),
                detail.centerYAnchor.constraint(equalTo: centerYAnchor),
                host.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
                host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                host.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) { nil }

        func show(_ entry: BlockingLog.Entry) {
            time.stringValue = Self.clock.string(from: entry.date)
            kind.stringValue = entry.kind.label
            // La nature se lit à la valeur, pas à la couleur : « bloqué » est le seul cas
            // où Wuji a franchement refusé quelque chose, et il est le seul en appuyé.
            kind.textColor = entry.kind == .blocked ? Tokens.textPrimary : Tokens.textSecondary
            detail.stringValue = entry.detail
            host.stringValue = entry.host
        }

        override func draw(_ dirtyRect: NSRect) {
            Tokens.separator.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }
}
