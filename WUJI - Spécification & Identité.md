# WUJI — Navigateur macOS

> **無極 (wújí)** — « sans limite », l'état de simplicité indifférenciée avant que les choses ne se compliquent.

**Statut :** spécification de travail — **v0.4** · 13 août 2026
**Rôle de ce document :** le *quoi* et le *pourquoi*. Le *quand* et l'*ordre* sont dans `WUJI - Roadmap.md`.
**Plateforme :** macOS, Apple Silicon uniquement · **Langage :** Swift / SwiftUI + AppKit · **Moteur :** WebKit (`WKWebView`)

---

## 1. Le pitch

**Wuji disparaît deux fois : de l'écran, et de la machine.**

De l'écran, parce que l'interface s'efface dès qu'on ne s'en sert plus — il ne reste que la page.
De la machine, parce qu'une fonction désactivée n'existe pas : ni code chargé, ni process, ni cycle CPU, ni connexion sortante.

Aucune télémétrie. Aucune IA. Aucun cloud. macOS, natif, Swift et WebKit.

---

## 2. Les principes

### 2.1 Les cinq règles

| # | Principe | Traduction concrète |
|---|---|---|
| 1 | **Zéro interface** | L'UI est absente par défaut et apparaît à l'intention (survol, geste, raccourci). Aucun élément permanent hors du contenu. |
| 2 | **Zéro télémétrie** | Aucune requête sortante non déclenchée par l'utilisateur. Vérifiable par lui-même (`wuji://runtime`). |
| 3 | **Zéro IA, zéro cloud** | Pas d'assistant. Pas de compte. Pas de serveur Wuji. Tout dans `~/Library/Application Support/Wuji`, en fichiers lisibles et exportables. |
| 4 | **OFF = inexistant** | Une fonction désactivée ne consomme rien. Mesuré en CI, montré à l'utilisateur. |
| 5 | **Pas de surcharge visible** | Le nombre d'éléments à l'écran est un coût. Le nombre de réglages aussi. |

### 2.2 Réconcilier plusieurs modes d'onglets et « pas de surcharge »

Garder horizontal, vertical, puis Spaces, Focus et Split View **n'est pas** une contradiction — à une condition stricte : **ce sont des états mutuellement exclusifs, pas des couches empilées.**

- Un seul mode est actif à la fois. Les autres ne sont pas « masqués » : leur module n'est pas chargé (principe 4).
- Le mode se choisit dans les Réglages, une fois. **Pas de raccourci de bascule** — changer de paradigme d'affichage par accident est une mauvaise surprise, pas une fonctionnalité.
- Focus Mode n'est pas un mode d'onglets, c'est une surcouche d'attention → il se combine avec n'importe lequel.
- Les Spaces n'existent qu'en mode vertical.

**Ce qu'il faut assumer :** chaque mode est un chemin de rendu de plus pour le layout, le glisser-déposer, la restauration de session et la navigation clavier. C'est la première source de bugs du projet. La parade est architecturale et se pose dès le premier jour : **le modèle d'onglets ne connaît pas son affichage** — ordre, sélection, épinglage, coupure du son et restauration vivent dans un modèle sans notion de barre ou de sidebar, dont chaque mode n'est qu'une vue.

---

## 3. Les décisions arrêtées

