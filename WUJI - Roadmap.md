# WUJI — Feuille de route v1

**Statut :** roadmap de travail — **v1.0** · 13 août 2026
**Document parent :** `WUJI - Spécification & Identité.md` (v0.3)
**Portée :** de zéro à la v1.0 publique.

---

## 0 bis. Ce qui a réellement été construit *(15 août 2026)*

> Ce document reste la feuille de route d'origine. Il est conservé tel quel, mais **trois de
> ses hypothèses sont fausses aujourd'hui**, et lire la suite sans le savoir induit en
> erreur. Les corriger en silence effacerait la trace de décisions qui ont été prises pour
> de bonnes raisons ; elles sont donc listées ici, pas réécrites plus bas.

**1. L'auto-masquage n'existe pas, et le geste de révélation non plus.** Le produit décrit
en J0 semaine 2, en J2 (« les quatre états ») et en risques §240–241 a été abandonné à
l'usage : une sidebar qui se dérobe fait chercher ce qu'on veut atteindre. Ce qui l'a
remplacé est plus banal et se vit mieux — une sidebar permanente, des espaces avec leurs
dossiers, et une palette au centre de l'écran. Tout le vocabulaire « Zero Interface » de ce
document s'applique donc au chrome (peu d'éléments, aucun doublon, rien de mort), pas à un
mécanisme d'escamotage.

**2. Le blocage est plus simple que ce qui était budgété, pas plus riche.** L'hypothèse §16
prévoyait des listes téléchargées et converties. Wuji est passé par là — convertisseur
d'AdGuard, scriptlets, 304 000 règles en vingt-deux tranches compilées — puis en est
revenu : 425 Mo sur le disque et trente secondes de recompilation contredisaient la
sobriété que le produit promet. Il livre maintenant **127 règles écrites directement dans
le format de `WKContentRuleList`**, dans son propre paquet. Rien n'est téléchargé, rien
n'est converti au démarrage, il n'y a plus de catalogue ni d'abonnement, et le découpage en
tranches a disparu avec eux. La dépendance à AdGuard est partie aussi, **et l'obligation
GPL-3 avec elle**.

**3. Ce que ce choix coûte est écrit dans le produit.** Les règles ne visent que des
domaines : les publicités servies depuis le domaine du site lui-même — YouTube au premier
chef — passent. Seuls les scriptlets les atteignaient, et les suivre demande une course
quotidienne que deux fichiers maintenus à la main ne tiendront pas. C'est dit sur
`wuji://settings/features`, pas seulement ici.

**4. Ce qui reste hors d'atteinte est mesuré, pas supposé.** WebKit accepte une action
`redirect` à la compilation et l'ignore à l'exécution ; `modify-headers` est refusé
d'entrée. Donc `$replace`, `$csp` et `$removeparam` ne sont pas faisables — quel que soit le
format d'écriture.

Le reste — espaces privés, journal de blocage, scripts utilisateur, autorisations par site,
mise en veille des onglets — a été construit hors de ce plan, dans l'ordre où l'usage l'a
réclamé.

---

## 0. Hypothèses de ce document

Ces trois choix conditionnent tout ce qui suit. S'ils changent, la roadmap change.

| Hypothèse | Choix | Ce que ça engage |
|---|---|---|
| **Modes d'onglets** | **Horizontal et vertical en v1.** Spaces, Split View et Focus Mode en v1.1. | Deux modes mutuellement exclusifs, choisis une fois dans les Réglages — pas de raccourci de bascule (changer de paradigme d'affichage par accident est une mauvaise surprise). Coût : +1,5 mois (jalon J2b) et la première source de bugs du projet, à budgéter comme telle. La sidebar auto-masquée est le mode vertical sans la perte de place du vertical — c'est ce qui le rend cohérent avec Zero Interface. |
| **Adblock** | `WKContentRuleList` natif, listes découpées pour passer sous la limite de 150 k règles par liste, + blocage cosmétique par CSS injecté. | Effort **M** au lieu de **L**. Le blocage passe dans le process réseau de WebKit : plus rapide et plus sobre qu'un moteur maison. Contrepartie : pas de règles procédurales avancées. |
| **Distribution** | Hors App Store — Developer ID, notarisation, mises à jour Sparkle. | Le sandbox du Mac App Store contredit trois promesses déjà écrites : fichiers libres dans `Application Support`, userscripts éditables dans le Finder, mises à jour automatiques. Décision d'architecture, pas décision commerciale. |
| **Matériel** | **Apple Silicon uniquement.** `arm64`, pas de binaire universel, pas de Rosetta. | Binaire deux fois plus léger, pas de matrice de test Intel, mémoire unifiée assumée (le budget des 120 Mo se mesure sur une seule architecture). Exclut les Mac Intel — assumé : le public de Wuji est celui qui choisit un navigateur pour son design, il est à jour. Fixe aussi le plancher système haut, donc moins de code de compatibilité. |

