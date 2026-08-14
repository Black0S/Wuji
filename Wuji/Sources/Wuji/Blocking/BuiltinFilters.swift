/// La liste de base, écrite pour ce projet.
///
/// **Elle est courte, et c'est un choix.** Une liste communautaire compte cent mille règles
/// et attrape tout ; elle vient aussi avec sa licence, ses mises à jour automatiques et ses
/// faux positifs. Ici on vise ce qui pèse : les régies publicitaires et les traceurs
/// présents sur la moitié du web. Le reste viendra d'un abonnement explicite.
///
/// Chaque ligne est au format Adblock, traduit par `FilterConverter`. Les commentaires
/// commencent par `!` — c'est le format d'origine, qu'on garde pour pouvoir copier une
/// règle depuis n'importe quelle liste existante sans la retoucher.
enum BuiltinFilters {

    static let list = """
    ! Wuji — liste de base
    !
    ! Régies publicitaires
    ||doubleclick.net^
    ||googlesyndication.com^
    ||googleadservices.com^
    ||adservice.google.com^
    ||pagead2.googlesyndication.com^
    ||amazon-adsystem.com^
    ||adnxs.com^
    ||rubiconproject.com^
    ||pubmatic.com^
    ||openx.net^
    ||criteo.com^
    ||criteo.net^
    ||taboola.com^
    ||outbrain.com^
    ||smartadserver.com^
    ||teads.tv^
    ||adform.net^
    ||casalemedia.com^
    ||3lift.com^
    ||sharethrough.com^
    ||media.net^
    ||moatads.com^
    ||serving-sys.com^
    ||advertising.com^
    ||yieldmo.com^
    !
    ! Mesure d'audience et traceurs
    ||google-analytics.com^
    ||analytics.google.com^
    ||googletagmanager.com^
    ||googletagservices.com^
    ||connect.facebook.net^
    ||facebook.com/tr
    ||scorecardresearch.com^
    ||quantserve.com^
    ||chartbeat.com^
    ||hotjar.com^
    ||hotjar.io^
    ||mouseflow.com^
    ||fullstory.com^
    ||clarity.ms^
    ||mixpanel.com^
    ||segment.com^
    ||segment.io^
    ||amplitude.com^
    ||branch.io^
    ||adjust.com^
    ||appsflyer.com^
    ||kochava.com^
    ||bat.bing.com^
    ||analytics.twitter.com^
    ||ads-twitter.com^
    ||static.ads-twitter.com^
    ||snap.licdn.com^
    ||px.ads.linkedin.com^
    ||t.co/i/adsct
    ||pinterest.com/ct.html
    ||tiktok.com/i18n/pixel
    ||analytics.tiktok.com^
    !
    ! Pixels et balises courants, quel que soit l'hôte
    /pixel.gif?
    /tracking-pixel.
    /beacon.js
    /analytics.min.js
    !
    ! Emplacements publicitaires les plus standardisés. Le masquage est volontairement
    ! avare : un sélecteur trop large fait disparaître du contenu légitime, et personne
    ! ne comprend pourquoi la page est trouée.
    ##.adsbygoogle
    ##ins.adsbygoogle
    ##iframe[id^="google_ads_iframe"]
    ##div[id^="div-gpt-ad"]
    ##div[data-ad-slot]
    ##.taboola-container
    ###taboola-below-article
    ##.OUTBRAIN
    """
}