| Sujet | Décision | Conséquence |
|---|---|---|
| **Quel produit ?** | **Le design gagne.** Wuji = *le navigateur qui disparaît*. L'interface invisible **est** le produit. | Tout ce qui ajoute de l'interface permanente est coupé. Les outils restent, mais discrets et à la demande. |
| **Direction artistique** | **Tout en flat.** Aucune surface translucide, aucun effet de verre. | Supprime la dépendance au flou au-dessus de `WKWebView`, où le contenu web est rendu dans un calque hors process. Moins de GPU, meilleure lisibilité, vieillit mieux. |
| **Modes d'onglets** | **Horizontal + vertical en v1.** Spaces, Split View et Focus Mode en v1.1. | Rien n'est abandonné, tout est échelonné. Le vertical arrive après validation du concept. |
| **Matériel** | **Apple Silicon uniquement.** `arm64`, pas de binaire universel. | Binaire plus léger, pas de matrice de test Intel, budget mémoire mesuré sur une seule architecture. Exclut les Mac Intel — assumé. |
| **Plancher système** | **macOS 26 minimum.** | Pour une sortie mi-2027, c'est un OS d'un an et demi, avec macOS 27 déjà disponible. Supprime tout le code de compatibilité, et le public de Wuji — celui qui choisit un navigateur pour son design — est à jour. |
| **Distribution** | **Hors App Store.** Developer ID, notarisation, mises à jour Sparkle. | Le sandbox du Mac App Store contredit trois promesses de ce document : fichiers libres dans `Application Support`, userscripts éditables dans le Finder, mises à jour automatiques. |
| **Synchro / mobile** | **Aucune synchro. Ordinateur uniquement.** | Export/import de fichier à la main. |

---

## 4. Direction artistique

> **Les planches de design sont une direction artistique, pas un cahier des charges.** Une icône dessinée ou une entrée de menu n'engage aucune fonctionnalité. Le périmètre réel est en §7.

### 4.1 Ce qui est acquis — à ne pas toucher

- **Le concept « Reveal on Intent ».** Quatre états (immersif → survol → omnibox → auto-masquage) : clair, démontrable en une capture, et personne ne le fait aussi radicalement sur macOS. C'est le produit.
- **Le logo anneau.** Enso zen, cohérent avec 無極, mémorisable en une forme, fonctionne en positif et négatif.
- **La discipline monochrome**, dans les limites de §4.3 et §4.6.
- **`wuji://` comme schéma interne.** Un espace propre aux pages internes, adressable et bookmarkable.
- **L'auto-masquage de la sidebar.** Le vertical sans la perte de place du vertical.

### 4.2 Les règles du flat

En flat monochrome, la profondeur ne peut venir que de la valeur et de l'ombre. D'où deux règles fermes :

1. **Trois niveaux d'élévation maximum** : contenu → chrome → modal. Pas un de plus.
2. **Le filet de 1 px est structurel, pas décoratif.** Une pilule blanche opaque posée sur une page blanche disparaît. Toute surface flottante porte un contour à faible opacité **et** une ombre douce.

### 4.3 Le trou du système : il n'y a pas de couleur pour dire « danger »

Le monochrome absolu est magnifique et il crée un problème de sécurité réel.

Un navigateur doit pouvoir signaler, sans ambiguïté et sans lecture : certificat TLS invalide, connexion non chiffrée, permission caméra/micro **active en ce moment**, site en liste blanche adblock, session privée. En monochrome, tout cela se ressemble.

**Une exception unique et documentée :**

- **Une seule couleur sémantique**, réservée exclusivement à la sécurité et jamais utilisée ailleurs.
- **Un liseré, pas une icône.** En mode zéro interface, l'utilisateur ne regarde pas la barre d'adresse — elle est cachée. Un fin liseré autour du contenu (rouge = non chiffré, ambre = permission active, violet discret = session privée) reste visible même UI masquée. C'est la seule solution compatible avec le concept.
- **Le liseré est par vue de contenu, jamais par fenêtre.** Le jour du Split View, deux volets dont un seul est chiffré rendent un liseré de fenêtre absurde.
- **Les couleurs des Spaces** ne peuvent pas partager le vocabulaire chromatique de la sécurité : nuances de gris + pastille de forme distincte, ou rien.

### 4.4 Contraste : trois valeurs de la palette sont sous le seuil

