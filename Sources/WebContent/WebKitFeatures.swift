import Foundation
import WebKit

/// Les réglages de WebKit qui n'ont pas d'interrupteur public.
///
/// **L'incrustation vidéo en est un, et il a fallu le mesurer pour le savoir.**
/// `requestPictureInPicture()` répond `NotSupportedError` dans un `WKWebView` — vérifié sur
/// une page ordinaire et sur YouTube —, et l'API WebKit historique que les contrôles de
/// Safari emploient, `webkitSupportsPresentationMode`, répond faux. Ce n'est pas un défaut
/// de la page : la fonctionnalité est simplement éteinte pour tout ce qui n'est pas Safari.
///
/// `WKPreferences` la déclare pourtant, dans une liste que WebKit expose sous
/// `_features` : `PictureInPictureAPIEnabled` et `AllowsPictureInPictureMediaPlayback` y
/// figurent, parmi cinq cent quatre-vingt-dix-neuf autres.
///
/// **C'est une API privée, et il faut le dire.** Elle n'est pas documentée, Apple peut la
/// retirer, et une mise à jour de macOS peut la déplacer. D'où la forme prise ici :
///
/// - **rien n'est supposé.** On demande à l'objet s'il répond au sélecteur, et on cherche
///   la fonctionnalité par son nom dans la liste qu'il rend. Un nom qui aurait disparu ne
///   produit pas d'erreur, seulement un `false` ;
/// - **rien ne casse si elle s'en va.** L'appelant reçoit `false`, le bouton reste caché,
///   et le navigateur se comporte comme avant ;
/// - **aucun `setValue:forKey:`.** Une clé inconnue y lèverait une exception Objective-C,
///   que Swift ne sait pas rattraper — le navigateur s'arrêterait au lancement.
enum WebKitFeatures {

    /// Allume l'incrustation vidéo. Rend `true` si WebKit a accepté les deux réglages.
    @discardableResult
    static func enablePictureInPicture(on preferences: WKPreferences) -> Bool {
        enable(["PictureInPictureAPIEnabled", "AllowsPictureInPictureMediaPlayback"],
               on: preferences)
    }

    /// Allume ce que les pages savent faire pour aller plus vite, et qui leur est refusé.
    ///
    /// **Trois mécanismes, éteints par défaut hors de Safari, mesuré sur les 599
    /// fonctionnalités que `WKPreferences` déclare :**
    ///
    /// - `LinkPrefetchEnabled` — `<link rel="prefetch">`. La page dit quelle ressource elle
    ///   sait qu'on demandera ensuite ; sans lui, la balise est ignorée et la ressource est
    ///   téléchargée au moment où elle bloque l'affichage.
    /// - `SpeculationRulesPrefetchEnabled` — les règles de spéculation, ce que les sites
    ///   modernes emploient pour rendre la navigation suivante immédiate. Sans lui, un site
    ///   qui a fait ce travail ne gagne rien chez nous.
    ///
    /// **Ce que ça coûte, et il faut le dire.** Précharger, c'est demander au réseau des
    /// choses qu'on n'a pas encore réclamées. Le préchargement reste commandé par la page
    /// qu'on regarde et vise ce qu'elle sert déjà : elle n'apprend rien qu'un lien cliqué ne
    /// lui aurait appris, et rien ne part vers un tiers qui n'était pas déjà dans la page.
    /// Ce qu'on paie, ce sont des octets pour une page qu'on n'ouvrira peut-être pas.
    ///
    /// - `RequestIdleCallbackEnabled` — `requestIdleCallback`, par quoi une page reporte son
    ///   travail secondaire à un moment où le fil est libre. Éteint, les sites qui l'emploient
    ///   retombent sur un `setTimeout` qui, lui, s'exécute au pire moment.
    ///
    /// **Ce que ça coûte, et il faut le dire.** Précharger, c'est demander au réseau des
    /// choses qu'on n'a pas encore réclamées. Le préchargement reste commandé par la page
    /// qu'on regarde et vise ce qu'elle sert déjà : elle n'apprend rien qu'un lien cliqué ne
    /// lui aurait appris, et rien ne part vers un tiers qui n'était pas déjà dans la page.
    /// Ce qu'on paie, ce sont des octets pour une page qu'on n'ouvrira peut-être pas.
    ///
    /// Le **prerender** n'est pas allumé : celui-là exécute la page suivante en entier, avec
    /// ses scripts et ses mesures d'audience, pour une visite qui n'a pas eu lieu.
    ///
    /// **Et on s'arrête là.** Deux cent soixante-douze fonctionnalités sont éteintes par
    /// défaut ; beaucoup sont des propriétés CSS ou des API récentes qu'on pourrait allumer
    /// d'une ligne. On ne le fait pas : chacune change la façon dont une page se dessine, et
    /// une régression d'affichage que personne n'a mesurée coûte plus cher que la
    /// fonctionnalité ne rapporte. Celles-ci sont additives — elles n'altèrent aucun rendu.
    @discardableResult
    static func enableWebPerformance(on preferences: WKPreferences) -> Bool {
        enable(["LinkPrefetchEnabled", "SpeculationRulesPrefetchEnabled",
                "RequestIdleCallbackEnabled"], on: preferences)
    }

    /// Allume une liste, et ne rend `true` que si **toutes** ont été acceptées.
    @discardableResult
    static func enable(_ keys: [String], on preferences: WKPreferences) -> Bool {
        keys.filter { enable($0, on: preferences) }.count == keys.count
    }

    private static func enable(_ key: String, on preferences: WKPreferences) -> Bool {
        let list = NSSelectorFromString("_features")
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: list), preferences.responds(to: setter),
              let features = WKPreferences.perform(list)?.takeUnretainedValue() as? [AnyObject],
              let feature = features.first(where: { $0.value(forKey: "key") as? String == key })
        else { return false }

        // `perform` ne sait pas passer un booléen : on passe par l'invocation, qui sait.
        guard let method = class_getInstanceMethod(type(of: preferences), setter),
              let implementation = method_getImplementation(method) as IMP? else { return false }
        typealias Call = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let call = unsafeBitCast(implementation, to: Call.self)
        call(preferences, setter, true, feature)
        return true
    }
}
