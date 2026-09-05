# Wuji

Un navigateur pour macOS, écrit en Swift et AppKit, posé sur WebKit. Apple Silicon
uniquement, macOS 26 au minimum.

Il tient en une fenêtre : une colonne d'onglets à gauche, la page à droite, et une palette
au centre quand on cherche quelque chose. Pas de barre d'outils qui s'accumule, pas de
bouton qui ne fait rien.

---

## Le dépôt

```
LICENSE CONTRIBUTING.md  GPL-3.0, et l'accord qui la rend tenable
Package.swift          une seule cible, le chemin des sources dit pourquoi
Sources/
├── App/               point d'entrée, assemblage, menus, délégués WebKit
├── Window/            la fenêtre et sa géométrie
├── Chrome/            palette, menus, bulles, panneau des espaces
│   ├── Sidebar/       la colonne : son modèle, sa disposition, ses rangées
│   └── TopBar/        la barre du haut, et l'icône d'une extension épinglée
├── WebContent/        hôte du WKWebView, certificat, favicons, menu de page
├── Extensions/        ce qui est installé sur la machine, et ce qui tourne ici
├── InternalPages/     tout ce qui s'ouvre en wuji://
│   └── Settings/      le socle, les sections, les contrôles communs
├── PublicSuffix/      la liste des suffixes, recopiée : où s'arrête « ce site »
├── Passwords/         le coffre chiffré de Wuji, et rien d'autre
├── Scripts/           scripts de l'utilisateur, guetteur d'adresse, lecture, traduction
├── Settings/ Store/ Tabs/
└── DesignSystem/      les tokens : couleurs, espacements, métriques
Resources/             Info.plist, icône
Tests/                 ce qui se vérifie sans fenêtre — à plat, sans dossier intermédiaire
build.sh check.sh run.sh dmg.sh release.sh uninstall.sh
```

Les scripts restent à la racine : ce sont les points d'entrée, et `./run.sh` se tape sans
réfléchir.

**Aucun fichier ne dépasse cinq cent quarante lignes**, et c'est une règle de travail, pas
une statistique. La colonne en faisait mille : la moitié était le dessin de ses rangées, qui
ne partage rien avec sa disposition sinon la place qu'elles y occupent. Un fichier qu'on doit
parcourir pour trouver le sujet qu'on cherche coûte à chaque lecture, et ce coût-là se paie
tous les jours pendant des années.

---

## Le construire et le lancer

```bash
./run.sh
```

Compile en release, installe dans `/Applications` et lance depuis là. **On teste où
l'application vivra** : lancée depuis `.build`, elle n'a ni la place ni l'identité qu'elle
aura chez quelqu'un, et macOS ne lui accorde pas les autorisations au même nom.

