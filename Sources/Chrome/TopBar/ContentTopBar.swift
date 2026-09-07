import AppKit

@MainActor
protocol ContentTopBarDelegate: AnyObject {
    func topBarDidRequestOmnibox(_ bar: ContentTopBar)
    func topBar(_ bar: ContentTopBar, didTrigger action: ContentTopBar.Action)
}

/// La barre du haut, au-dessus du **contenu seulement** — elle commence après la sidebar.
///
/// L'adresse n'est pas éditable : cliquer dessus ouvre la palette. Deux surfaces d'édition
/// pour la même chose, c'est le doublon que le principe 5 interdit.
@MainActor
final class ContentTopBar: ThemedView {

    enum Action { case back, forward, menu, blocking, scripts, security, zoomReset, reader }

    weak var delegate: ContentTopBarDelegate?

    private let back = NSButton()
    private let forward = NSButton()
    private let more = NSButton()
    private let shield = NSButton()
    private let braces = NSButton()
    /// Le niveau de zoom, quand il n'est pas à cent pour cent.
    ///
    /// **Une bulle passait, et c'était tout.** Elle disait ce qui venait de changer, pas
    /// dans quel état on est : deux jours plus tard, un site qui se lit trop gros ne
    /// s'explique plus. L'écart mérite d'être visible tant qu'il dure — et de disparaître
    /// dès qu'il cesse, parce qu'un badge à cent pour cent ne dirait rien.
    private let zoomBadge = NSButton()
    /// Le mode lecture, **dans le champ et à droite** — en miroir du cadenas.
    ///
    /// Sa place était déjà réservée : pour que l'adresse reste centrée quel que soit
    /// l'affichage du cadenas, le champ garde de part et d'autre la largeur d'un glyphe. Le
    /// côté droit attendait un occupant, et celui-ci parle de la même chose que le champ —
    /// la page qu'on regarde. Le mettre avec le blocage et les scripts l'aurait rangé
    /// avec les outils, qui eux ne dépendent pas de la page.
    private let reader = NSButton()
    private let lock = NSImageView()
    private let plaque = ThemedView()
    private var addressHovered = false
    /// Ce que la barre affiche déjà — voir `show(url:…)`.
    private var shownState = ""

    private let address = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Rien à droite : le « + » doublait « Nouvel onglet ⌘T » de la sidebar, et
        // l'anneau doublait le clic sur l'adresse. Deux chemins vers la même action,
        // c'est deux éléments à l'écran pour rien (principe 5).
        configure(back, symbol: "chevron.left", label: "Précédent")
        configure(forward, symbol: "chevron.right", label: "Suivant")
        // Le seul bouton à droite, et il n'est pas un doublon : les actions qu'il expose
        // n'ont aucune autre porte d'entrée que la barre de menus du système.
        configure(more, symbol: "ellipsis", label: "Menu")
        // Le bouclier n'apparaît que si une liste est en service : un bouton qui
        // n'ouvrirait qu'une liste vide n'a pas à occuper la barre.
        // **Le bouclier est toujours là.** Il l'était seulement quand une liste tournait —
        // mais c'est lui qui mène au sélecteur d'éléments et au catalogue : caché, il
        // rendait inatteignable ce qui sert précisément à le remplir.
        configure(shield, symbol: "shield.lefthalf.filled", label: "Blocage")
        // Les scripts ont leur propre bouton, et pas une ligne dans le menu des
        // extensions : ce sont deux pouvoirs différents. Une extension arrive avec ses
        // permissions déclarées et son bac à sable ; un script utilisateur est du code à
        // soi, exécuté avec les droits de la page. Les ranger ensemble laisserait croire
        // que l'un est une option de l'autre.
        configure(braces, symbol: "curlybraces", label: "Scripts")
        braces.isHidden = true

