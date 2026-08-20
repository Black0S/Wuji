import AppKit

/// Une notification discrète, en bas à droite du contenu.
///
/// La spec §4.1 les prévoit pour « pub bloquée, téléchargement fini, session privée ».
/// La règle qui les rend acceptables dans une interface qui se veut calme : **elles ne
/// demandent rien.** Pas de bouton, pas de croix, pas d'attente — elles disent ce qui
/// vient de se passer et s'en vont. Cliquer mène à l'endroit concerné, ne rien faire est
/// une réponse valable.
///
/// **Sauf une, et elle vit au même endroit.** Les demandes — autoriser la caméra, partager
/// sa position, installer un script — sont des questions, donc elles attendent une réponse
/// et ne s'effacent pas seules. Mais elles arrivent là où l'on regarde déjà quand Wuji
/// parle : en bas à droite. Une carte au centre de l'écran pour dire la même chose ferait
/// deux vocabulaires pour un seul propos, et le second serait le plus brutal des deux.
///
/// Fermer sans répondre vaut « non ». C'est la seule réponse qu'on puisse déduire d'un
/// silence sans se tromper.
@MainActor
final class Toast: ThemedView {

    private let pill = NSView()
    private let glyph = NSImageView()
    private let label = InsetTextField.label()
    private var action: (() -> Void)?
    private var dismissal: DispatchWorkItem?

    /// La forme « question » : un titre, une explication, deux réponses.
    private let title = InsetTextField.label()
    private let detail = InsetTextField.wrapping()
    private let confirm = BubbleButton()
    private let cancel = BubbleButton()
    private var onCancel: (() -> Void)?
    /// Une question est-elle posée ? La bulle n'en pose qu'une : une seconde chasserait
    /// la première, et la page qui attendait sa réponse ne l'aurait jamais.
    private(set) var isAsking = false

    /// La forme « identifiants » : la même carte, avec deux champs entre l'explication et
    /// les réponses.
    ///
    /// **Une boîte de dialogue du système aurait été le deuxième vocabulaire** pour dire ce
    /// que cette carte dit déjà — et le plus brutal des deux, au centre de l'écran. Un site
    /// qui demande un mot de passe pose une question comme une page qui demande la caméra ;
    /// la réponse s'écrit donc au même endroit.
    private let identity = BoxedField(placeholder: "Identifiant")
    private let secret = BoxedField(placeholder: "Mot de passe", isSecure: true)
    private var onSubmit: ((String, String) -> Void)?
    private var isAskingCredentials = false

    private static let height: CGFloat = 40
    private static let margin: CGFloat = 16
    private static let visible: TimeInterval = 4.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        pill.wantsLayer = true
        pill.layer?.cornerRadius = Tokens.Radius.pill
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        Tokens.applyChromeShadow(to: pill)
        addSubview(pill)

        glyph.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyDown
        pill.addSubview(glyph)
        pill.addSubview(label)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        for view in [title, detail, confirm, cancel] {
            view.isHidden = true
            pill.addSubview(view)
        }
        for field in [identity, secret] {
            field.isHidden = true
            field.onSubmit = { [weak self] in self?.submitCredentials() }
            pill.addSubview(field)
        }