**Direction artistique arrêtée : tout en flat.** Aucune surface translucide, aucun effet de verre. Trois niveaux d'élévation maximum (contenu → chrome → modal). Toute surface flottante porte un filet de 1 px à faible opacité + une ombre douce — sinon elle disparaît sur une page de la même valeur.

**Base d'estimation :** une personne à plein temps, maîtrisant Swift. Ajuster proportionnellement.

---

## 1. Vue d'ensemble

| Jalon | Durée | Livrable | Ce qu'on prouve |
|---|---|---|---|
| **J0 — Spike** | 3 sem | prototype jetable | Que l'interface qui disparaît est vivable |
| **J1 — Socle nu** | 3,5 mois | build interne | Que c'est un navigateur |
| **J2 — Le concept** | 2 mois | **v0.1 privée** | Que c'est *Wuji* |
| **J2b — Le mode vertical** | 1,5 mois | build interne | Que deux modes cohabitent sans se marcher dessus |
| **J3 — La sobriété** | 2 mois | **v0.9 bêta publique** | Que la promesse de sobriété est vérifiable |
| **J4 — Finition** | 1,5 mois | **v1.0** | Que c'est livrable |

**Total : 10,5 à 11,5 mois.** Départ août 2026 → **v1.0 visée juin–août 2027**.

Deux voies parallèles tout du long : **dev** et **design**. La voie design a toujours un jalon d'avance — c'est la condition pour ne jamais coder à l'aveugle.

---

## 2. J0 — Spike *(3 semaines, code jetable)*

> **But :** répondre à quatre questions binaires avant d'engager huit mois. Ce code n'ira pas en production et ne doit pas être écrit comme s'il y allait.

### Semaine 1 — les trois vérifications de fenêtre

| # | Question | Réponse attendue |
|---|---|---|
| 1 | Peut-on faire un `WKWebView` bord à bord, sans barre de titre, avec des feux de circulation qui s'escamotent proprement ? | `NSWindow` en `.fullSizeContentView` + titre transparent + masquage des boutons standard |
| 2 | Peut-on dessiner un liseré fin autour du contenu, animable, sans décaler la mise en page de la page ? | Vue de recouvrement au-dessus du web view, ou couche sur la vue parente |
| 3 | Le chrome flat opaque reste-t-il lisible sur cinq pages réelles très différentes ? | Filet + ombre suffisent, ou il faut plus de contraste |

### Semaine 2 — le geste, seul vrai inconnu

Le problème est identifié et il n'a pas de solution évidente : **deux doigts vers le haut sur trackpad, c'est le défilement de la page.** Le geste « swipe ↑ pour révéler » des maquettes entre en collision frontale avec la lecture. De même, ←/→ est déjà pris par `allowsBackForwardNavigationGestures` de WebKit, que beaucoup de sites captent.

Prototyper les quatre candidats et les vivre, pas les juger sur le papier :

- **A.** Overscroll — le rebond en haut de page révèle. *Élégant, mais mort sur une page non défilable.*
- **B.** Trois doigts. *Libre, mais inconnu du grand public et en conflit avec Mission Control chez certains.*
- **C.** Curseur poussé vers le bord haut. *Fonctionne aussi à la souris — argument fort.*
- **D.** Raccourci clavier seul, geste abandonné.

