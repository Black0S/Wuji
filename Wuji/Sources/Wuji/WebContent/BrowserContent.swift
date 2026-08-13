import AppKit
import WebKit

/// Le conteneur de contenu : un `WKWebView` bord à bord, et **son** liseré de sécurité.
///
/// Un liseré par conteneur, pas un par fenêtre (spec §4.3). En v1 il n'y a qu'un volet,
/// donc ça ne se voit pas — mais le jour du Split View, deux volets dont un seul est
/// chiffré rendent un liseré de fenêtre absurde. Deux heures maintenant, deux semaines plus tard.
@MainActor
final class BrowserContent: ThemedView {

    let border = SecurityBorderView()
    private(set) var webView: WKWebView?

    /// Le chargement est le seul retour d'information qui doit rester visible **même
    /// interface masquée** : sans lui, une page lente est indiscernable d'un clic manqué.
    /// D'où un filet de 2 pt collé au bord haut du contenu, qui s'efface tout seul.
    private let progress = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        progress.wantsLayer = true
        progress.layer?.opacity = 0
        addSubview(border)
        addSubview(progress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        border.frame = bounds       // au-dessus du contenu : la page ne se remet jamais en page
        progress.layer?.backgroundColor = Tokens.textPrimary.cgColor
    }

    func setProgress(_ value: Double, isLoading: Bool) {
        let height: CGFloat = 2
        let width = bounds.width * CGFloat(min(max(value, 0), 1))

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        progress.frame = NSRect(x: 0, y: bounds.height - height, width: width, height: height)
        // On disparaît à l'arrivée, pas à 100 % : la barre ne doit jamais rester à l'écran.
        progress.layer?.opacity = (isLoading && value < 1) ? 0.55 : 0
        CATransaction.commit()
    }

    func attach(_ newWebView: WKWebView) {
        guard newWebView !== webView else { return }
        webView?.removeFromSuperview()
        webView = newWebView
        newWebView.frame = bounds
        newWebView.autoresizingMask = [.width, .height]
        addSubview(newWebView, positioned: .below, relativeTo: border)
        needsLayout = true
    }
}

/// Un onglet. Pas de barre d'onglets dans le prototype, et c'est délibéré : la thèse à
/// éprouver est que **l'omnibox devient le vrai sélecteur d'onglets** quand l'interface
/// disparaît. Une barre d'onglets rendrait le test caduc.
@MainActor
final class Tab {
    let webView: WKWebView

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
    }

    var url: URL? { webView.url }
    var title: String { webView.title ?? url?.host() ?? "Nouvel onglet" }

    /// L'état de sécurité déduit de l'URL. Le vrai signal (certificat invalide,
    /// permission caméra active) arrive en J1/J2 — ici on valide le vocabulaire visuel.
    var security: SecurityBorderView.State {
        guard let scheme = url?.scheme?.lowercased() else { return .none }
        return scheme == "http" ? .insecure : .none
    }
}
