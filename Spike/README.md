# J0 — Spike *(3 semaines, code jetable)*

Ce code ne va pas en production et ne doit pas être écrit comme s'il y allait. Il existe
pour répondre à quatre questions binaires avant d'engager dix mois.

```bash
swift run
```

## Raccourcis

| | |
|---|---|
| `⌘L` | Omnibox (révèle le chrome et met le focus) |
| `⌘T` / `⌘W` | Nouvel onglet / fermer |
| `⌘]` / `⌘[` | Onglet suivant / précédent |
| `⌘R` | Recharger |
| `⌥0` `⌥1` `⌥2` `⌥3` | Liseré : réel · non chiffré · permission active · session privée |
| `⌃1` `⌃2` `⌃3` | Activer/désactiver un candidat de révélation : bord haut · overscroll · trois doigts |
| `⌃S` | Afficher les compteurs de révélation par source |

Pas de barre d'onglets : c'est délibéré — la thèse à éprouver est que l'omnibox devient
le vrai sélecteur d'onglets.

## Les quatre questions

### Semaine 1 — la fenêtre

- [ ] **Q1.** `WKWebView` bord à bord, sans barre de titre, feux de circulation escamotables.
      → `SpikeWindow.swift`
- [ ] **Q2.** Liseré fin autour du contenu, animable, sans décaler la mise en page.
      → `SecurityBorderView.swift` — posé *au-dessus* du web view, jamais autour.
- [ ] **Q3.** Le chrome flat opaque reste-t-il lisible sur cinq pages réelles ?
      → `ChromeOverlay.swift` — tester sur cinq pages volontairement laides et contrastées.
      Retirer le filet de 1 px et poser la pilule sur une page blanche : c'est la
      démonstration de la règle §4.2 de la spec.

### Semaine 2 — le geste *(le seul vrai inconnu)*

Deux doigts vers le haut sur trackpad, **c'est le défilement de la page**. Le geste des
maquettes entre en collision frontale avec la lecture. `←`/`→` est déjà pris par
`allowsBackForwardNavigationGestures`, que beaucoup de sites captent.

**Les quatre candidats sont implémentés et se désactivent au menu** (`⌃1` `⌃2` `⌃3`).
Ils sont à **vivre**, pas à juger sur le papier — et à isoler un par un : tant que les
trois sont actifs, on ne sait pas lequel a réellement servi.

| | Candidat | État | Ce qu'il faut constater |
|---|---|---|---|
| A | Overscroll en haut de page | `RevealGestures.swift` | Sur une page **non défilable**, `scrollY` vaut toujours 0 : toute tentative de défilement vers le haut déclenche. Acceptable ou rédhibitoire ? |
| B | Trois doigts | `RevealGestures.swift` | **Conflit système attendu** : sans « Balayer entre les pages » réglé sur trois doigts, le geste part dans Mission Control. Le constater est un résultat. |
| C | Curseur au bord haut | `RevealController.swift` | Le seul qui marche aussi à la souris. Repli sûr. |
| D | Clavier seul (`⌘L`) | `AppDelegate.swift` | Repli minimal, toujours disponible |

**Protocole :** une journée par candidat, isolé. À la fin, `⌃S` donne les compteurs par
source — c'est ce tableau qui tranche, pas une impression de fin de semaine.

Décision attendue en fin de semaine 2, **écrite dans la spec**.

Réglages à triturer :
- `RevealController.swift` — `revealZone` (6 pt), `keepZone` (96 pt : c'est l'hystérésis,
  sans elle le chrome clignote dès que la main tremble), `hideDelay` (0,35 s)
- `RevealGestures.swift` — `OverscrollGesture.threshold` (120 px de molette accumulés :
  trop bas, la lecture déclenche ; trop haut, le geste est mort), `travelThreshold` (0,12)

### Note technique — pourquoi l'overscroll passe par du JS

Sur macOS, `WKWebView` n'expose pas son scroll view et avale `scrollWheel(with:)`. La page
elle-même est le seul endroit d'où l'on voit à la fois la position de défilement et
l'intention de la molette. C'est une contrainte à retenir pour J2 : ce candidat implique
un `WKUserScript` injecté dans **chaque** page — donc un module qui a un coût permanent,
ce qui le met en tension avec le principe 4.

### Semaine 3 — le vivre

Utiliser le spike comme navigateur principal cinq jours. Noter chaque friction dans
`JOURNAL.md`, brut, sans filtrer.

## Critères de sortie

- [ ] Les 3 questions de fenêtre ont une réponse écrite, avec le code qui le prouve
- [ ] Le geste de révélation est tranché et documenté
- [ ] 5 jours d'usage réel, journal de frictions rédigé
- [ ] Verdict explicite : **on continue / on ajuste le concept / on l'abandonne**

> Si le verdict est « inconfortable », on l'a appris en trois semaines. C'est la seule
> raison d'être de ce jalon.

## Ce que le spike ne fait pas

Pas d'historique, pas de favoris, pas de persistance, pas de restauration de session, pas
d'adblock, un seul profil, aucune barre d'onglets. Tout ça, c'est J1 — et l'écrire ici
serait la seule vraie façon de rater ce jalon.

## Limites connues

Exécutable SPM sans bundle applicatif : les permissions système (caméra, micro, position)
n'ont pas d'`Info.plist` pour se déclarer et échoueront. Sans importance pour les quatre
questions ; le vrai bundle arrive avec le projet Xcode de J1.