| Combinaison | Ratio | Verdict |
|---|---|---|
| `#8E8E93` sur `#FFFFFF` | **3,26 : 1** | ❌ Sous AA (4,5:1) pour du texte < 18 pt |
| `#8E8E93` sur `#F5F5F7` | **2,99 : 1** | ❌ Nettement insuffisant |
| `#8E8E93` sur `#000000` | 6,44 : 1 | ✅ |
| `#1D1D1F` sur `#FFFFFF` | 16,83 : 1 | ✅ |
| `#E5E5E7` sur `#000000` | 16,69 : 1 | ✅ |

Tous les libellés secondaires en mode clair sont concernés. **Le gris secondaire clair doit descendre à `#6E6E73`** — ratio 4,8:1, visuellement quasi identique, conforme.

### 4.5 Le risque « écran vide »

Au premier lancement, Wuji affiche une image et rien d'autre. Un utilisateur qui ne connaît pas les gestes ne peut ni naviguer, ni ouvrir un onglet, ni trouver les réglages. Il désinstalle en trente secondes.

**Trois garde-fous non négociables, traités comme des fonctionnalités et non comme du polish :**

1. **Premier lancement pédagogique** — trois écrans qui enseignent les trois gestes (révéler, omnibox, onglets), une seule fois, sans compte.
2. **Réglage « interface toujours visible »** — pour VoiceOver, la navigation clavier exclusive, ou les difficultés motrices avec le trackpad. L'auto-masquage est hostile à ces usages ; en faire un choix, jamais une contrainte.
3. **Respect de « Réduire le mouvement » et « Différencier sans couleur »** de macOS — les animations de révélation se désactivent, les signaux passent par la forme.

L'accessibilité n'est pas un supplément moral ici : c'est ce qui empêche le concept de se retourner contre le produit.

### 4.6 Ce que macOS impose, et qu'on ne contrôle pas

Le monochrome absolu est impossible : le système injecte de la couleur hors de portée — feux de circulation, teinte d'accentuation dans la sélection de texte et les anneaux de focus, panneaux de fichiers, menu contextuel de WebKit, et surtout **les contrôles de formulaire rendus par WebKit** (cases, menus, sélecteurs de date), qui suivent l'accent *système* et non le nôtre.

**Règle : monochrome pour le chrome, jamais pour le contenu.** Et le design system doit dire ce qui se passe quand les deux se touchent — c'est le vrai sujet, puisque le chrome ne représente que ~5 % des pixels et que les 95 % restants sont une page web qui ne coopère pas.

### 4.7 Corrections à passer dans les fichiers de design

| Où | Problème | Correction |
|---|---|---|
| Planche brand, palette light | `#F5F577` — c'est un **jaune** | `#F5F5F7` |
| Planche brand simplifiée | `#BEBE93` — c'est un **kaki** | `#8E8E93` |
| Planche « Vertical Tabs », barre d'adresse | `wuj://` | `wuji://` |
| Planche typo | « FONT **WIEGHTS** » | « FONT WEIGHTS » |
| Planche brand, features | « **Bun** custom scripts » | « **Run** custom scripts » |
| Planches brand et Vertical Tabs | « Full Sync », « Sync (Local) », bloc mobile | ❌ Supprimer — aucune synchro, pas de mobile |
| Planche 2, « Adaptive Modes » | Focus Mode rangé à côté de Light/Dark/Auto, avec un badge permanent | Focus n'est pas un thème, et un badge permanent contredit le principe 1 |
| Planche 6, arborescence Swift | `BrowserEngine.swift` | Rejoue l'argument démonté en §6.1 : renommer `WebViewHost.swift` |

**Le logo aux petites tailles.** L'anneau avec halo fonctionne à 512 px. À 16 px (favicon, barre de menus, Spotlight), le halo devient une bouillie grise et l'anneau se referme. Prévoir une **variante simplifiée** : trait plus épais, pas de halo, ouverture optique corrigée. C'est la version que les gens verront le plus souvent. L'icône d'application doit par ailleurs être construite en couches dans le format d'icône de la plateforme, pas exportée à plat.

