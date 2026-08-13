import AppKit

/// Une notification discrète, en bas à droite du contenu.
///
/// La spec §4.1 les prévoit pour « pub bloquée, téléchargement fini, session privée ».
/// La règle qui les rend acceptables dans une interface qui se veut calme : **elles ne
/// demandent rien.** Pas de bouton, pas de croix, pas d'attente — elles disent ce qui
/// vient de se passer et s'en vont. Cliquer mène à l'endroit concerné, ne rien faire est
/// une réponse valable.
@MainActor
final class Toast: ThemedView {

    private let pill = NSView()
    private let glyph = NSImageView()
    private let label = InsetTextField.label()
    private var action: (() -> Void)?
    private var dismissal: DispatchWorkItem?

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Seule la pilule intercepte le clic : le reste de la page continue de vivre.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return pill.frame.contains(local) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let handler = action
        hide()
        handler?()
    }

    func show(_ message: String, onClick: (() -> Void)? = nil) {
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

        let width = min(360, max(220, label.intrinsicContentSize.width + 64))
        pill.frame = NSRect(x: bounds.width - width - Self.margin, y: Self.margin,
                            width: width, height: Self.height)
        glyph.frame = NSRect(x: Tokens.Row.inset, y: (Self.height - 16) / 2, width: 16, height: 16)
        let left = Tokens.Row.inset + 16 + Tokens.Row.glyphGap
        label.frame = NSRect(x: left, y: 0, width: width - left - Tokens.Row.inset, height: Self.height)
    }
}