        // Une surface discrète derrière l'adresse, visible au survol seulement.
        //
        // Cliquer l'adresse ouvre la palette, et rien ne le disait : un texte nu au milieu
        // d'une barre ne se donne pas pour une cible. Un fond permanent aurait ajouté du
        // chrome à demeure ; celui-ci n'existe que sous le curseur, au moment où la
        // question « est-ce que ça se clique ? » se pose.
        plaque.wantsLayer = true
        plaque.layer?.cornerCurve = .continuous
        // **Tout le champ se clique, pas seulement le texte.** Le geste vivait sur
        // l'adresse : viser à côté du dernier caractère ne faisait rien, alors que le fond
        // s'allumait — la cible qu'on voyait n'était pas celle qui répondait.
        plaque.addGestureRecognizer(NSClickGestureRecognizer(target: self,
                                                             action: #selector(openOmnibox)))
        addSubview(plaque)

        zoomBadge.isBordered = false
        zoomBadge.wantsLayer = true
        zoomBadge.layer?.cornerRadius = Tokens.Radius.pill
        zoomBadge.layer?.cornerCurve = .continuous
        zoomBadge.font = .systemFont(ofSize: 11, weight: .medium)
        zoomBadge.target = self
        zoomBadge.action = #selector(buttonAction(_:))
        zoomBadge.isHidden = true
        zoomBadge.toolTip = "Revenir à la taille réelle"
        addSubview(zoomBadge)

        reader.isBordered = false
        reader.imagePosition = .imageOnly
        reader.target = self
        reader.action = #selector(buttonAction(_:))


        // Caché tant qu'il n'y a pas d'article : un bouton qui n'ouvrirait rien apprend à
        // ne plus être regardé, et c'est la règle qu'on s'est donnée pour tous les autres.
        reader.isHidden = true
        addSubview(reader)

        lock.imageScaling = .scaleProportionallyDown
        // Caché tant qu'on ne sait pas quoi certifier : au premier affichage, il n'y a pas
        // encore de page, et un cadenas posé là parle d'une connexion qui n'existe pas.
        lock.isHidden = true
        // **Le cadenas est cliquable.** Il affirmait « chiffré » sans jamais dire par qui,
        // et c'est précisément la question qu'on se pose au moment où l'on regarde ce
        // symbole. Un indicateur qui ne mène à rien demande qu'on lui fasse confiance.
        lock.addGestureRecognizer(NSClickGestureRecognizer(target: self,
                                                           action: #selector(openSecurity)))
        addSubview(lock)

        address.font = .systemFont(ofSize: 13, weight: .medium)
        address.alignment = .left
        address.lineBreakMode = .byTruncatingTail
        addSubview(address)
        address.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openOmnibox)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(buttonAction(_:))
        addSubview(button)
    }

    override func layout() {
        super.layout()
        // Même fond que la sidebar : les deux forment un seul cadre, pas deux surfaces
        // empilées. C'est la courbe du contenu qui fait la jonction, pas un filet.
        layer?.backgroundColor = Tokens.sidebarBackground.cgColor
        [back, forward, more, shield, braces].forEach { $0.contentTintColor = Tokens.textPrimary }

        let size: CGFloat = 24
        let y = (bounds.height - size) / 2
        back.frame = NSRect(x: Tokens.Space.l, y: y, width: size, height: size)
        forward.frame = NSRect(x: Tokens.Space.l + size + Tokens.Space.xs, y: y, width: size, height: size)

        // **La droite se pose de droite à gauche, et saute ce qui est caché.**
        //
        // Chaque bouton se plaçait par rapport au précédent, avec une condition pour le
        // cas où celui-ci manquait. Deux boutons facultatifs, puis un nombre variable
        // facultatifs : la chaîne de conditions ne tenait plus. Un trou là où
        // une icône a disparu fait chercher un bouton absent, et cette boucle est ce qui
        // garantit qu'il n'y en a jamais.
        // L'ordre, de droite à gauche : le menu, les scripts, le bouclier. Les scripts se
        // tiennent contre le menu parce qu'ils sont à vous.
        var cursor = bounds.width - Tokens.Space.l
        for button in [more, braces, shield] as [NSView] where !button.isHidden {
            button.frame = NSRect(x: cursor - size, y: y, width: size, height: size)
            cursor -= size + Tokens.Space.s
        }

        // **Le badge du zoom vient après les boutons d'outils**, du côté où l'on
        // regarde déjà quand on cherche l'état de la page.
        //
        // Il a fait un détour par l'intérieur du champ, contre le cadenas, au motif que le
        // zoom parle de la page comme l'adresse. Il y était moins bien : le champ a une
        // géométrie stable, et un chiffre qui apparaît dedans décale le texte qu'on lisait.
        // Ici il pousse la bordure du champ, qui bouge de toute façon avec la fenêtre.
        if !zoomBadge.isHidden {
            let width = max(38, zoomBadge.intrinsicContentSize.width + Tokens.Space.m)
            zoomBadge.frame = NSRect(x: cursor - width, y: (bounds.height - 20) / 2,
                                     width: width, height: 20)
            zoomBadge.layer?.backgroundColor = Tokens.field.cgColor
            zoomBadge.contentTintColor = Tokens.textSecondary
            cursor -= width + Tokens.Space.s
        }

        // **Un champ, pas un texte flottant.**
        //
        // L'adresse se centrait avec le cadenas, et la plaque épousait sa largeur : la
        // « barre de recherche » changeait donc de taille et de position à chaque page, et
        // n'existait qu'au survol. On ne pouvait pas la viser sans l'avoir déjà trouvée, et
        // deux captures d'écran du même navigateur ne montraient pas le même objet.
        //
        // Elle a maintenant une géométrie **stable** : une largeur qui ne dépend que de la
        // fenêtre, un centre qui ne bouge pas, un fond permanent. Ce qui change au survol,
        // c'est la teinte du fond et rien d'autre.
        let gap = Tokens.Space.l
        // Bornée des deux côtés : assez large pour une adresse ordinaire, jamais au point
        // de toucher les boutons — c'est `cursor` qui dit où commence la droite occupée.
        // Le bouton d'incrustation mange sa place à gauche du champ quand il est là. On
        // la retire du calcul plutôt que de le poser par-dessus : un bouton qui chevauche
        // la plaque se clique une fois sur deux.
        let libre = cursor - (forward.frame.maxX + gap)
        let fieldWidth = max(240, min(bounds.width * 0.46, min(560, libre)))
        var fieldX = (bounds.width - fieldWidth) / 2
        fieldX = min(max(fieldX, forward.frame.maxX + gap), cursor - gap - fieldWidth)

        // 28 et non la hauteur d'une ligne : la barre fait trente-huit points, et un champ
        // de trente-quatre s'y colle en haut et en bas — il ne se lirait plus comme un
        // champ posé sur la barre, mais comme la barre elle-même.
        let fieldHeight: CGFloat = 28
        plaque.frame = NSRect(x: fieldX, y: (bounds.height - fieldHeight) / 2,
                              width: max(0, fieldWidth), height: fieldHeight)
        plaque.layer?.cornerRadius = Tokens.Row.radius
        // Un fond à demeure, plus marqué sous le curseur. Sans lui, rien ne disait que
        // l'adresse se clique ; permanent, il donne au champ la même présence qu'une ligne
        // de la colonne — c'est le même vocabulaire, donc rien de plus à apprendre.
        plaque.layer?.backgroundColor = addressHovered ? Tokens.selectionFill.cgColor
                                                       : Tokens.field.cgColor

        // **Le cadenas est à gauche, et il n'en bouge plus.**
        //
        // Il se centrait avec l'adresse, en bloc : il se déplaçait donc à chaque page, et
        // d'autant plus loin que le titre était court. Un indicateur de sécurité qui change
        // de place demande qu'on le cherche avant de pouvoir le lire — c'est le contraire de
        // son rôle, et c'était la dernière chose qui bougeait encore dans cette barre.
        let inset = Tokens.Space.m
        let lockSize: CGFloat = 14
        lock.frame = NSRect(x: plaque.frame.minX + inset, y: (bounds.height - lockSize) / 2,
                            width: lockSize, height: lockSize)
        reader.frame = NSRect(x: plaque.frame.maxX - inset - lockSize,
                              y: (bounds.height - lockSize) / 2,
                              width: lockSize, height: lockSize)
        reader.contentTintColor = Tokens.textPrimary

        // Sa place est réservée **des deux côtés**, qu'il s'affiche ou non. À gauche pour
        // qu'il ne chevauche jamais le texte ; à droite pour que l'adresse reste centrée
        // dans le champ — sinon elle sauterait d'une demi-largeur de cadenas entre une page
        // qui en a un et une page interne qui n'en a pas.
        let reserved = inset + lockSize + Tokens.Space.s
        let textArea = plaque.frame.insetBy(dx: reserved, dy: 0)
        let mesure = address.cell?.cellSize(forBounds: NSRect(x: 0, y: 0,
                                                              width: max(0, textArea.width),
                                                              height: 16)).width ?? 0
        let texte = min(max(mesure, 0), max(0, textArea.width))
        address.frame = NSRect(x: textArea.midX - texte / 2, y: (bounds.height - 16) / 2,
                               width: texte, height: 16)

        updateTrackingAreas()
    }

    func show(url: URL?, insecure: Bool, canGoBack: Bool, canGoForward: Bool,
              extensionName: String? = nil) {
        // **Rien à refaire quand rien n'a changé.**
        //
        // WebKit signale l'adresse, le titre et l'avancement des dizaines de fois pendant
        // qu'une page arrive, et chacun repassait ici : composition de l'adresse enrichie,
        // puis mesure du texte par la cellule à la mise en page suivante. C'est du travail
        // exact, refait à l'identique — le seul genre qu'on puisse supprimer sans rien
        // perdre.
        let state = "\(url?.absoluteString ?? "")|\(insecure)|\(canGoBack)|\(canGoForward)|\(extensionName ?? "")"
        guard state != shownState else { return }
        shownState = state

        address.attributedStringValue = Self.render(url, insecure: insecure,
                                                    extensionName: extensionName)
        // Sans ce rappel, le cadenas gardait la position calculée pour l'adresse
        // précédente — et pour la toute première, celle d'un champ vide : au milieu.
        needsLayout = true

        lock.image = NSImage(systemSymbolName: insecure ? "exclamationmark.triangle" : "lock",
                             accessibilityDescription: insecure ? "Connexion non chiffrée" : "Connexion chiffrée")
        lock.contentTintColor = insecure ? Tokens.Security.insecure : Tokens.textSecondary
        lock.isHidden = !Self.certifies(url)

        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        // « Différencier sans couleur » : l'état désactivé passe par l'opacité.
        back.alphaValue = canGoBack ? 1 : 0.35
        forward.alphaValue = canGoForward ? 1 : 0.35
    }

    /// Y a-t-il quelque chose à certifier ?
    ///
    /// Le cadenas ne dit qu'une chose : *cette page vient d'un serveur distant, et voici
    /// l'état du transport*. Il lui faut donc un hôte et un protocole de transport. Sur une
    /// page interne, sur un onglet vide, sur un fichier local, il n'y a pas de connexion —
    /// et un cadenas posé là **affirme un chiffrement qui n'a pas lieu**. C'est le pire
    /// défaut possible pour un indicateur de sécurité : il ne se trompe pas de forme, il se
    /// trompe de vérité.
    ///
    /// Le cas vu à l'écran : un onglet neuf dont la vue annonce `about:blank`. L'adresse
    /// n'était pas nulle, seulement sans hôte — la barre affichait `🔒 wuji://`.
    static func certifies(_ url: URL?) -> Bool {
        guard let url, let host = url.host(), !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// L'adresse, écrite pour répondre à une seule question : **sur quel site suis-je ?**
    ///
    /// C'est une question de sécurité avant d'être une question de confort, et elle se
    /// perdait dans le bruit — tout s'affichait du même poids, le site au milieu d'un
    /// protocole et d'un identifiant de vidéo. Le nom du site est donc seul en pleine
    /// valeur ; le sous-domaine et le chemin s'estompent.
    ///
    /// **`https://` disparaît, `http://` reste.** Le premier ne dit rien que le cadenas ne
    /// dise mieux. Le second est une information — et il s'écrit dans la couleur du danger,
    /// parce qu'un site en clair doit se voir sans qu'on aille chercher le petit symbole.
    static func render(_ url: URL?, insecure: Bool,
                       extensionName: String? = nil) -> NSAttributedString {
        let normal = NSFont.systemFont(ofSize: 13, weight: .medium)
        let result = NSMutableAttributedString()

        func append(_ text: String, _ colour: NSColor, weight: NSFont.Weight = .regular) {
            guard !text.isEmpty else { return }
            result.append(NSAttributedString(string: text, attributes: [
                .font: weight == .regular ? normal : NSFont.systemFont(ofSize: 13, weight: weight),
                .foregroundColor: colour
            ]))
        }

        // **Une page d'extension se nomme par son extension.** Son hôte est l'identifiant
        // que WebKit lui a tiré au sort — trente-six caractères qui ne veulent rien dire, et
        // qui ressemblent à l'adresse d'un site qu'on ne connaît pas. C'est le nom de
        // l'extension qui répond à la seule question que la barre doit trancher : chez qui
        // suis-je ?
        if let extensionName, let url {
            append("extension://", Tokens.textSecondary)
            append(extensionName, Tokens.textPrimary, weight: .semibold)
            let chemin = url.path
            append(chemin == "/" ? "" : chemin, Tokens.textSecondary)
            return result
        }

        guard let url, let host = url.host(), !host.isEmpty else {
            // Pas d'hôte du tout : ou bien il n'y a pas de page — onglet neuf, vue vidée par
            // la veille, qui annoncent `about:blank` —, et alors on est chez Wuji ; ou bien
            // c'est une adresse d'une autre nature, un fichier local par exemple, et
            // l'annoncer comme une page de Wuji serait un mensonge de plus.
            guard let url, let scheme = url.scheme, scheme != "about", !url.path.isEmpty else {
                append("wuji://", Tokens.textSecondary)
                return result
            }
            let dossier = url.deletingLastPathComponent().path
            append(scheme + "://" + (dossier.hasSuffix("/") ? dossier : dossier + "/"),
                   Tokens.textSecondary)
            append(url.lastPathComponent, Tokens.textPrimary, weight: .semibold)
            return result
        }

        // Une page interne garde son schéma : c'est lui qui dit qu'on est chez Wuji et non
        // sur un site qui s'appellerait « réglages ». Le retirer l'aurait affichée comme
        // un simple mot, sans rien pour la distinguer d'une page du web.
        if url.scheme == InternalPageHandler.scheme {
            append(InternalPageHandler.scheme + "://", Tokens.textSecondary)
            append(host, Tokens.textPrimary, weight: .semibold)
            let chemin = url.path
            append(chemin == "/" ? "" : chemin, Tokens.textSecondary)
            return result
        }

        if insecure { append("http://", Tokens.Security.insecure) }

        // Le site au sens de la liste des suffixes publics : le même découpage que celui
        // qui décide où se range un zoom retenu. Deux notions de « site » dans la même
        // application finiraient par se contredire.
        let site = Site.name(ofHost: host)
        if host != site, host.hasSuffix(site) {
            append(String(host.dropLast(site.count)), Tokens.textSecondary)
        }
        append(site, Tokens.textPrimary, weight: .semibold)

        let rest = url.path + (url.query.map { "?" + $0 } ?? "")
        append(rest == "/" ? "" : rest, Tokens.textSecondary)
        return result
    }

    /// Le mode lecture : disponible sur cette page, et actif ou non.
    ///
    /// Le glyphe plein dit l'état sans changer de forme ni de place — « différencier sans
    /// couleur » tient, et l'œil ne cherche pas un bouton qui aurait bougé.
    func setReader(available: Bool, active: Bool) {
        reader.isHidden = !available
        reader.image = NSImage(systemSymbolName: active ? "doc.plaintext.fill" : "doc.plaintext",
                               accessibilityDescription: active ? "Quitter le mode lecture"
                                                                : "Mode lecture")
        reader.toolTip = active ? "Quitter le mode lecture" : "Mode lecture"
        reader.alphaValue = active ? 1 : 0.65
        needsLayout = true
    }

    /// Le zoom de la page, en pourcentage — ou `nil` à la taille réelle, où il s'efface.
    func setZoom(_ percent: Int?) {
        let shown = percent.map { "\($0) %" }
        guard zoomBadge.title != (shown ?? "") || zoomBadge.isHidden != (shown == nil) else {
            return
        }
        zoomBadge.title = shown ?? ""
        zoomBadge.isHidden = shown == nil
        zoomBadge.setAccessibilityLabel(shown.map { "Zoom \($0), cliquer pour revenir à la taille réelle" })
        needsLayout = true
    }

    /// Le bouton des scripts n'existe que s'il y en a d'installés, et se pâlit quand
    /// aucun ne vise la page qu'on regarde.
    func setScripts(installed: Bool, activeHere: Bool) {
        braces.isHidden = !installed
        braces.alphaValue = activeHere ? 1 : 0.5
        braces.setAccessibilityLabel(activeHere ? "Scripts actifs sur cette page"
                                                : "Aucun script sur cette page")
        needsLayout = true
    }

    /// Le bouclier se montre dès qu'une liste bloque quelque chose.
    func setBlocking(active: Bool) {
        guard shield.isHidden == active else { return }
        shield.isHidden = !active
        needsLayout = true
    }

    var menuButton: NSView { more }
    var blockingButton: NSView { shield }
    var scriptsButton: NSView { braces }


    // Le survol n'est suivi que sur la zone de l'adresse, et elle bouge avec le texte :
    // la zone se refait donc à chaque mise en page plutôt qu'une fois pour toutes.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: plaque.frame,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        addressHovered = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        addressHovered = false
        needsLayout = true
    }

    @objc private func openOmnibox() { delegate?.topBarDidRequestOmnibox(self) }

    @objc private func openSecurity() { delegate?.topBar(self, didTrigger: .security) }

    /// Pour ancrer le menu sous le cadenas.
    var securityButton: NSView { lock }

    @objc private func buttonAction(_ sender: NSButton) {
        switch sender {
        case back:    delegate?.topBar(self, didTrigger: .back)
        case forward: delegate?.topBar(self, didTrigger: .forward)
        case more:    delegate?.topBar(self, didTrigger: .menu)
        case shield:  delegate?.topBar(self, didTrigger: .blocking)
        case braces:  delegate?.topBar(self, didTrigger: .scripts)
        case zoomBadge: delegate?.topBar(self, didTrigger: .zoomReset)
        case reader:  delegate?.topBar(self, didTrigger: .reader)
        default:      break
        }
    }
}

/// L'icône d'une extension épinglée.
///
/// Un `NSButton` ne suffisait pas pour deux raisons qui se cumulent : la pastille — le
/// compteur qu'une extension affiche sur son icône — n'a nulle part où vivre dans un
/// bouton d'image, et le clic droit doit ouvrir un menu à nous plutôt que celui d'AppKit.