**La planche qui manque.** Toutes les planches montrent le chrome contre des photos en noir et blanc. Il en faut une qui montre la même pilule d'adresse posée sur cinq pages réelles et laides. C'est là que le monochrome se valide ou s'effondre.

---

## 5. Design system

- **Grille 8 pt** : 4 · 8 · 12 · 16 · 24 · 32 · 40 · 48 · 64
- **Rayons** : 0 · 4 · 8 · 12 · 16 · 20 · 24
- **Élévation** : 3 niveaux, filet 1 px + ombre douce obligatoires (§4.2)
- **Typographie** : SF Pro. La police système bascule seule entre Display et Text à 20 pt — ne pas forcer un autre seuil.
- **Icônes** : trait 1,5 px, angles arrondis, monochrome. **À produire en symboles personnalisés** plutôt qu'en SVG plats : on récupère gratuitement les variantes de graisse, l'alignement optique avec le texte et la mise à l'échelle d'accessibilité. Un trait fixe casse dès qu'on agrandit le texte système.
- **Palette clair** : `#FFFFFF` · `#F5F5F7` · `#E5E5E7` · **`#6E6E73`** (secondaire, §4.4) · `#1D1D1F` · `#000000`
- **Palette sombre** : `#1C1C1E` en fond de fenêtre, `#2C2C2E`, `#E5E5E7`, `#FFFFFF`. **`#000000` est réservé au vide immersif** — blanc pur sur noir pur fait baver le texte.
- **À créer** : la couleur sémantique de sécurité (§4.3) et les six états manquants — focus clavier, survol, pressé, désactivé, erreur, vide.

---

## 6. Architecture

### 6.1 Organisation du code

Le découpage classique `Core / UI / Features / System` est écarté. Il range par **nature de code** ; Wuji a besoin d'un rangement par **module**, pour une raison précise : le principe 4 exige qu'une fonctionnalité se désactive **en bloc**. Un module éparpillé sur quatre dossiers ne peut pas garantir qu'il ne reste rien de vivant. `Core` et `System` deviennent par ailleurs systématiquement des dépotoirs, faute de définition.

```
Wuji/
├── App/                    # cible app : NSApplication, fenêtre, menus, assemblage
├── Packages/
│   ├── WujiKit/            # modèle d'onglets, session, réglages, protocole Module
│   ├── DesignSystem/       # tokens, couleurs, symboles, composants flat
│   ├── WebHost/            # WKWebView : configuration, navigation, permissions
│   ├── Store/              # SQLite, fichiers, migrations
│   ├── Chrome/             # révélation, omnibox, liseré de sécurité
│   ├── TabsHorizontal/     # une vue du modèle
│   ├── TabsVertical/       # une autre vue du même modèle
│   ├── History/  Bookmarks/  Downloads/
│   ├── AdBlock/  Privacy/
│   └── InternalPages/      # wuji://runtime, erreurs, interstitiels
└── Design/                 # planches, tokens source, icônes
```

**Trois règles.**

1. **Les dépendances vont dans un seul sens** : les modules dépendent de `WujiKit` et `DesignSystem`, jamais l'inverse, et **jamais un module d'un autre module**. En paquets locaux séparés, ce n'est plus une convention de revue — c'est le compilateur qui refuse.
2. **`TabsHorizontal` et `TabsVertical` ne peuvent pas se voir.** C'est la garantie mécanique du modèle découplé de son rendu (§2.2) : aucun mode ne peut se mettre à dépendre de l'autre par accident.
3. **Noms bannis** : `Core`, `Utils`, `Helpers`, `Common`, `Managers`. Ce sont les endroits où la responsabilité disparaît.

**Ne pas créer les quinze paquets au premier jour** — Xcode devient pénible à ce rythme. Démarrer avec quatre (`App`, `WujiKit`, `DesignSystem`, `Store`) et **extraire un paquet le jour où un module doit devenir désactivable**. La structure suit le besoin, elle ne le précède pas.

