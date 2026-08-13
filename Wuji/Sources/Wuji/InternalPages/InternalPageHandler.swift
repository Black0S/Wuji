import AppKit
import WebKit

/// Sert les pages du schéma `wuji://`.
///
/// La spec §4.1 en fait un espace propre, adressable et bookmarkable, plutôt que des
/// panneaux collés au chrome. Une page interne se navigue, se recharge, se met en favori
/// et s'imprime comme n'importe quelle autre — pour rien, puisqu'on écrit du HTML de toute
/// façon.
///
/// Passer par un `WKURLSchemeHandler` plutôt que par `loadHTMLString` a une conséquence
/// qui compte : l'adresse reste `wuji://history` dans la barre. Avec `loadHTMLString`, la
/// page vivrait sous `about:blank` et ne pourrait ni être rechargée ni être mise en favori.
@MainActor
final class InternalPageHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "wuji"

    private unowned let history: HistoryStore

    init(history: HistoryStore) {
        self.history = history
    }

    nonisolated func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        // WebKit appelle ce gestionnaire sur le fil principal, mais sa signature ne le
        // déclare pas : sans cette annotation, le compilateur refuse de faire traverser la
        // tâche jusqu'à l'acteur principal.
        nonisolated(unsafe) let task = task
        MainActor.assumeIsolated {
            guard let url = task.request.url else { return }
            let body = html(for: url)
            let data = Data(body.utf8)
            let response = URLResponse(url: url, mimeType: "text/html",
                                       expectedContentLength: data.count, textEncodingName: "utf-8")
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func html(for url: URL) -> String {
        switch url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "history":
            return HistoryPage.html(entries: history.recent())
        default:
            return HistoryPage.html(entries: history.recent())
        }
    }
}