**Décision attendue en fin de semaine 2, écrite dans la spec.** Le repli sûr est C + raccourci ; A est le plus beau si la mesure le permet.

### Semaine 3 — le vivre

Utiliser le prototype comme navigateur principal cinq jours. Noter chaque friction dans un journal brut.

**Critères de sortie de J0 :**
- [ ] Les 3 questions de fenêtre ont une réponse écrite, avec le code minimal qui le prouve
- [ ] Le geste de révélation est tranché et documenté
- [ ] 5 jours d'usage réel, journal de frictions rédigé
- [ ] Verdict explicite : **on continue / on ajuste le concept / on l'abandonne**

> Si le verdict est « inconfortable », on l'a appris en trois semaines. C'est la seule raison d'être de ce jalon.

### Voie design, en parallèle de J0

- **La planche manquante** : la même pilule d'adresse posée sur cinq pages réelles et laides. C'est là que le monochrome se valide ou s'effondre.
- Palette corrigée : `#F5F5F7`, `#8E8E93`, gris secondaire clair à **`#6E6E73`** (le `#8E8E93` sur blanc est à 3,26:1, sous le seuil AA).
- Règle du noir : `#1C1C1E` en fond de fenêtre sombre, `#000000` réservé au vide immersif. Blanc pur sur noir pur fait baver le texte.
- Les six états manquants : focus clavier, survol, pressé, désactivé, erreur, vide.
- **La couleur sémantique de sécurité** — une seule, jamais utilisée ailleurs.

---

## 3. J1 — Socle nu *(3,5 mois)*

> **But :** un navigateur complet et ennuyeux, avec un chrome classique **permanent**. Le concept vient après, par-dessus.
> **Règle de conduite : zéro innovation ici.** Schémas les plus bêtes possibles, aucune expression, tout le soin est réservé à J2.

### Architecture posée dès maintenant

Cinq choses coûtent dix fois plus cher si on les rétrofite. Elles sont écrites en J1 même si l'UI ne sort qu'en J2b ou plus tard :

1. **Cycle de vie explicite des modules** — `activate()` / `deactivate()`. Désactivé = aucun objet, aucun timer, aucun observateur, aucun `WKUserScript`. C'est le principe « OFF = inexistant », et il est inimplantable après coup.
2. **Le modèle d'onglets ne connaît pas son affichage.** Ordre, sélection, épinglage, coupure du son, restauration : tout vit dans un modèle sans la moindre notion de barre horizontale ou de sidebar. Les deux modes de v1 en sont deux vues, et Spaces/Split View en seront deux de plus. C'est **la** condition pour que J2b fasse 1,5 mois et non 3 — écrire le modèle en pensant « une barre en haut » condamne à tout reprendre.
3. **Abstraction du magasin de données** — `WKWebsiteDataStore` paramétrable dès le départ. Sert à la session privée (J3) et aux profils (v1.1). Écrit une fois, pas deux.
4. **Restauration de session à chargement différé** — à la restauration, seul l'onglet actif charge ; les autres ne sont que des titres jusqu'au clic. Rétrofiter le chargement différé sur un restaurateur existant coûte plus cher que de le concevoir ainsi.
5. **Le liseré de sécurité est par vue de contenu, jamais par fenêtre.** En v1 il n'y a qu'un volet, donc ça ne se voit pas — mais le jour du Split View, deux volets dont un seul est chiffré rendent un liseré de fenêtre absurde. Deux heures maintenant, deux semaines plus tard.

### Contenu

