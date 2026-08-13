import AppKit
import WebKit

/// D'où vient une révélation. Compté séparément : à la fin de la semaine 3, c'est ce
/// tableau qui tranche, pas une opinion.
enum RevealSource: String, CaseIterable {
    case edge         = "bord haut (C)"
    case overscroll   = "overscroll (A)"
    case threeFinger  = "trois doigts (B)"
    case keyboard     = "clavier (D)"
}

@MainActor
protocol RevealGestureDelegate: AnyObject {
    func gesture(_ source: RevealSource, requestsReveal: Bool)
}

/// **Candidat A — overscroll.** Le rebond en haut de page révèle.
///
/// Impossible à faire depuis AppKit : sur macOS, `WKWebView` n'expose pas son scroll view
/// et avale `scrollWheel(with:)`. On passe donc par du JS injecté, qui est le seul endroit
/// d'où l'on voit à la fois la position de défilement et l'intention de la molette.
///
/// Le défaut connu est structurel : sur une page non défilable, `scrollY` vaut toujours 0,
/// donc **toute** tentative de défilement vers le haut déclenche. À juger à l'usage — c'est
/// peut-être acceptable, c'est peut-être rédhibitoire.
@MainActor
final class OverscrollGesture: NSObject, WKScriptMessageHandler {

    static let handlerName = "wujiOverscroll"
    weak var delegate: RevealGestureDelegate?
    var isEnabled = true

    /// Seuil accumulé, en pixels de molette, avant de considérer l'intention comme délibérée.
    /// C'est le réglage à triturer : trop bas, la lecture déclenche ; trop haut, le geste est mort.
    static let threshold = 120

    static var userScript: WKUserScript {
        let source = """
        (function () {
            let accumulated = 0;
            let lastEvent = 0;
            window.addEventListener('wheel', function (event) {
                const now = Date.now();
                if (now - lastEvent > 300) { accumulated = 0; }  // nouvelle intention
                lastEvent = now;

                const atTop = window.scrollY <= 0;
                if (atTop && event.deltaY < 0) {
                    accumulated += -event.deltaY;
                    if (accumulated > \(threshold)) {
                        accumulated = 0;
                        window.webkit.messageHandlers.\(handlerName).postMessage('reveal');
                    }
                } else {
                    accumulated = 0;
                }
            }, { passive: true });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isEnabled else { return }
        delegate?.gesture(.overscroll, requestsReveal: true)
    }
}

/// **Candidat B — trois doigts.**
///
/// On suit les touches indirectes du trackpad à la main plutôt que d'utiliser `.swipe` :
/// le swipe système n'existe que si l'utilisateur a réglé « Balayer entre les pages » sur
/// trois doigts, sinon les trois doigts partent dans Mission Control. Ce conflit est
/// précisément l'une des choses que la semaine 2 doit constater.
@MainActor
final class ThreeFingerGesture {

    weak var delegate: RevealGestureDelegate?
    var isEnabled = true

    /// Déplacement vertical moyen, en fraction de la surface du trackpad.
    private let travelThreshold: CGFloat = 0.12

    private var origin: CGFloat?
    nonisolated(unsafe) private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.gesture]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }
        let touches = event.touches(matching: .touching, in: nil)
        guard touches.count == 3 else {
            origin = nil
            return
        }

        let average = touches.reduce(0) { $0 + $1.normalizedPosition.y } / 3
        guard let start = origin else {
            origin = average
            return
        }

        let travel = average - start
        if travel > travelThreshold {
            origin = nil
            delegate?.gesture(.threeFinger, requestsReveal: true)
        } else if travel < -travelThreshold {
            origin = nil
            delegate?.gesture(.threeFinger, requestsReveal: false)
        }
    }
}