        confirm.onClick = { [weak self] in
            guard let self else { return }
            // Deux formes de « oui » : une question rend une décision, une demande
            // d'identifiants rend ce qui est écrit dans les champs.
            if isAskingCredentials { return submitCredentials() }
            let handler = action
            onCancel = nil
            hide()
            handler?()
        }
        cancel.onClick = { [weak self] in self?.decline() }
    }

    /// Pose une question. Rien ne se referme tout seul : une demande d'autorisation qui
    /// s'évanouit laisse la page attendre une réponse qui ne viendra jamais.
    func ask(title question: String, message: String, confirm label: String,
             isDestructive: Bool, onCancel refuse: @escaping () -> Void,
             onConfirm accept: @escaping () -> Void) {
        dismissal?.cancel()
        dismissal = nil

        isAsking = true
        title.stringValue = question
        detail.stringValue = message
        confirm.set(title: label, symbol: isDestructive ? "trash" : "checkmark",
                    isDestructive: isDestructive)
        cancel.set(title: "Annuler", symbol: "xmark", isDestructive: false)
        action = accept
        onCancel = refuse

        glyph.isHidden = true
        self.label.isHidden = true
        for view in [title, detail, confirm, cancel] { view.isHidden = false }

        isHidden = false
        alphaValue = 1
        needsLayout = true
        window?.makeFirstResponder(self)
    }

    /// Demande un identifiant et un mot de passe pour un site.
    ///
    /// **Rien n'est retenu.** Ce que l'on tape part au serveur et disparaît avec la carte :
    /// Wuji n'a pas de trousseau, et un navigateur qui garderait des mots de passe sans en
    /// avoir un serait le pire des deux mondes. Le système d'exploitation et les
    /// gestionnaires de mots de passe savent remplir ici comme ailleurs.
    func askCredentials(title question: String, message: String,
                        onCancel refuse: @escaping () -> Void,
                        onSubmit submit: @escaping (String, String) -> Void) {
        ask(title: question, message: message, confirm: "Se connecter",
            isDestructive: false, onCancel: refuse, onConfirm: {})
        isAskingCredentials = true
        onSubmit = submit
        identity.text = ""
        secret.text = ""
        for field in [identity, secret] { field.isHidden = false }
        confirm.set(title: "Se connecter", symbol: "arrow.right", isDestructive: false)
        needsLayout = true
        // Le curseur est dans le premier champ : la carte apparaît parce qu'on attend une
        // frappe, pas un clic de plus pour pouvoir taper.
        DispatchQueue.main.async { [weak self] in self?.identity.focus() }
    }

    /// ⏎ dans l'un ou l'autre champ vaut « Se connecter » — sauf depuis l'identifiant, où
    /// il passe au mot de passe : c'est l'ordre dans lequel on remplit.
    private func submitCredentials() {
        guard isAskingCredentials else { return }
        if identity.isEditing, secret.text.isEmpty { return secret.focus() }
        let submit = onSubmit
        let user = identity.text
        let password = secret.text
        onSubmit = nil
        onCancel = nil
        hide()
        submit?(user, password)
    }

    /// Fermer sans répondre vaut « non ».
    private func decline() {
        let refuse = onCancel
        onCancel = nil
        hide()
        refuse?()
    }

    override var acceptsFirstResponder: Bool { isAsking }

    override func cancelOperation(_ sender: Any?) {
        guard isAsking else { return }
        decline()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Seule la pilule intercepte le clic : le reste de la page continue de vivre.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard pill.frame.contains(local) else { return nil }
        // En mode question, ce sont les boutons qui répondent : cliquer la carte elle-même
        // ne doit rien valider.
        return isAsking ? super.hitTest(point) : self
    }

    override func mouseUp(with event: NSEvent) {
        guard !isAsking else { return }
        let handler = action
        hide()
        handler?()
    }

    func show(_ message: String, onClick: (() -> Void)? = nil) {
        // Une question en cours ne se fait pas chasser par une nouvelle du jour.
        guard !isAsking else { return }
        label.stringValue = message
        action = onClick
        isHidden = false
        alphaValue = 1
        needsLayout = true

        dismissal?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visible, execute: item)
    }

    private func hide() {
        dismissal?.cancel()
        dismissal = nil
        if isAsking {
            isAsking = false
            isAskingCredentials = false
            onSubmit = nil
            for view in [title, detail, confirm, cancel] { view.isHidden = true }
            for field in [identity, secret] {
                field.isHidden = true
                // Le mot de passe ne traîne pas dans une vue cachée en attendant la
                // prochaine question.
                field.text = ""
            }
            glyph.isHidden = false
            label.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
    }

    override func layout() {
        super.layout()
        pill.layer?.backgroundColor = Tokens.chromeBackground.cgColor
        pill.layer?.borderColor = Tokens.chromeHairline.cgColor
        glyph.contentTintColor = Tokens.textSecondary
        label.textColor = Tokens.textPrimary

        guard !isAsking else { return layoutQuestion() }

        let width = min(360, max(220, label.intrinsicContentSize.width + 64))
        pill.frame = NSRect(x: bounds.width - width - Self.margin, y: Self.margin,
                            width: width, height: Self.height)
        glyph.frame = NSRect(x: Tokens.Row.inset, y: (Self.height - 16) / 2, width: 16, height: 16)
        let left = Tokens.Row.inset + 16 + Tokens.Row.glyphGap
        label.frame = NSRect(x: left, y: 0, width: width - left - Tokens.Row.inset, height: Self.height)
    }

    /// La carte de question, mesurée par son texte : une hauteur fixe couperait la phrase
    /// des sites au nom long, et c'est précisément l'information qu'il faut lire.
    private func layoutQuestion() {
        title.textColor = Tokens.textPrimary
        detail.textColor = Tokens.textSecondary

        let width: CGFloat = 320
        let inset = Tokens.Row.inset + 2
        let content = width - inset * 2
        let titleHeight: CGFloat = 18
        let detailHeight = ceil(detail.cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: content, height: 400)).height ?? 32)
        let buttons = Tokens.Row.compact
        let fieldHeight: CGFloat = 26
        let fields: CGFloat = isAskingCredentials ? (fieldHeight * 2 + 6 + 12) : 0
        let height = 14 + titleHeight + 4 + detailHeight + fields + 12 + buttons + 12

        pill.frame = NSRect(x: bounds.width - width - Self.margin, y: Self.margin,
                            width: width, height: height)
        // Repère en haut à gauche, comme on lit.
        title.frame = NSRect(x: inset, y: height - 14 - titleHeight, width: content, height: titleHeight)
        detail.frame = NSRect(x: inset, y: title.frame.minY - 4 - detailHeight,
                              width: content, height: detailHeight)
        if isAskingCredentials {
            identity.frame = NSRect(x: inset, y: detail.frame.minY - 12 - fieldHeight,
                                    width: content, height: fieldHeight)
            secret.frame = NSRect(x: inset, y: identity.frame.minY - 6 - fieldHeight,
                                  width: content, height: fieldHeight)
        }

        let confirmWidth = confirm.width
        let cancelWidth = cancel.width
        cancel.frame = NSRect(x: width - inset - cancelWidth, y: 12,
                              width: cancelWidth, height: buttons)
        confirm.frame = NSRect(x: cancel.frame.minX - 6 - confirmWidth, y: 12,
                               width: confirmWidth, height: buttons)
    }
}