Bénéfice secondaire : chaque paquet a sa propre cible de tests. Tester l'adblock ne demande pas de lancer le navigateur.

### 6.2 Ce qui est réellement sous contrôle

| Couche | Technologie | Contrôle |
|---|---|---|
| Interface (chrome, onglets, omnibox, réglages) | SwiftUI + AppKit | **Total** |
| Hôte du contenu | `WKWebView` | Configuration seulement |
| Rendu, layout, JS, compositing | WebKit / JavaScriptCore | **Aucun** |
| Réseau du contenu web | Pile réseau WebKit | **Quasi aucun** |
| Modules Wuji isolés | Services XPC à la demande | **Total** |
| Persistance | SQLite + fichiers plats | **Total** |

**L'argument technique se formule ainsi :** *« interface 100 % native, aucune couche web dans l'application elle-même »*. C'est vrai, vérifiable, et ça reste un argument de performance — pas d'Electron, pas de runtime JS pour l'UI. Ce n'est **pas** « moteur maison » ni « accélération Metal » : `WKWebView` compose déjà via Core Animation, hors de notre contrôle.

### 6.3 « OFF = inexistant », concrètement

1. **Modules à cycle de vie explicite** — `activate()` / `deactivate()`. Désactivé : aucun objet instancié, aucun timer, aucun observateur, aucun `WKUserScript` injecté, aucun fichier ouvert. Les modes d'onglets non sélectionnés en font partie.

   ```swift
   public protocol Module: AnyObject {
       static var identifier: ModuleID { get }
       init(host: ModuleHost)
       func activate() throws
       func deactivate()
   }
   ```

   Le module n'est **instancié qu'à l'activation** — la désactivation le libère entièrement, elle ne le met pas en veille. `ModuleHost` est la seule surface par laquelle un module touche le reste de l'app : pas de singleton, pas d'accès global, donc rien qui puisse survivre à la libération.

2. **XPC ciblé, jamais systématique** — uniquement pour ce qui est lourd ou risqué : compilation des listes de filtres, traitement d'images, parsing de contenu distant. Lancé pour la tâche, terminé ensuite. Multiplier les process est contre-productif : chacun coûte 5–20 Mo et de la latence.
3. **Budget mesuré en CI** — *tous modules désactivés, un onglet vide : < 120 Mo RSS, < 0,1 % CPU au repos.* Sans chiffre testé, « ultra performance » n'est pas vérifiable — et `wuji://runtime` l'affiche à l'utilisateur.

### 6.4 Stockage

```
~/Library/Application Support/Wuji/
├── settings.plist          # préférences, modules actifs, mode d'onglets
├── spaces.sqlite           # onglets, sessions, Spaces (v1.1)
├── history.sqlite          # rétention configurable, purge auto
├── bookmarks.sqlite
├── filters/                # listes brutes + règles compilées
├── userscripts/            # fichiers .user.js éditables hors de Wuji
└── profiles/               # WKWebsiteDataStore par profil (v1.1)
```

Tout doit rester lisible et exportable sans Wuji. C'est ce qui rend « vos données vous appartiennent » vrai plutôt que déclaratif — et c'est la raison de rester hors du Mac App Store.

---

## 7. Le périmètre v1

Le calendrier et l'ordre sont dans `WUJI - Roadmap.md`. Ici, seulement le contenu.

**Le noyau — c'est le produit**
Zero Interface (les 4 états) · Omnibox `⌘L` (suggestions, historique, favoris, onglets ouverts, moteurs) · liseré de sécurité + permissions par site · premier lancement pédagogique · réglage « interface toujours visible » · respect des réglages d'accessibilité macOS

**Les onglets**
Mode horizontal · mode vertical + sidebar auto-masquée · états épinglé / muet / en chargement · restauration de session à chargement différé

**Le socle — invisible, obligatoire, à minimiser**
Historique · favoris + import · téléchargements · réglages · thème clair/sombre/auto · trousseau système · PDF · zoom par site · impression · mode bureau · interstitiel certificat · pages d'erreur · mises à jour