| Lot | Détail |
|---|---|
| **Onglets** | Barre horizontale, création/fermeture/réordonnancement, restauration de session, récupération après plantage |
| **Navigation** | Barre d'adresse classique, retour/avant/rechargement, historique de navigation |
| **Historique** | SQLite, recherche, rétention configurable, purge automatique |
| **Favoris** | SQLite, dossiers, **import via le format Netscape HTML** (couvre Safari, Chrome, Firefox en une centaine de lignes) |
| **Téléchargements** | File d'attente, reprise, révélation dans le Finder. *Le poste le plus coûteux du socle, ne pas le sous-estimer.* |
| **Permissions par site** | Caméra, micro, localisation, notifications. **C'est la justification n°1 de la couleur sécurité** — le liseré n'a rien à signaler sans lui. |
| **Sécurité** | Interstitiel certificat invalide, page d'erreur réseau, indicateur de chiffrement |
| **Divers système** | PDF (gratuit dans WebKit), zoom par site, impression, trousseau système, mode bureau |
| **Réglages** | Fenêtre complète, thème clair/sombre/auto |
| **Stockage** | `~/Library/Application Support/Wuji/` — tout lisible et exportable sans Wuji |
| **Mises à jour** | Sparkle, canal de test |

**Critères de sortie de J1 :**
- [ ] 30 jours d'usage quotidien sans perte de données
- [ ] L'import des favoris fonctionne depuis Safari, Chrome et Firefox
- [ ] Après un `kill -9`, la session revient à l'identique
- [ ] Un onglet désactivé n'instancie rien — vérifié au profileur, pas cru sur parole

### Voie design, en parallèle de J1

Dessiner **J2**, jamais J1 : les quatre états de révélation en détail (seuils, délais, hystérésis), l'omnibox et ses états, le liseré de sécurité et son vocabulaire, les trois écrans de premier lancement. Plus les tokens figés — grille 8 pt, rayons, typographie — et le jeu d'icônes en symboles personnalisés plutôt qu'en SVG plats, pour récupérer gratuitement les variantes de graisse et la mise à l'échelle d'accessibilité.

---

## 4. J2 — Le concept *(2 mois)* → **v0.1 privée**

> **But :** Wuji devient Wuji. Le chrome permanent de J1 apprend à disparaître.

| Lot | Détail |
|---|---|
| **Zero Interface** | Les quatre états : immersif → révélation → omnibox → auto-masquage. Seuils, délais, hystérésis, réglages de délai. C'est le produit — c'est ici que passe le budget de soin. |
| **Omnibox `⌘L`** | Le point d'entrée unique quand l'UI est cachée. Suggestions, historique, favoris, **onglets déjà ouverts**, moteurs de recherche. Doit être excellent, pas correct. |
| **Gestes** | La solution tranchée en J0. Plus ←/→ historique si le conflit WebKit est gérable. |
| **Liseré de sécurité** | Branché sur les permissions et le chiffrement de J1. Rouge = non chiffré, ambre = permission active. Visible même UI masquée — c'est sa raison d'être. |
| **Premier lancement** | Trois écrans, une seule fois, sans compte. Enseignent révéler / omnibox / onglets. |
| **Accessibilité** | Réglage **« interface toujours visible »**, respect de « Réduire le mouvement » et « Différencier sans couleur », navigation clavier complète, VoiceOver sur tout le chrome. Traité comme une fonctionnalité, pas comme du polish : sans ça le concept se retourne contre le produit. |
| **Find in page** | Overlay `⌘F`. Effort faible, présence indispensable. |

**Critères de sortie de J2 :**
- [ ] **Le test des deux minutes** : une personne qui n'a jamais vu Wuji ouvre un site, un deuxième onglet et trouve les réglages en moins de deux minutes, sans aide. Trois personnes différentes.
- [ ] Le liseré est compris sans explication par ces mêmes personnes
- [ ] Wuji navigable au clavier seul, de bout en bout
- [ ] Wuji est ton navigateur principal depuis 30 jours

> C'est le seul jalon où l'on a le droit de dépasser. Si l'auto-masquage n'est pas juste, rien de ce qui suit n'a de valeur.

---

## 5. J2b — Le mode vertical *(1,5 mois)*

> **But :** ajouter le second mode d'onglets **après** que le concept soit validé, jamais avant. Isolé volontairement : si ce jalon dérape, la v0.1 existe déjà et reste livrable.

### La règle qui rend deux modes tenables

Les deux modes sont **des états mutuellement exclusifs, pas des couches empilées.** Un seul est actif à la fois, et l'autre n'est pas « masqué » : son module n'est pas chargé (principe 4). Le mode se choisit dans les Réglages, une fois. **Pas de raccourci de bascule** — changer de paradigme d'affichage par accident est une mauvaise surprise, pas une fonctionnalité.

