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

    @Test func lesMessagesDesPagesSontVisibles() {
        #expect(répond("userContentController:didReceiveScriptMessage:"))
    }
}