**La sobriété — le second pilier de l'identité**
Adblock (`WKContentRuleList`, listes découpées sous les 150 k règles, blocage cosmétique, liste blanche) · session privée · anti-tracking (nettoyage d'URL, `Sec-GPC`, ITP) · `wuji://runtime` · Cookie Eraser (garder / effacer à la fermeture / bloquer) · notifications discrètes

**Le confort quasi gratuit**
Find in page · gestes trackpad · bangs · `⌘⇧C` copie titre + URL + sélection en Markdown · nettoyage d'URL à la copie · PiP natif

**v1.1** — Spaces · onglets groupés · Split View · Focus Mode · profils
**v1.2** — Userscripts · sélecteur d'élément → filtre · mode lecture · aperçu de lien au survol · capture d'écran · fermeture des onglets dormants

---

## 8. Ce qui est coupé, et pourquoi

> La partie la plus utile de ce document. Une décision sans sa justification écrite se reprend toujours.

| Coupé | Pourquoi |
|---|---|
| **Extensions** | Orion a des années d'avance ; le terrain n'est pas là. Décision assumée. |
| **Synchronisation, iCloud, mobile** | Pas de serveur, pas de compte, pas de cloud. Export/import de fichier à la main. |
| **Notes intégrées** | Six planches de produit dessinées, les notes n'y apparaissent nulle part. Ce n'est pas Wuji. → Remplacé par `⌘⇧C` vers l'app de notes de l'utilisateur : même bénéfice, zéro dette. |
| **Inspecteur web maison et « Dev Features »** | Un inspecteur est l'antithèse d'une interface qui disparaît. → Remplacé par une case « Autoriser l'inspection Safari » dans Réglages › Avancé : une ligne de code, l'inspecteur d'Apple gratuit et à jour. |
| **Sélection et cache DNS** | Techniquement inaccessible depuis `WKWebView`. Les alternatives sont system-wide et contredisent l'identité. |
| **Mode sombre forcé sur les sites** | C'est Dark Reader : des années de travail, imparfait partout. |
| **Gestionnaire de cookies en tableau** | Trop d'interface pour trop peu d'usage. → Réduit à Cookie Eraser + trois règles par site. |
| **« Détection intelligente » de publicités** | Jamais spécifiée. Le blocage cosmétique couvre le besoin réel. |
| **Double UI native / nouvelle** | Doubler la surface de bugs pour un bénéfice nul. |
| **Metal comme pilier d'architecture** | `WKWebView` compose déjà hors de notre contrôle. Metal reste pertinent pour l'UI et le post-traitement des captures — pas comme argument de rendu web. |
| **« Séparer en multiples sous-process »** | Chaque process coûte 5–20 Mo et de la latence IPC. → Modules paresseux + XPC ciblé (§6.2). |
| **Raccourci `⌘⇧S` de bascule de mode** | Changer de paradigme d'affichage par accident. → Réglage uniquement. |
| **IA, assistant, télémétrie, compte** | Un navigateur affiche des pages. |

---

## 9. Identité — texte final

> ## Wuji — Designed to Disappear
>
> **De l'écran.** L'interface s'efface dès que vous n'en avez plus besoin. Il ne reste que la page.
> **De la machine.** Une fonction désactivée n'existe pas : pas de code chargé, pas de process, pas un cycle CPU.
>
> - **Zéro télémétrie.** Aucune connexion que vous n'avez pas déclenchée — et une page pour le vérifier vous-même.
> - **Zéro IA.** Un navigateur affiche des pages.
> - **Zéro cloud.** Pas de compte, pas de serveur, pas de synchronisation. Vos données restent sur votre Mac, dans des fichiers que vous pouvez lire et emporter.
> - **100 % natif.** Swift et WebKit. Aucune couche web dans l'application elle-même.