| Lot | Détail |
|---|---|
| **Sidebar verticale** | Liste d'onglets, réordonnancement par glisser-déposer, largeur ajustable, sélecteur de mode dans les Réglages |
| **Auto-masquage de la sidebar** | Le vertical sans la perte de place du vertical. Révélation au survol du bord, sur les mêmes seuils et la même hystérésis que le chrome de J2 — c'est le même comportement, pas un second système. |
| **États d'onglet** | Épinglé, muet, en chargement. Modèle commun aux deux modes, rendu propre à chacun. *(« Groupé » part avec les Spaces en v1.1.)* |
| **Navigation clavier** | Suivant/précédent, toutes fenêtres, recherche d'onglets. Un seul jeu de raccourcis pour les deux modes. |
| **Le point dur** | Le glisser-déposer, la restauration de session et le focus clavier ont deux chemins de rendu. C'est ici que se logeront les bugs — prévoir la moitié du temps en tests croisés, pas en écriture. |

**Critères de sortie de J2b :**
- [ ] Le même scénario complet (ouvrir, réordonner, épingler, couper le son, fermer, restaurer après plantage) passe à l'identique dans les deux modes
- [ ] Basculer de mode dans les Réglages ne perd aucun onglet ni aucun ordre
- [ ] Le mode inactif n'instancie rien — vérifié au profileur
- [ ] 15 jours d'usage quotidien en vertical, 15 jours en horizontal

---

## 6. J3 — La sobriété *(2 mois)* → **v0.9 bêta publique**

> **But :** rendre la promesse de sobriété vérifiable par l'utilisateur, pas déclarative.

| Lot | Détail |
|---|---|
| **Adblock** | `WKContentRuleList`, listes découpées sous les 150 k règles, compilation en tâche de fond, blocage cosmétique par CSS, liste blanche par site |
| **Session privée** | `WKWebsiteDataStore.nonPersistent()` — l'abstraction est déjà là depuis J1 |
| **Anti-tracking** | Nettoyage des paramètres d'URL (`utm_*`, `fbclid`, `gclid`), en-tête `Sec-GPC`, ITP au maximum |
| **`wuji://runtime`** | La preuve : modules actifs, mémoire, CPU au repos, journal des requêtes bloquées, connexions sortantes. Page interne, invisible jusqu'à demandée. |
| **Cookie Eraser** | Trois règles par site : garder / effacer à la fermeture / bloquer. Pas de tableau de gestion. |
| **Notifications discrètes** | Toasts : pub bloquée, téléchargement terminé, session privée |
| **Budget de performance en CI** | *Tous modules désactivés, un onglet vide : < 120 Mo RSS, < 0,1 % CPU au repos.* Sans chiffre testé, « ultra performance » n'est pas un argument. |

**Critères de sortie de J3 :**
- [ ] Le budget CI passe, et `wuji://runtime` affiche les mêmes chiffres à l'utilisateur
- [ ] **24 h de capture réseau, zéro requête sortante non déclenchée par l'utilisateur**
- [ ] L'adblock passe une suite de pages de référence, comparée à uBlock Origin
- [ ] 20 testeurs externes, un canal de retours ouvert

---

## 7. J4 — Finition et sortie *(1,5 mois)*

| Lot | Détail |
|---|---|
| **Le confort quasi gratuit** | Bangs dans l'omnibox · `⌘⇧C` copie titre + URL + sélection en Markdown · nettoyage d'URL à la copie · PiP natif |
| **Accessibilité, passe finale** | WCAG AA sur l'intégralité du chrome, audit VoiceOver complet |
| **Robustesse** | Correction des retours de bêta, fuites mémoire, arbre des plantages à zéro sur les chemins principaux |
| **Distribution** | Notarisation, signature Developer ID, mise à jour Sparkle testée de bout en bout, DMG |
| **Le reste** | Site, captures, page d'à-propos, licence |