| | |
|---|---|
| `./build.sh` | assemble le paquet, sans le lancer — le seul script qui sait ce qu'il y a dedans |
| `./run.sh` | installe dans `/Applications` et lance (`debug` en argument pour l'autre configuration) |
| `./dmg.sh` | produit `Wuji.dmg` à côté, signé ad-hoc — pour soi |
| `./release.sh` | le même, **signé, notarisé et agrafé** — pour les autres |
| `./check.sh` | **tout ce qui peut se vérifier sans Xcode** : les deux configurations, les essais, le paquet |
| `./uninstall.sh` | efface l'application **et tout ce qu'elle a laissé** |

`./check.sh` mérite un mot. `swift test` a besoin du module `Testing`, livré avec Xcode
seulement : sur une machine qui n'a que les outils en ligne de commande, il échoue par « no
such module » et **aucun** essai n'est vérifié. Le piège est qu'on croit alors n'avoir rien
cassé, alors qu'on n'a rien regardé. Le script tente donc la vraie exécution, et retombe sur
un contrôle de types : les fichiers d'essai sont réécrits sans `Testing` et compilés contre
les sources. Cela ne prouve pas qu'un essai passe ; cela prouve qu'il compile encore contre
le code d'aujourd'hui — ce qui attrape tout renommage, toute signature changée, toute API
supprimée. C'est le contrôle le plus fort qu'on puisse faire ici, et l'autre option était
rien.

`./dmg.sh` signe en ad-hoc : sur une autre machine, le premier lancement demandera un clic
droit → Ouvrir. `./release.sh` fait la chaîne complète — durcissement de l'exécution,
signature horodatée, notarisation, agrafage du ticket — et produit l'image qu'on peut
donner à quelqu'un. Il refuse de commencer s'il ne trouve pas de certificat *Developer ID
Application*, plutôt que de livrer une image que Gatekeeper rejettera.

**Et les clés d'accès en dépendent.** L'API WebAuthn est bien exposée — `PublicKeyCredential`
existe, le contexte est sûr — mais `isUserVerifyingPlatformAuthenticatorAvailable()` répond
`false`, mesuré dans un `WKWebView` nu. C'est exactement ce que Google interroge avant de
proposer la clé d'accès : il voit qu'il n'y a pas d'authentificateur et bascule sur le mot
de passe. Toucher au trousseau iCloud depuis une vue web demande l'entitlement
`com.apple.developer.web-browser-public-key-credential`, qu'Apple réserve aux navigateurs
et qu'un profil de provisionnement doit porter. Il ne peut pas être ajouté d'ici là :
mesuré aussi, un paquet signé ad-hoc qui le déclare est tué au lancement (SIGKILL), là où
le même paquet sans lui démarre.

**L'incrustation vidéo, elle, a pu être rallumée** — et c'est le lecteur de la page qui la
commande, pas Wuji. Il a fallu trois mesures pour comprendre pourquoi elle ne marchait pas : `callAsyncJavaScript` ne porte pas de geste
utilisateur (`NotAllowedError`) ; `evaluateJavaScript` en force un, mais l'API répond alors
`NotSupportedError` ; et `webkitSetPresentationMode`, celle qu'emploient les contrôles de
Safari, n'est pas déclarée. La fonction est simplement éteinte pour tout ce qui n'est pas
Safari — `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` n'existe pas sur macOS.

`WKPreferences` la déclare pourtant, dans une liste que WebKit expose sous `_features` :
`PictureInPictureAPIEnabled` et `AllowsPictureInPictureMediaPlayback`, parmi cinq cent
quatre-vingt-dix-neuf autres. **C'est une API privée**, et [WebKitFeatures.swift](Sources/WebContent/WebKitFeatures.swift)
la traite comme telle : on demande à l'objet s'il répond au sélecteur, on cherche la
fonctionnalité par son nom, et l'échec est un `false` — rien ne s'allume, le navigateur se
comporte comme avant. Aucun `setValue:forKey:`, dont une clé inconnue lèverait une exception
que Swift ne sait pas rattraper.

**Le lecteur de PDF avait le même problème, et la même réponse.** Son bouton
d'enregistrement ne faisait rien : WebKit ne passe pas par `WKDownload` pour ce geste — le
document est déjà en mémoire depuis qu'on le regarde —, il appelle son délégué d'interface
avec les octets, par une méthode que `WKUIDelegate` ne déclare pas publiquement. Une
application qui ne l'implémente pas ne reçoit rien, et le bouton reste muet sans le dire.
Wuji l'implémente maintenant : le fichier arrive avec le nom que WebKit propose, à une
destination que le magasin réserve — donc jamais un fichier écrasé —, et avec sa ligne dans
la liste. Là encore le sélecteur est privé et l'échec inoffensif : WebKit demande
`respondsToSelector:` avant d'appeler, donc un renommage chez Apple rend simplement l'état
d'avant.

**Wuji ne pose pas de bouton dans sa barre pour autant.** Il en a eu un, à gauche du champ
d'adresse, et il a été retiré : la commande appartient au lecteur, où on la cherche déjà.
Allumer la fonctionnalité suffit à la rendre — le lecteur de YouTube gagne son bouton
d'incrustation, les contrôles natifs de WebKit aussi. Vérifié : la fenêtre flotte et la page
affiche « This video is playing in picture in picture ».

`uninstall.sh` mérite un mot : supprimer le dossier de l'application ne suffit pas. Les
réglages restent dans le démon des préférences, les autorisations caméra et position dans
une base du système. Un test qui repart d'un état non vide fait croire à un premier
lancement alors qu'il observe le précédent — c'est ce qui rend certains défauts invisibles
chez soi et évidents chez les autres. `--dry-run` liste sans rien toucher.

---

## Les extensions

**Wuji ne bloque plus rien de lui-même.** Il portait 260 règles écrites à la main dans le
format de `WKContentRuleList` ; elles sont sorties du dépôt. Une liste tenue à la main ne
suit pas le rythme des domaines jetables, et un navigateur qui promet une protection dont
il ne peut pas tenir le rythme promet mal. Ce travail-là est fait par des gens dont c'est
le métier, et leur travail s'installe : `Sources/Extensions` va le chercher.

### Ce qui est déjà sur la machine

Une extension pour Safari achetée sur l'App Store n'est **pas** un fichier qu'on installe :
c'est une application ordinaire, posée dans `/Applications`, qui porte l'extension dans son
paquet — un `.appex` sous `Contents/PlugIns`, avec le `manifest.json` de l'extension web
dans ses ressources. C'est ce fichier qu'on cherche, et rien d'autre : sa présence est ce
qui distingue une extension web d'une extension Safari **native**, du code compilé que
WebKit ne sait pas charger hors de Safari.

Le balayage est volontairement peu profond — `Contents/PlugIns` de chaque application, et
on s'arrête là. macOS n'enregistre une extension d'application qu'à cet endroit précis :
chercher plus loin ne trouverait que des copies inertes, au prix d'un parcours récursif de
tout `/Applications` à chaque ouverture de la page.

### Une application qui se découpe en plusieurs extensions

**C'est le cas ordinaire, pas l'exception.** Noir porte cinq `.appex` : l'extension web,
une extension Safari **native**, un gestionnaire d'intentions, un widget, des App Intents.
Safari en montre deux dans ses réglages — « Noir » et « Noir for Web Apps » —, avec leurs
icônes pour seule différence lisible. Rien dans leur nom de fichier ne les sépare : c'est le
contenu qui tranche, et il faut les deux signes : un `manifest.json` dans les ressources, et
`NSExtensionPointIdentifier` valant `com.apple.Safari.web-extension`. Le manifeste seul
laisserait passer un fichier embarqué comme simple ressource ; le point d'extension seul
manquerait les extensions décompressées, qui n'ont pas d'`Info.plist` du tout.

**Le nom vient du manifeste, traductions comprises.** Un manifeste ne se nomme souvent que
par une clé — `__MSG_extension_name__` —, résolue dans `_locales/<langue>/messages.json`.
Wuji la résout lui-même : il affiche la ligne **avant** d'avoir rien chargé, et le repli sur
le nom de l'application donnait ici une réponse fausse. Le paquet de Noir contient
« Noir for Web Apps », qui s'affichait « Noir » — c'est-à-dire sous le nom de l'*autre*
morceau de la même application. Le repli censé rendre la ligne lisible la rendait fausse.

**Ce qui est refusé est nommé à l'ajout, et n'entre pas dans la liste.** Une extension
Safari native est du code compilé, que WebKit ne charge que dans Safari ; Wuji ne peut pas la
prendre, et le taire laisse croire à un ajout raté — on a désigné l'application qu'il fallait,
et il ne s'est rien passé de lisible. L'ajout dit donc les deux moitiés : « Noir for Web
Apps » ajoutée, « Noir » non prise, avec la raison. Mais la liste, elle, ne montre que ce qui
s'active : une ligne qui ne peut ni s'activer, ni s'épingler, ni rien faire mettrait un
interrupteur qui ne commande rien à côté de ceux qui commandent. Ce qui ne vise pas le
navigateur — widgets, intentions — sort en silence dans les deux cas : le signaler ferait
passer chaque application pour un échec partiel.

**Chaque ligne porte son icône**, lue dans le manifeste (`icons`, à défaut
`action.default_icon`) et remise à la page interne en URI de données — une page `wuji://`
n'a aucun accès au disque, et ne doit pas en recevoir un pour afficher une vignette. C'est
la seule chose qui distingue deux extensions sorties du même paquet, exactement comme dans
les réglages de Safari. Quand deux d'entre elles portent en plus le même nom, le nom de leur
paquet les départage.

**Rien n'est copié.** L'extension est lue là où elle est, dans le paquet de son application
hôte. Elle suit donc ses mises à jour de l'App Store, et la retirer se fait en jetant
l'application — ce à quoi on s'attend. « Ajouter une extension… », sur `wuji://extensions`,
ouvre le sélecteur de fichiers : on désigne l'application, ou le dossier d'une extension
décompressée — celle qu'on écrit soi-même ou qu'on a tirée d'ailleurs.

### Dans la barre

La punaise de `wuji://extensions` pose l'icône d'une extension chargée dans la barre du
haut, avec l'étiquette et la pastille qu'elle donne **pour la page ouverte** : c'est ce
qu'une extension a de plus à dire qu'un bouton fixe, et l'épingler sans elles reviendrait à
poser une image morte. Un clic la déclenche, un clic droit la retire ou ouvre ses réglages.

Le bouton en forme de puzzle ne liste alors plus que les extensions **non** épinglées :
celles qui le sont ont déjà leur porte dans la barre, et deux chemins vers la même action
font un élément à l'écran pour rien. Quand tout est épinglé, il disparaît — « Extensions »
reste dans le menu Présentation et dans le sommaire des pages internes.

### Ce qu'on accorde, et quand

Une extension trouvée arrive **éteinte**. On enregistre ce qui est allumé, jamais ce qui
est éteint : le contraire aurait fait tourner du code tiers sur simple installation d'une
application dans `/Applications`.

L'activer affiche d'abord ce que son manifeste demande — les hôtes qu'elle pourra lire et
récrire, les pouvoirs qu'elle réclame — et c'est cette liste qu'on accorde. L'accord est
donné une fois, sur ce qui était affiché. Poser la question à chaque appel d'API aurait
noyé la décision sous des bulles au moment où l'on regarde une page, c'est-à-dire au pire
moment pour lire une liste d'hôtes. Ce qu'une extension demande **en plus**, après coup,
passe bien par une question, au même endroit que la caméra et la position.

Un clic sur son bouton vaut accord pour la page ouverte — `activeTab`. Le refuser
casserait la plupart des extensions sans rien protéger : sans ce geste, une extension qui
n'a demandé aucun hôte n'obtient toujours rien.

### Ce que l'extension voit de Wuji

`browser.tabs` et `browser.windows` ne sont pas des objets de WebKit : ce sont **nos**
onglets et **notre** fenêtre, vus à travers `WKWebExtensionTab` et `WKWebExtensionWindow`.
Tout y est facultatif, et `Sources/Extensions/ExtensionSurfaces.swift` ne répond qu'à ce
que Wuji sait vraiment — un onglet n'y est ni épinglé ni en mode lecture, et prétendre le
contraire ferait échouer l'appel suivant.

Le contrôleur doit être posé sur la configuration de **chaque** vue web, avant sa création.
Une vue qui ne le porte pas est invisible pour les extensions : leurs scripts de contenu ne
s'y posent pas, et l'onglet n'existe pas dans `browser.tabs`.

Même piège que pour les délégués de WebKit, et même parade : une méthode que le moteur ne
voit pas ne fait rien et ne le dit pas. `DelegateSelectorTests` demande à la classe ce que
WebKit lui demandera — c'est vérifié, pas supposé.

**Et il faut lui raconter ce qui se passe.** Les délégués répondent quand WebKit demande ;
ils ne réveillent personne. `browser.tabs.onCreated`, `onActivated`, `onUpdated`,
`onRemoved` sont des **événements** : sans les appels correspondants sur le contrôleur, ils
ne se déclenchent jamais. La conséquence n'est pas théorique — un bloqueur met à jour sa
pastille sur `onUpdated` et décide du mode de filtrage d'un site à `onActivated`. Sans ces
signaux il tourne à moitié : il bloque, mais il ne sait pas où il est, et tout ce qui vise
« la page courante » vise le vide. Chaque changement porte son drapeau plutôt qu'un
« quelque chose a changé » : une extension qui reçoit tout à chaque frappe refait à chaque
fois le travail de la page entière.

### Les pages d'une extension

Le tableau de bord d'uBlock Origin Lite, la page de réglages d'une autre : ce sont des
pages en `webkit-extension://`, et elles s'ouvrent dans un onglet comme les nôtres.

**Une telle page ne se charge pas dans n'importe quelle vue web.** Il lui faut la
configuration que son contexte fabrique — c'est par là que passent ses API `browser.*` et
l'origine sous laquelle WebKit accepte de la servir. Mesuré dans une vue ordinaire : la vue
n'annonce même pas d'adresse, l'onglet se croit vierge, la colonne le retire. On voyait
« rien ne s'est passé » là où le navigateur avait fait presque tout le chemin. La
configuration se choisit donc à la création de la vue, jamais après, et l'adresse est ce qui
la décide.

La barre nomme ces pages par leur extension. Leur hôte est l'identifiant que WebKit leur a
tiré au sort : trente-six caractères qui ne veulent rien dire et qui ressemblent à l'adresse
d'un site inconnu, là où la barre n'a qu'une question à trancher — chez qui suis-je ?

### Une conséquence qui reste

Une extension peut poser ses propres règles de contenu, et WebKit signale alors une adresse
arrêtée par le code `WebKitErrorDomain 104`. La page d'erreur le dit tel quel : la règle ne
vient pas de Wuji, elle vient d'une extension installée, et c'est là qu'elle se lève.

---

## La performance

**Ce que Wuji ne peut pas améliorer, et il vaut mieux le dire.** Le moteur est WebKit : la
vitesse à laquelle une page s'analyse, se met en page et s'exécute est celle de Safari, au
JIT près. HTTP/3, le cache arrière-avant, le chargement différé des images, les *speculation
rules* — tout cela est déjà dans le moteur et ne s'ajoute pas depuis l'application. Ce qu'un
navigateur peut faire par-dessus, c'est **ne pas se mettre en travers**, et c'est là qu'il y
avait tout à gagner.

**La colonne se reconstruisait à chaque battement de WebKit.** Adresse, titre, avancement,
favicon : des dizaines de signaux par seconde pendant qu'une page arrive, et chacun détruisait
puis recréait toutes les lignes de la colonne, vues et champs de texte compris. Le résultat
était juste, donc ça ne se voyait nulle part. Les lignes se mettent maintenant à jour sur
place ; on ne les refait que si la **forme** de la liste a changé — identité, nature,
profondeur —, et pas quand un titre bouge.

Trois autres, du même genre :

| | |
|---|---|
| Barre du haut | Elle recomposait l'adresse enrichie et remesurait le texte à chaque signal. Elle ne le fait plus que si elle a quelque chose de neuf à dire. |
| Icônes d'extensions | Les lire coûte un décodage d'image ; c'était fait à chaque signal. Une signature — identifiants, étiquettes, pastilles, adresse — dit quand il faut vraiment y retourner. |
| Scripts utilisateur | Leur corps était relu **sur le disque** à chaque navigation, dans `decidePolicyFor` — c'est-à-dire sur le chemin critique de la requête. Il tient en mémoire. |

**Au lancement.** Les observations posées avec `.initial` se déclenchaient sur une vue qui
n'avait encore ni adresse ni titre : cinq synchronisations complètes du chrome par onglet
créé, soixante-cinq pour une session de treize onglets, toutes sur du vide. Chaque chemin qui
crée un onglet finit par `activateCurrentTab`, qui synchronise une fois. Le balayage de
`/Applications` à la recherche des extensions — quelques centaines d'accès disque — est passé
hors du fil principal.

Mesuré sur une session de treize onglets, en release : **fenêtre à l'écran en 500 ms**, dont
250 ms de notre code ; 0,1 % de processeur au repos ; 7 % en pointe pendant le chargement
d'une page lourde, le rendu se faisant dans un autre processus.

**Et l'empreinte mémoire, qui est la mesure honnête** — pas le résident, qui compte les
fichiers mappés : **31 Mo** pour le navigateur, vingt-deux onglets restaurés compris. Avec
uBlock Origin Lite et Noir activés, 341 Mo, avec un pic à 796 Mo au lancement. Ce n'est pas
le navigateur qui coûte, ce sont les règles de filtrage que WebKit compile pour l'extension —
Safari paie la même chose. Le dire évite d'aller chercher la fuite là où elle n'est pas.

Un profil pris pendant le chargement d'une page lourde ne montre plus aucun de nos symboles
au-delà d'un échantillon isolé. C'est le critère : quand le navigateur n'apparaît plus dans
son propre profil, ce qui reste à gagner est dans le moteur, et le moteur est celui de
Safari.

**La poignée de main TLS ne se refait pas deux fois.** `SecTrustEvaluateWithError` valide
la chaîne entière, sur le fil principal, et il était appelé à **chaque** connexion : une
page ordinaire en ouvre des dizaines vers la même poignée d'hôtes. C'est le seul symbole à
nous qu'un profil pris pendant un chargement ait fait ressortir — vingt-six échantillons,
tous là. Le résultat est retenu par hôte pour la session, et le profil suivant n'en montre
plus aucun.

Rien n'est perdu côté sûreté, et c'est ce qui rend le cache légitime : notre évaluation ne
décide de rien. Wuji répond `performDefaultHandling`, donc **c'est WebKit qui tranche**, à
chaque fois, avec sa propre évaluation. La nôtre ne sert qu'à savoir s'il faut garder le
certificat pour la page d'erreur.

**Ce que Wuji va chercher pour son compte** — favicons, version publiée, script à installer —
passe par `Sources/Store/Fetch` et non par `URLSession.shared` : HTTP/3 tenté d'emblée plutôt
qu'après un premier échange en HTTP/2, un cache dimensionné pour des favicons, quatre
connexions par hôte au plus — restaurer trente onglets demande trente icônes d'un coup, et
sans borne elles se disputent la connexion au moment où la page qu'on regarde en aurait
besoin — et aucun témoin.

---

## Ce que le navigateur sait faire

**L'adresse est un champ, pas un texte flottant.** Elle se centrait avec le cadenas, et son
fond épousait la largeur du texte : la barre de recherche changeait donc de taille et de
position à chaque page, et n'existait qu'au survol. On ne pouvait pas la viser sans l'avoir
déjà trouvée, et deux captures du même navigateur ne montraient pas le même objet. Sa
géométrie est maintenant stable — une largeur qui ne dépend que de la fenêtre, un centre qui
ne bouge pas, un fond à demeure. Ce qui change au survol, c'est la teinte du fond et rien
d'autre ; et c'est tout le champ qui se clique, plus seulement le texte.

**Le cadenas est à gauche, et il n'en bouge plus.** Il se centrait avec l'adresse, en bloc :
il se déplaçait donc à chaque page, et d'autant plus loin que le titre était court. Un
indicateur de sécurité qui change de place demande qu'on le cherche avant de pouvoir le lire.
Sa place est réservée des deux côtés du champ, qu'il s'affiche ou non — à gauche pour qu'il
ne chevauche jamais le texte, à droite pour que l'adresse reste centrée et ne saute pas d'une
demi-largeur de cadenas entre un site et une page interne.

**Espaces et dossiers.** Les onglets appartiennent à un espace, pas à l'application. Un
espace naît privé ou ne l'est jamais : `⇧⌥N` en crée un — magasin de données éphémère, rien
sur le disque, un symbole qui ne se change pas — et il l'est jusqu'à sa fermeture.

Il y avait une bascule privé/normal ; elle mentait dans les deux sens. Le magasin de
données est choisi quand une vue web naît : « rendre cet espace privé » laissait les
onglets déjà ouverts écrire sur le disque sous un symbole qui disait le contraire, et
« rendre cet espace normal » aurait versé dans une session enregistrée ce qu'un espace
privé avait promis de ne pas garder.

**Fermer un espace ne demande plus rien.** Il y avait une confirmation, et elle se
défendait : on ferme des onglets que rien ne rouvrira. Mais un espace se ferme rarement par
accident — il faut ouvrir le panneau et viser une croix, ou taper `⌥W` —, et la question
tombait à chaque fois pour le cas où l'on se serait trompé une fois sur cent. Une interface
qui se fait oublier ne redemande pas ce qu'on vient de dire ; ce qu'on a fermé se retrouve
dans l'historique, et `session-précédente.json` garde l'état d'avant.

**Un onglet ne se ferme jamais tout seul, et c'est WebKit qui l'endort.** Wuji avait sa
mise en veille : passé un délai, un onglet qu'on ne regardait plus était vidé, son état
gardé pour le reconstruire. Elle est partie — elle obligeait l'onglet à traverser un état
où sa vue web n'a plus rien à dire, et chaque nouvel état de transition a fini par ouvrir un
trou par lequel une ligne disparaissait de la colonne.

`WKPreferences.inactiveSchedulingPolicy = .suspend` fait la même chose sans rien détruire :
une vue détachée de la hiérarchie — c'est le cas de tout onglet qu'on ne regarde pas, le
conteneur ne garde que celui du moment — voit son JavaScript et sa mise en page suspendus.
Mesuré : une page qui brûle 100 % d'un cœur tombe à 3 % en passant en arrière-plan, et
reprend là où elle en était, compteur intact, sans rechargement. Et le moteur sait ce qu'il
ne faut pas suspendre — une page qui joue du son ou qui charge n'est pas inactive, ce qui est
exactement la distinction que notre veille devait deviner et ratait quand un lecteur changeait
de piste. Un onglet qui joue du son porte toujours un haut-parleur à droite de son titre.

**Un téléchargement interrompu survit à la fermeture.** Ce qui est fini ne s'enregistre
toujours pas — le fichier est dans le Finder, et tenir la liste de ce qu'on a téléchargé un
mois plus tôt serait un journal de plus que personne n'a demandé. Mais un fichier de deux
gigaoctets coupé par un arrêt était perdu avec sa liste : le morceau reçu restait sur le
disque sans que rien ne sache à quoi il correspondait. L'inachevé revient donc, marqué
« interrompu », avec son bouton — **rien n'est repris tout seul** : reprendre deux gigaoctets
sur un partage de connexion parce que le navigateur a redémarré serait une décision qu'on n'a
pas prise. Avec les données de reprise si WebKit les a rendues, depuis le début sinon, et la
ligne le dit.

**La session d'avant est gardée.** Perdre une session est irréversible, et c'est la seule
chose ici qui le soit : l'historique se refait, les favoris sont ailleurs, un réglage se
remet ; trente onglets ouverts depuis une semaine, non. Chaque enregistrement recopie
d'abord le précédent dans `session-précédente.json`. Une écriture qui remplacerait la
session par moins — un défaut, un état transitoire attrapé au mauvais moment — devient un
`mv` au lieu d'une perte.

**Mode lecture** (`⇧⌘R`) — l'article, et rien d'autre. Il ne télécharge ni n'envoie rien :
les services de lecture différée envoient l'adresse, parfois la page entière, chez quelqu'un
pour la nettoyer ; ici la machine qui affiche est celle qui nettoie. Le bloc se choisit à sa
**densité de liens** — un menu, un pied de page, une colonne de recommandations sont faits de
liens, un paragraphe n'en a presque pas. Compter les mots seuls désignerait la colonne
latérale d'un journal. Aucun sélecteur à la mode n'est codé en dur : `.article-body` change à
chaque refonte de site, et une liste de sélecteurs est une liste à tenir à jour pour toujours.

**Traduire la page** — avec les modèles installés sur **cet appareil**. Les traducteurs des
autres navigateurs envoient le texte à un serveur : sur un article, cela révèle ce qu'on lit ;
sur un courriel ou un intranet, cela envoie le contenu à un tiers. Et rien n'est téléchargé en
douce : un couple de langues absent fait échouer la traduction et renvoie aux réglages du
système, plutôt que de déclencher un gigaoctet derrière un clic sur « traduire ».

**Enregistrer la page** (`⌘S`) — archive web pour la garder navigable, PDF pour la figer. Le
format se choisit par l'extension du nom, là où l'on décide de toute façon où le fichier va.
Le PDF est celui de la page **entière** : sans configuration WebKit ne rend que la zone
visible, et un article de trois écrans s'enregistrait coupé au milieu d'un paragraphe.

**Le zoom se voit tant qu'il dure, et à un seul endroit.** Une bulle disait ce qui venait de
changer, pas dans quel état on est : deux jours plus tard, un site qui se lit trop gros ne
s'explique plus. Un badge dans la barre du haut porte l'écart — **après les extensions
épinglées**, du côté où l'on regarde déjà quand on cherche l'état de la page — et disparaît
quand il n'y a plus d'écart. Le cliquer rend le zoom par défaut.

**L'écart se mesure au réglage par défaut, pas à cent pour cent.** Le badge s'effaçait à
100 % : quelqu'un dont le zoom général vaut 80 % voyait donc « 80 % » sur chaque page, pour
toujours — et `⌘0`, qui rend justement le zoom par défaut, laissait le chiffre à l'écran comme
si le geste n'avait pas abouti. Le badge dit ce qui *diffère* de ce qu'on a choisi ; quand
plus rien ne diffère, il n'a rien à dire. `⌘0` ne rafraîchissait d'ailleurs pas le chrome du
tout : `applySettings` change les pages, pas la barre.

**Et il est seul à le dire.** Une bulle l'annonçait en plus à chaque pression, en bas à
droite. Deux surfaces pour un seul fait, et la bulle était la moins utile des deux : elle
s'efface au bout de quelques secondes, là où le badge reste tant que l'écart dure.

Il a fait un détour par l'intérieur du champ, contre le cadenas, au motif que le zoom parle
de la page comme l'adresse. Il y était moins bien : le champ a une géométrie **stable**, et un
chiffre qui apparaît dedans décale le texte qu'on était en train de lire. Dehors, il pousse la
bordure du champ — qui bouge de toute façon avec la fenêtre.

**Zoom par site.** `⌘+` et `⌘−` règlent le site qu'on regarde, et il s'en souvient : un
site qui se lit mal n'impose pas sa correction à tout le web. `⌘0` lui rend le zoom par
défaut. Seuls les écarts sont conservés, et Réglages › Zoom par site les liste.

**Il y a un onglet d'application par espace, et un seul.** Pas un par page : **un, pour
toutes.** Les favoris, l'historique, les extensions, les réglages ne sont pas quatre
destinations, ce sont les sections d'un même endroit — elles partagent le sommaire, et y
cliquer « Historique » depuis les favoris navigue sur place. Le raccourci fait donc ce que
fait le lien, sans quoi les deux chemins d'une même intention ne mènent pas au même endroit.
Un espace finissait sinon avec quatre onglets qui affichaient la même colonne à quatre lignes
de sélection près.

Deux onglets sur la même page de l'application ne sont d'ailleurs pas deux vues, ce sont deux
vérités : elles divergent à la première modification, et la seule façon de savoir laquelle a
raison est de recharger celle qu'on regarde. L'espace courant est cherché d'abord — on y
travaille, y rester est le comportement qui ne surprend jamais ; ce n'est qu'à défaut qu'on
rejoint l'onglet ouvert ailleurs. Un espace privé n'est jamais rejoint.

**Rien n'est refermé pour autant.** Un espace hérité d'avant la règle garde ses doublons :
aucun onglet ne se ferme sans qu'on l'ait fermé, et la règle vaut aussi quand c'est le
navigateur qui aurait rangé. Le raccourci vise alors l'onglet qui affiche déjà la page
demandée. Mesuré : cinq allers-retours entre cinq de ces pages, sur un espace qui en portait
trois, laissent exactement trois onglets — aucun créé, aucun fermé.

**`⌘` change d'onglet, `⌥` change d'espace.** Les deux mêmes touches — celles à droite du P,
« ^ » et « $ » sur un clavier français —, avec l'autre modificateur. Ce sont deux raccourcis
de moins à retenir, parce que c'est une règle et non deux faits.

**Changer d'espace se voit.** La colonne entre du côté d'où vient l'espace, avec la durée et
la courbe qui servent déjà à ranger un onglet — deux mouvements qui se ressembleraient à
moitié se remarqueraient au lieu de se comprendre. Sans lui, la colonne se remplace d'un
coup et l'on ne sait pas si l'on a changé d'espace ou perdu ses onglets.

**La palette ne s'ouvre que sur trois gestes** : ⌘T, ⌘L, et le clic sur l'adresse. Elle
s'ouvrait aussi toute seule à la fermeture du dernier onglet et à la création d'un espace
privé — on venait de fermer quelque chose, et l'application répondait par un champ de saisie
qu'on n'avait pas demandé.

**Les menus sont ceux du système.** Ils l'ont été, puis ne l'ont plus été, et le
redeviennent : une feuille dessinée à la main tenait la direction artistique d'un seul
tenant, et refaisait moins bien ce que macOS fait depuis quarante ans — le repli quand la
place manque, la navigation au clavier, VoiceOver, la répétition des touches, le survol qui
traverse un sous-menu en diagonale. Un menu est le seul endroit de l'interface où
l'habitude vaut plus que la cohérence visuelle : on y vise sans lire, avec des gestes appris
ailleurs. Les invites de renommage passent par une feuille `NSAlert` sur la fenêtre, pour la
même raison.

Ce qui n'a **pas** changé : les questions que Wuji pose — caméra, position, installer un
script, autoriser une extension — restent dans la bulle en bas à droite. Elles attendent une
réponse, elles arrivent là où l'on regarde déjà, et fermer sans répondre vaut « non ». Un
menu qu'on ouvre et une question qu'on subit ne sont pas la même chose.

Les menus se déclarent en tableaux d'`ActionItem`, et un seul endroit les transforme en
`NSMenu` — raccourci compris : la chaîne affichée (« ⇧⌘T ») *est* la déclaration de la
touche, ce qui rend impossible le libellé qui ment sur ce qu'il faut taper.

**Scripts utilisateur** — installation depuis une adresse en `.user.js`, portée affichée
avant d'accepter, mise à jour à la demande. Leur icône quitte la barre quand la fonction
est éteinte.

Deux signes les reconnaissent, et ils ne disent pas la même chose. Le suffixe `.user.js`
est une **déclaration d'intention** — la convention de Greasemonkey, respectée par Greasy
Fork et OpenUserJS —, et elle court-circuite l'affichage : on n'a rien à lire, on a une
offre à accepter. Le contenu, lui, est un **constat** : une page qui se révèle être un
script utilisateur en propose l'installation par-dessus son propre code, qui reste lisible.
L'adresse ment souvent — un dépôt sert son script sous `/raw/main/loop`, un lien raccourci
perd le suffixe —, et on tombait alors sur un mur de JavaScript sans rien pour dire qu'il y
avait quelque chose à en faire.

**Un site qui ne recharge rien rejoue quand même ses scripts.** YouTube passe d'une vidéo à
la suivante par `history.pushState` : le document reste le même, aucune navigation n'a lieu,
`decidePolicyFor` n'est jamais appelé, et un script posé pour la page précédente ne se
rejoue pas. Le défaut n'était pas intermittent, il tenait à la façon d'arriver sur la page —
coller l'adresse marchait, cliquer depuis une autre vidéo non. `Sources/Scripts/RouteWatcher`
instrumente `pushState`, `replaceState`, `popstate` et `hashchange` — les quatre seules
façons de changer d'adresse sans recharger — plutôt que d'interroger `location` par un
minuteur qui arriverait toujours en retard. L'onglet retient pour quelle adresse ses scripts
ont été joués : un site qui écrit ses filtres dans l'adresse à chaque frappe n'en déclenche
pas un par caractère.

**Téléchargements.** Ils passaient à côté de deux choses que le web dit explicitement, et
les deux se sont vues au banc d'essai avant de se voir à l'usage.

`shouldPerformDownload` : un lien porteur de l'attribut `download`, ou un `blob:`/`data:`
qu'un script fait cliquer pour livrer un fichier. Sans ce test l'attribut était décoratif —
le fichier s'affichait dans l'onglet quand son type était affichable, et le nom demandé par
la page était perdu. `Content-Disposition: attachment` : `canShowMIMEType` ne répond qu'à
« saurais-je l'afficher ? », et un `text/plain` servi en pièce jointe sait s'afficher sans
devoir l'être. Sur les six formes du banc, aucune ne téléchargeait ; toutes le font.

**Deux fichiers du même nom ne se marchent plus dessus.** La déduplication regardait le
disque, où rien n'existe encore : WebKit demande la destination bien avant de créer le
fichier, donc deux téléchargements lancés dans la même seconde repartaient avec le même nom.
Seuls les téléchargements **en vol** retiennent une place — un terminé a laissé son fichier,
c'est le disque qui parle pour lui. Et une reprise reprend le même fichier : lui en chercher
un libre l'aurait fait repartir de zéro sous un nom numéroté. Le nom suggéré est réduit à son
dernier segment, sans quoi un serveur proposant `filename="../../.zshrc"` écrirait ailleurs.

Vérifié de bout en bout : quarante mégaoctets, mis en pause à mi-course, repris, arrivés
complets et en un seul fichier.

**Serveurs qui demandent qui vous êtes.** Une authentification HTTP ouvre une bulle avec
identifiant et mot de passe — au même endroit que les autres questions, en bas à droite.
**Rien n'est retenu de cette bulle-là** : ce qui y est tapé part au serveur et disparaît
avec elle. C'est l'authentification HTTP, celle du protocole ; elle n'a pas de formulaire
où l'on reviendrait.

**Les identifiants de formulaire vont dans le coffre de Wuji, et nulle part ailleurs.**

Ce README a longtemps dit l'inverse : « un navigateur qui garderait des mots de passe sans
avoir de trousseau serait le pire des deux mondes », et il rangeait donc dans celui de macOS.
C'était défendable, et cela avait un prix qu'on ne voyait pas tant qu'on ne le payait pas :
les identifiants n'étaient pas à Wuji. Ils dépendaient d'une session Apple, d'un trousseau
que le système peut redemander d'autoriser, et d'un format que Wuji ne maîtrisait pas.

Le choix a changé, et il faut dire les deux côtés.

**Ce qu'on gagne.** Un fichier, `coffre.json`, chiffré en **AES-256-GCM** avec une clé dérivée
d'un mot de passe maître par **PBKDF2-HMAC-SHA512**, 210 000 tours — la recommandation de
l'OWASP, mesurée à 120 ms sur cette machine : assez pour qu'une attaque par dictionnaire
coûte cher, assez peu pour qu'on ne la sente pas. Le sel vient de `SecRandomCopyBytes`. GCM
authentifie autant qu'il chiffre : un fichier modifié d'un octet est refusé au lieu de rendre
n'importe quoi — vérifié par un essai qui en retourne un. **La clé ne touche jamais le
disque** : elle vit en mémoire et disparaît au verrouillage. Wuji n'appelle plus le trousseau
de macOS, ni pour lire, ni pour écrire, ni pour y ranger sa propre clé — un coffre dont la
clé dort ailleurs n'est pas un coffre, c'est un renvoi.

**Ce qu'on perd, et ce n'est pas rien.** Plus de sauvegarde par Time Machine du trousseau,
plus de synchronisation iCloud, plus d'inspection par « Trousseaux d'accès ». Et surtout :
**un mot de passe maître oublié est un coffre perdu.** Il n'y a pas de récupération — c'est
ce que « chiffré » veut dire. C'est pourquoi la création demande le mot de passe **deux
fois** : une faute de frappe rendrait le coffre inouvrable sans que rien ne le signale avant
la prochaine ouverture, et cette confirmation est la seule chose qui protège de cela.

### Touch ID

Le coffre s'ouvre au doigt quand on l'allume dans Réglages › Mots de passe. **C'est un
raccourci, pas un remplacement** : le mot de passe maître reste valable, et il le faut —
ajouter ou retirer une empreinte au Mac invalide la clé confiée, et sans ce repli le coffre
deviendrait inouvrable un matin sans qu'on ait rien fait.

**Il faut dire ce que cela suppose.** Touch ID ne rend pas une clé, il authentifie. Pour
qu'un doigt ouvre le coffre, la clé doit dormir quelque part que l'Enclave sécurisée garde —
et sur macOS, cet endroit est le trousseau du système. Ce qui y va : **trente-deux octets**,
la clé du coffre, inutiles sans `coffre.json` qui est ailleurs. Ce qui n'y va jamais : aucun
identifiant, aucun mot de passe de site, aucun nom d'hôte. C'est éteint par défaut, et
l'éteindre efface l'élément.

**Deux protections, et l'interface dit laquelle s'applique.** Un élément de trousseau à
contrôle biométrique demande le droit `keychain-access-groups`, dont le groupe commence par
l'identifiant de l'équipe : `SecItemAdd` rend `errSecMissingEntitlement` (-34018) sur un
paquet signé ad-hoc, mesuré ici. La version publiée, signée Developer ID, l'obtient —
`release.sh` lit l'identifiant d'équipe dans le certificat et écrit le fichier de droits au
moment de signer. Une copie compilée localement retombe donc sur une protection plus faible :
l'empreinte est bien vérifiée par le système, mais la clé n'y est pas liée. **La ligne des
réglages l'écrit en toutes lettres** au lieu de laisser croire à l'Enclave.

Le coffre est fermé au lancement. Il ne s'ouvre pas de force : sur une page de connexion, la
complétion affiche une ligne « Déverrouiller le coffre… » — la proposition se fait là où elle
sert, sans interrompre. Une fois ouvert, la liste se rouvre d'elle-même sur le champ où l'on
était.

Trois règles tiennent le reste :

- **L'hôte vient de WebKit, jamais de la page.** `frameInfo.securityOrigin` est l'origine
  réelle du cadre qui parle ; la page ne peut pas la mentir. Si l'hôte venait de la charge
  utile, `mauvais.example` demanderait l'identifiant de la banque en s'annonçant sous son
  nom, et le navigateur le lui donnerait. C'est la seule protection qui compte.
- **Rien n'entre sans un oui, rien ne sort sans un geste.** L'enregistrement est proposé, pas
  fait. Le remplissage n'est automatique que s'il n'y a **rien à choisir** — un seul compte
  connu ; à partir de deux, c'est la complétion qui propose, et c'est vous qui choisissez,
  parce que choisir à votre place entre deux comptes, c'est vous connecter au mauvais.
- **HTTPS, sauf chez soi.** Un mot de passe proposé en clair est proposé à quiconque écoute
  le réseau. Mais la règle vise le réseau : un service hébergé sur sa propre machine —
  `localhost`, `.local`, les plages privées — n'en traverse aucun. L'exclure ferait payer la
  précaution là où elle ne protège de rien, et priverait de la fonction les seuls sites qu'on
  ne peut pas passer en HTTPS sans monter une autorité de certification pour soi.

### La complétion

Cliquer dans un champ de connexion ouvre la liste des comptes connus pour ce site, sous le
champ. Elle se filtre à la frappe — casse et accents mis de côté, les préfixes d'abord, les
correspondances au milieu ensuite, parce qu'on se souvient du domaine plus souvent que de ce
qui le précède. `↑` `↓` `↵` choisissent, `esc` referme.

**Un choix ne remplit que le champ où l'on a cliqué.** L'identifiant depuis le champ
d'identifiant, le mot de passe depuis le champ de mot de passe. Poser les deux d'un coup
écrasait une saisie en cours quand on ne venait chercher que le secret, et n'avait nulle part
où l'écrire sur une connexion en deux étapes. La conséquence est plus qu'une commodité :
choisir un compte dans le champ d'identifiant **ne sort pas le mot de passe du coffre** —
il n'est ni lu, ni envoyé à la page. Il ne le quitte que lorsque c'est le champ de mot de
passe qui a été désigné. « Remplir avec… », dans le menu du cadenas, garde les deux : ce
geste-là désigne la connexion entière et non un champ.

Sur le champ de mot de passe, l'amorce n'est plus ce qu'on tape mais l'identifiant déjà saisi
à côté : il est normalement exact, et la règle « rien à compléter » ne s'y applique donc pas —
sinon la liste se fermerait précisément au moment où l'on vient chercher le secret.

**C'est une vue de la fenêtre, pas un menu.** Un `NSMenu` — ou n'importe quelle fenêtre qui
prend le clavier — avalerait les frappes suivantes : on cliquerait dans le champ, la liste
s'ouvrirait, et taper son identifiant ne l'écrirait plus nulle part. Ici la page garde le
clavier ; la liste se filtre pendant qu'on écrit, et n'intercepte que les trois touches qui
lui appartiennent tant qu'elle est ouverte.

**Une connexion en deux étapes en profite aussi.** Google, Microsoft et beaucoup d'autres
demandent l'adresse d'abord, sur une page où `input[type=password]` n'existe pas encore.
Exiger un champ de mot de passe dans le DOM privait de complétion exactement les sites où
l'on s'en sert le plus. Ce qui remplace la preuve manquante : la déclaration du champ —
`autocomplete="username"` ou `"email"` —, la même annonce que lisent les gestionnaires de
mots de passe, et qu'une barre de recherche ne porte pas. Le remplissage suit : sans champ de
mot de passe, il écrit l'adresse seule au lieu d'abandonner.

**La page ne voit jamais la liste.** Elle est dessinée par AppKit : un site ne peut ni la
lire, ni compter ses lignes, ni deviner sous quels noms on est inscrit chez lui. Une liste
posée dans le DOM aurait rendu tout cela lisible par le premier script venu. Et elle ne
porte que des noms : le secret ne quitte le coffre qu'au moment de remplir, pour un compte
nommé — une liste qui porterait les mots de passe les mettrait à l'écran de quiconque passe
derrière, et dans la première capture d'écran.

Le coffre répond de mémoire, sans toucher au disque : il est déchiffré une fois à
l'ouverture, et une frappe n'y coûte qu'une lecture d'index — 0,2 µs, mesurée sur deux mille
identifiants.

Deux pièges de géométrie ont été payés avant d'arriver là : le zoom de page, qui décale la
carte d'un dixième de hauteur quand on l'oublie, et le sens de l'axe — `WKWebView` est une
vue *renversée*, dont l'origine est en haut comme celle du DOM. Retourner l'ordonnée à la
main y ajoutait un second retournement, et la carte s'ouvrait en miroir du champ.

### Où c'est rangé

Les réglages tiennent en huit sections, et chacune n'en montre qu'une chose : Fonctions,
Apparence, Confidentialité, Recherche, Sites web, **Mots de passe**, **Zoom par site**,
**Autorisations**. Les trois dernières étaient empilées sous « Sites web » — trois listes
sous deux réglages faisaient une page qu'on parcourait au lieu de la lire, et chacune de ces
listes peut compter des centaines de lignes. Chaque liste a son champ de filtrage, qui
travaille **dans la page** : un aller-retour par message redessinerait tout à chaque frappe.

L'interrupteur des scripts utilisateur a quitté « Fonctions » pour la page **Scripts**, avec
les scripts qu'il commande. Un réglage rangé loin de ce qu'il pilote oblige à traverser
l'application pour comprendre pourquoi rien ne s'exécute.

**Les données de sites s'effacent site par site.** Le seul geste possible était le grand
ménage : se débarrasser de ce qu'un site avait laissé obligeait à se déconnecter de tous les
autres. Confidentialité liste maintenant chaque domaine avec ce qu'il a laissé — cookies,
stockage, cache —, un champ pour le retrouver, et un bouton par ligne. Effacer une ligne
déconnecte de ce site-là, et de lui seul.

L'effacement passe par l'**enregistrement** que WebKit a rendu, jamais par un nom de domaine
qu'on lui redonnerait : c'est ce qui garantit qu'on efface exactement ce que la ligne
annonçait. Et sans confirmation, à la différence du grand ménage — celui-ci déconnecte
partout, la question s'y justifie ; une par site transformerait un rangement en
interrogatoire, et apprendrait à répondre oui sans lire.

### Entrer et sortir

**Wuji ne peut pas lire l'app Mots de passe de macOS, et aucun navigateur tiers ne le peut.** Les identifiants de
Safari et de l'app Mots de passe vivent dans le trousseau iCloud, sous des groupes d'accès
qui appartiennent à Apple — `com.apple.cfnetwork` et ses voisins. Y entrer demande un droit
`keychain-access-groups` sur un groupe d'Apple, qu'un éditeur tiers n'obtient pas. Mesuré
ici : une requête sur les éléments synchronisés rend `errSecItemNotFound`, et Wuji ne voit
que ce qu'il a lui-même rangé. Chrome et Firefox sont logés à la même enseigne.

Reste la porte que le système ouvre volontairement : **l'export**. Dans l'app Mots de passe,
*Fichier ▸ Exporter tous les mots de passe…* écrit un CSV ; « Importer… », dans Réglages ›
Mots de passe, le lit et range chaque ligne dans le coffre, chiffrée. Ce qui est importé se
comporte ensuite comme ce qu'on y a mis soi-même. **« Exporter… » fait l'inverse**, aux mêmes
colonnes : ce qui sort d'ici se relit dans Safari, Chrome ou Firefox. Un export chiffré que
seul Wuji relirait ne serait pas un export — donc il est en clair, et c'est dit au moment où
on le demande.

Un import de deux cents lignes ne chiffre le coffre **qu'une fois** : les ranger une par une
le rechiffrerait deux cents fois, pour le même résultat. Mesuré à 7 ms pour deux mille
identifiants.

Le lecteur CSV est écrit à la main, et il le fallait : un mot de passe contient des virgules,
des guillemets, parfois un retour à la ligne. Couper sur les virgules donnerait des secrets
tronqués — et un secret tronqué qui entre dans le coffre est pire qu'un import raté, parce
qu'il ne se voit qu'à la prochaine connexion. Les colonnes sont trouvées par leur **nom**
(`URL`, `Username`, `Password`, et leurs variantes chez Chrome et Firefox) et non par leur
position, que ces exports n'ont pas en commun ; sans en-tête reconnaissable, rien n'est
importé plutôt que deviné.

Deux choses sont dites avant d'écrire : combien de lignes entrent, combien sont écartées
faute d'hôte, de compte ou de secret — « 42 importés » sans reste laisse croire que le
fichier n'en contenait que 42. Et que **le fichier exporté est en clair** : Wuji ne le
supprime pas — effacer un fichier qu'on ne nous a pas demandé d'effacer est une perte de
données — il rappelle de le faire.

Réglages › Mots de passe liste ce qui est rangé — hôte et compte, jamais le secret, avec un
champ pour filtrer. « Copier » le prend dans le coffre et le met dans le presse-papiers
**sans passer par la page** : une page interne reste une page, et ce qui y entre peut en
ressortir.

**La lecture est indexée par hôte.** La complétion interroge le coffre à chaque frappe ; un
parcours du tableau coûtait 270 µs sur deux mille identifiants, mesuré, pour une réponse qui
en demande moins d'une. L'index se refait à chaque écriture — le seul instant où personne
n'attend — et la lecture est retombée à **0,2 µs**, mille fois moins.

**Le cadenas dit tout ce qu'on peut lire — en deux lignes et cinq portes.** Il menait à
trois lignes et s'arrêtait là où commencent les questions. Il a ensuite tout montré d'un
coup : onze entrées à plat, dont une empreinte de quatre-vingt-quinze caractères qui étirait
le menu jusqu'au bord de l'écran. Ce n'était pas trop d'information, c'était la mauvaise
forme — on ne lit pas un certificat en entier, on y cherche une chose.

L'essentiel se lit sans cliquer : avec qui la connexion est chiffrée, et qui atteste du
certificat. Le reste attend derrière le groupe qui le concerne — **Identité** (sujet,
organisation, les autres noms couverts, ce qui explique un cadenas sur une adresse qui n'est
pas celle du champ « délivré à »), **Validité** (dates et jours restants), **Chiffrement**
(signature, clé, numéro de série), **Empreinte SHA-256** en quatre lignes de huit octets,
comme on la compare, et **Chaîne de confiance** jusqu'à la racine. Chaque ligne se copie d'un
clic : une empreinte qu'on ne peut pas coller ailleurs ne se compare à rien.

Ce que `Security` ne rend pas est **absent** de la liste plutôt que rempli d'un tiret. Un
certificat DV n'a pas d'organisation ; afficher la ligne vide se lirait comme une ligne
fausse.

**Certificats qu'aucune autorité n'atteste.** C'est l'ordinaire d'un service qu'on héberge
soi-même, et c'était un cul-de-sac. La page d'erreur montre maintenant le certificat —
délivré à qui, par qui, jusqu'à quand, et son **empreinte SHA-256**, la seule chose qui se
compare — puis propose de continuer. L'exception vaut **pour cet hôte et cette session
seulement**, et n'est jamais écrite sur le disque : une exception TLS permanente est un
trou qu'on oublie avoir creusé.

**Téléverser un fichier.** Un champ « choisir un fichier » ouvre le panneau du système,
en feuille sur la fenêtre. C'est le seul endroit où le panneau de macOS est le bon : la
règle qui envoie les questions de Wuji dans la bulle vaut pour les questions que *Wuji*
pose, et c'est ici le navigateur de fichiers du système qu'on demande — avec ses favoris,
sa recherche et ses raccourcis.

**Autorisations par site** — caméra, micro, position. Demandées une fois, retenues,
révocables. La position passe par deux portes : le site vous demande, et macOS demande à
Wuji ; accorder la première sans la seconde donnait un refus que la page vous attribuait.

La demande caméra/micro passait par WebKit et non par Wuji : la méthode existait, compilait,
et n'était appelée par personne — la réponse n'était donc retenue nulle part. Un délégué
n'est visible du moteur que si sa signature satisfait *exactement* l'exigence du protocole,
et une signature qui s'en écarte ne produit ni erreur ni avertissement. Un test demande
maintenant à la classe ce que WebKit lui demande.

**Mises à jour.** Réglages › Fonctions demande à GitHub la dernière version publiée —
**sans identifiant, et sans dire laquelle vous utilisez** : la comparaison se fait ici.
Rien n'est téléchargé ni installé tout seul ; la page de la version s'ouvre, et vous
décidez. La vérification au lancement est **éteinte par défaut**, parce qu'une requête
automatique contredirait la phrase juste en dessous pour ceux qui ne l'ont pas lue.

**Pages internes** en `wuji://` — favoris, historique, téléchargements, listes de règles,
sites exclus, scripts, réglages — avec le même sommaire à gauche partout.

---

## Raccourcis

| | |
|---|---|
| `⌘L` | Palette — adresse, recherche, onglets ouverts |
| `⌘T` / `⌘W` | Nouvel onglet / fermer · `⇧⌘T` rouvrir le dernier fermé |
| `⌘]` / `⌘[` | Onglet suivant / précédent |
| `⌥]` / `⌥[` | Espace suivant / précédent — les mêmes touches, l'autre modificateur |
| `⌥T` / `⌥W` | Nouvel espace / fermer l'espace — `⌘` agit sur l'onglet, `⌥` sur l'espace |
| `⌘S` | Enregistrer la page — archive web ou PDF |
| `⇧⌘R` | Mode lecture |
| `⇧⌥N` / `⇧⌘N` | Nouvel espace privé / nouveau dossier |
| `⌘F` | Rechercher dans la page · `⌘G` et `⇧⌘G` pour circuler |
| `⌘R` | Recharger · `⌘+` et `⌘−` pour le zoom |
| `⌘D` / `⇧⌘B` | Mettre en favori / ouvrir les favoris |
| `⌘Y` / `⌘J` | Historique / téléchargements |
| `⌘,` | Réglages |
| `⌘M` | Minimiser la fenêtre |

---

## Ce que le projet s'interdit

- **Aucun contrôle mort.** Un réglage qui ne pilote rien est pire qu'un réglage absent : il
  donne l'illusion d'un produit plus avancé qu'il ne l'est.
- **Aucune télémétrie.** Rien ne part de cette machine que vous n'ayez demandé — la seule
  requête que Wuji émette pour son propre compte est la vérification de version, et elle
  ne se déclenche que sur un clic, sauf si vous l'autorisez au lancement.
- **Aucun mot de passe enregistré.** Stocker des identifiants demande de les remplir, et
  c'est le remplissage qui coûte : au mauvais endroit, dans un cadre tiers ou sur une
  origine voisine, il livre un mot de passe à un site qui ne l'a jamais eu. C'est la seule
  fonction où un défaut ne casse pas une page — il donne un compte. À moitié faite, elle
  serait la pire chose que Wuji puisse embarquer ; les gestionnaires de mots de passe et
  l'app Mots de passe de macOS remplissent ici comme ailleurs.
- **Une seule fenêtre, parce qu'il y a les espaces.** Ailleurs, on ouvre une seconde
  fenêtre parce que les onglets n'ont aucun autre moyen d'être groupés — c'est un
  contournement. Ici les espaces font le travail, et mieux : ils persistent, se nomment, se
  reconnaissent d'un symbole et survivent à la fermeture. Reste ce qu'ils ne savent pas
  faire — être visibles en même temps — mais ce besoin-là est étroit et le coût est le plus
  élevé de la liste : un contexte par fenêtre, et chaque surface flottante à faire suivre.
  Le jour où il faudra trancher autrement, la bonne forme sera « ouvrir *cet espace* dans
  une seconde fenêtre », pas des fenêtres génériques qui concurrenceraient les espaces.
- **Aucune suggestion du moteur de recherche.** Elles supposent d'envoyer *chaque frappe* à
  un tiers — « c », « ch », « cha » — y compris pour les recherches qu'on efface avant de
  les valider. C'est une fuite continue, pas ponctuelle. La palette cherche donc chez vous
  seulement : onglets ouverts, historique, favoris. Décidé, pas en attente.
- **Les favicons viennent du site**, jamais d'un service tiers qui apprendrait au passage
  ce que vous visitez.
- **Aucune règle écrite pour faire passer un test.** Les pages de conformité proposent
  leurs propres filtres ; les adopter donne un bon score et ne protège personne.

---

## Licence

**[GPL-3.0](LICENSE).** Copyright © 2026 Liam Jutteau (Black0S).

Wuji peut être lu, modifié et redistribué par qui veut — mais **pas fermé** : qui publie
une version modifiée doit en publier le code sous la même licence. Le travail reste ouvert
en aval, ce qu'une licence permissive ne garantit pas.

Ce choix ne l'empêche pas d'être vendu, ni de recevoir un soutien financier : « libre » n'a
jamais voulu dire gratuit. Il demande en revanche que les droits restent réunis en une
seule main, sans quoi plus personne ne pourrait relicencier — d'où l'accord de contribution
décrit dans [CONTRIBUTING.md](CONTRIBUTING.md), qui ne retire rien aux contributeurs et
laisse leur travail sous GPL-3.0 comme le reste.

**Le projet n'a aucune dépendance.** La liste des suffixes publics vient de
[swift-psl](https://github.com/ameshkov/swift-psl) et vit dans `Sources/PublicSuffix`,
recopiée avec sa licence MIT et le copyright de son auteur — compatible. Ce n'est pas une
préférence : SwiftPM range les ressources d'une dépendance **à la racine** du paquet `.app`,
et macOS refuse de signer une application qui porte quoi que ce soit à cet endroit. Le
choix était donc entre la dépendance et la distribution.

Les extensions ne sont pas non plus une dépendance : Wuji n'en embarque, n'en distribue et
n'en télécharge aucune. Il lit ce qui est déjà installé sur la machine, sous la licence de
chacune et là où son propriétaire l'a mise.

---

## L'état réel

Ce dépôt a longtemps porté une feuille de route et une spécification qui décrivaient un
produit différent — une interface qui s'escamotait, un blocage adossé au convertisseur
d'AdGuard et à ses scriptlets. Les deux ont été abandonnés à l'usage : la première parce
qu'une colonne qui se dérobe fait chercher ce qu'on veut atteindre, le second parce que
425 Mo sur le disque et trente secondes de recompilation contredisaient la sobriété
promise. Ces documents ont été retirés plutôt que maquillés.

Le blocage écrit à la main qui leur a succédé est parti à son tour, pour la même raison
qu'eux : il ne tenait pas ce qu'il laissait espérer. Les extensions le remplacent — le
travail est fait ailleurs, par des gens dont c'est le métier, et Wuji va le chercher là où
il est déjà installé.

Ce qui reste ouvert est écrit dans les commits, qui disent aussi ce qui a été mesuré pour
en décider.
