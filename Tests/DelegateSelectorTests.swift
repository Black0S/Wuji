import Testing
import WebKit
@testable import Wuji

/// Les délégués que WebKit doit voir.
///
/// **Un délégué que WebKit ne voit pas ne fait rien, et ne le dit pas.** Le cas vécu :
/// l'invite d'authentification a été écrite, compilée sans une erreur ni un avertissement,
/// installée — et jamais appelée. Pas d'invite, pas de certificat lu, pas de message :
/// exactement comme si le fichier n'existait pas.
///
/// La cause tient dans le type d'un paramètre. WebKit demande à l'objet s'il répond au
/// sélecteur ; Swift n'expose la méthode à Objective-C que si elle satisfait *exactement*
/// l'exigence du protocole. Mesuré dans le mode de langage du projet :
///
///     forme async ................................ ne répond pas
///     complétion sans @MainActor ................. ne répond pas
///     complétion avec @MainActor ................. répond, et la page se charge
///
/// Ces tests demandent la même chose que WebKit demande. Ils ne vérifient pas ce que le
/// code fait — ils vérifient qu'il **existe** du point de vue du moteur, ce qu'aucune
/// relecture ne montre.
@MainActor
struct DelegateSelectorTests {

    private func répond(_ selector: String, _ type: NSObject.Type = AppDelegate.self) -> Bool {
        type.instancesRespond(to: Selector((selector)))
    }

    @Test func lAuthentificationEstVisible() {
        // Celui qui manquait. Sans lui : aucune invite sur un site protégé, et un
        // certificat auto-signé sans issue.
        #expect(répond("webView:didReceiveAuthenticationChallenge:completionHandler:"))
    }

    @Test func laNavigationEstVisible() {
        #expect(répond("webView:decidePolicyForNavigationAction:decisionHandler:"))
        #expect(répond("webView:decidePolicyForNavigationResponse:decisionHandler:"))
        #expect(répond("webView:didFinishNavigation:"))
        #expect(répond("webView:didFailProvisionalNavigation:withError:"))
        #expect(répond("webView:didFailNavigation:withError:"))
    }

    @Test func lesFenêtresEtLesTéléchargementsSontVisibles() {
        #expect(répond("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:"))
        #expect(répond("webView:navigationAction:didBecomeDownload:"))
        #expect(répond("webView:navigationResponse:didBecomeDownload:"))
    }

    @Test func lesAutorisationsSontVisibles() {
        #expect(répond("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"))
        // Le sélecteur privé de la géolocalisation : il n'est dans aucun en-tête public,
        // donc rien d'autre qu'un essai comme celui-ci ne dit qu'on l'a bien écrit.
        #expect(répond("_webView:requestGeolocationPermissionForFrame:decisionHandler:"))
    }

    @Test func leChoixDUnFichierEstVisible() {
        // Sans lui, un champ « choisir un fichier » ne fait rien du tout : le clic part,
        // la page attend, et rien n'arrive.
        #expect(répond("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:"))
    }

    @Test func lesMessagesDesPagesSontVisibles() {
        #expect(répond("userContentController:didReceiveScriptMessage:"))
    }

    /// Le même piège, sur la surface des extensions.
    ///
    /// Ces méthodes sont écrites en `async` : le compilateur en tire le thunk à complétion
    /// que WebKit interroge — vérifié ici, et non supposé. Sans elles, une extension ne
    /// peut ni ouvrir d'onglet, ni montrer sa bulle, ni poser une question ; rien ne
    /// planterait, elle serait simplement inerte.
    @Test func laSurfaceDesExtensionsEstVisible() {
        #expect(répond("webExtensionController:openWindowsForExtensionContext:"))
        #expect(répond("webExtensionController:focusedWindowForExtensionContext:"))
        #expect(répond("webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:"))
        #expect(répond("webExtensionController:openOptionsPageForExtensionContext:completionHandler:"))
        #expect(répond("webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:"))
        #expect(répond("webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:"))
        #expect(répond("webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:"))
        #expect(répond("webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:"))
    }

    /// Ce qu'une extension voit d'un onglet et de la fenêtre.
    ///
    /// Tout y est facultatif : une méthode absente ne casse rien, elle rend seulement
    /// `undefined` du côté de l'extension. C'est précisément pour ça qu'on l'affirme ici —
    /// un onglet sans `url` ni `title` existe dans `browser.tabs` et n'y sert à rien.
    @Test func lesOngletsEtLaFenêtreSontVisiblesDesExtensions() {
        #expect(répond("webViewForWebExtensionContext:", Tab.self))
        #expect(répond("urlForWebExtensionContext:", Tab.self))
        #expect(répond("titleForWebExtensionContext:", Tab.self))
        #expect(répond("activateForWebExtensionContext:completionHandler:", Tab.self))
        #expect(répond("closeForWebExtensionContext:completionHandler:", Tab.self))
        #expect(répond("loadURL:forWebExtensionContext:completionHandler:", Tab.self))
        #expect(répond("tabsForWebExtensionContext:", BrowserWindow.self))
        #expect(répond("activeTabForWebExtensionContext:", BrowserWindow.self))
    }
}