**Critères de sortie — v1.0 :**
- [ ] Zéro plantage connu sur les parcours principaux
- [ ] WCAG AA vérifié, VoiceOver audité
- [ ] Mise à jour testée depuis une v0.9 réellement installée
- [ ] Le budget de performance tient toujours

---

## 8. Après la v1

| Version | Contenu | Durée |
|---|---|---|
| **v1.1 — Spaces et Split View** | Spaces (mode vertical uniquement) · onglets groupés · Split View · Focus Mode · profils | **3,5–4,5 mois** |
| **v1.2 — Le confort** | Userscripts · sélecteur d'élément → filtre · mode lecture · aperçu de lien au survol · capture d'écran · fermeture des onglets dormants | 2–3 mois |

Sur la v1.1 : la §2.2 de la spec chiffre les modes multiples à « 2 à 3 mois supplémentaires » **en plus** de l'implémentation d'un mode, et les 3–4 mois de la v0.3 étaient sous-évalués. Avec le vertical déjà livré en J2b et le modèle d'onglets découplé de son rendu depuis J1, le Split View devient une troisième vue du même modèle plutôt qu'un troisième chemin de code. C'est ce qui ramène ce poste à 3,5–4,5 mois — le travail d'architecture de J1 est payé ici.

Le Split View garde deux points ouverts hérités des maquettes : une seule sidebar et une seule barre d'adresse contextuelle sur le volet actif (les planches en montrent deux), et le liseré de sécurité par volet — déjà prévu depuis J1.

**Jamais :** extensions · synchronisation · mobile · IA · télémétrie · compte · inspecteur maison · mode sombre forcé · sélection DNS · notes intégrées.

---

## 9. Risques

| Risque | Impact | Parade |
|---|---|---|
| **Le geste de révélation n'a pas de bonne solution** | Le concept perd un de ses trois points d'entrée | Tranché en J0 sem. 2. Repli : curseur au bord + raccourci, qui marche aussi à la souris |
| **L'auto-masquage est fatigant à l'usage** | Le produit n'existe pas | J0 sem. 3 et le test des 30 jours en J2. Le réglage « toujours visible » est le filet |
| **Les téléchargements et la restauration de session débordent** | J1 glisse d'un mois | Les deux seuls postes du socle à surveiller. Le reste est mécanique |
| **Les deux modes d'onglets deviennent la première source de bugs** — glisser-déposer, restauration, focus clavier en double | J2b double de taille | Le modèle découplé du rendu, posé en J1 (point 2). Le scénario complet rejoué à l'identique dans les deux modes comme critère de sortie. J2b est isolé après la v0.1 : s'il dérape, il ne bloque rien |
| **`WKContentRuleList` ne couvre pas assez de règles** | Adblock plus faible que uBlock | Mesuré en J3 contre des pages de référence. Repli : filtrage réseau maison en v1.2, pas en v1 |
| **Le monochrome ne tient pas face aux vraies pages** | La direction artistique s'effondre tard | La planche « chrome contre pages laides » est due en J0, pas en J3 |
| **macOS impose de la couleur** — feux, teinte d'accentuation, contrôles de formulaire rendus par WebKit | Le monochrome absolu est impossible | Règle écrite : monochrome pour le chrome, jamais pour le contenu. À acter dans le design system en J0 |

---

## 10. Ce qui reste à trancher

1. **Le mode par défaut au premier lancement.** Horizontal (familier, rassurant) ou vertical (différenciant, mais déroutant en plus de l'UI qui disparaît) ? *Recommandation : horizontal. Deux ruptures d'habitude en même temps, c'est une de trop — et le vertical reste à un clic dans les Réglages.* À décider avant J2b.
2. **Le modèle économique.** Achat unique, don, open source ? Sans télémétrie, sans pub, sans compte, sans sync, il n'y a aucun revenu passif. Sans conséquence sur J0–J2b, à décider avant J3 (bêta publique).
3. **Le nom des « Spaces ».** Déjà pris par les bureaux virtuels de macOS. Sans objet avant la v1.1.
4. **Le sort des couleurs de Spaces** une fois la couleur réservée à la sécurité. v1.1.

Aucun de ces points ne bloque le démarrage de J0.