/// Un bouton de la bulle : même vocabulaire que les lignes d'une feuille d'action — un
/// glyphe, un mot, un fond au survol — mais dimensionné à son texte pour tenir à deux dans
/// la largeur d'une info-bulle.
@MainActor
final class BubbleButton: ThemedView {

    var onClick: (() -> Void)?

    private let glyph = NSImageView()
    private let label = InsetTextField.label(size: 12, weight: .medium)
    private var isDestructive = false
    private var hovering = false

    var width: CGFloat { label.intrinsicContentSize.width + 14 + 16 + 6 + 12 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Row.radius
        layer?.cornerCurve = .continuous
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, symbol: String, isDestructive: Bool) {
        label.stringValue = title
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.isDestructive = isDestructive
        setAccessibilityLabel(title)
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsLayout = true }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func layout() {
        super.layout()
        let tint = isDestructive ? Tokens.Security.insecure : Tokens.textPrimary
        glyph.contentTintColor = tint
        label.textColor = tint
        layer?.backgroundColor = hovering ? Tokens.selectionFill.cgColor : NSColor.clear.cgColor

        glyph.frame = NSRect(x: 12, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 12 + 14 + 6, y: 0,
                             width: bounds.width - 12 - 14 - 6 - 12, height: bounds.height)
    }
}
