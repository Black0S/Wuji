# Wuji — prototype de travail

Navigateur macOS à interface qui disparaît. Voir `../WUJI - Spécification & Identité.md`
pour le quoi et le pourquoi, `../WUJI - Roadmap.md` pour l'ordre.

```bash
./run.sh
```

Le script compile et assemble un bundle `.app`. Un exécutable SPM nu n'est pas une
application pour macOS : sans `Info.plist`, pas de permissions système et pas d'identité
au niveau du Dock. Le bundle vit dans `.build/`, ignoré par git.

## Arborescence

Calquée sur les modules de la spec §6.1. Une seule cible SPM pour l'instant : on n'extrait
un paquet que le jour où un module doit devenir désactivable.

```
Sources/Wuji/
├── App/           point d'entrée, assemblage, menus
├── Window/        la fenêtre et toute la géométrie du layout
├── Chrome/        barre du haut, sidebar, palette omnibox
├── Reveal/        la révélation à l'intention et ses candidats
├── WebContent/    hôte WKWebView, liseré de sécurité, favicons
├── Settings/      modèle de réglages et fenêtre de réglages
└── DesignSystem/  tokens : couleurs, espacements, métriques du chrome
```

## Raccourcis

| | |
|---|---|
| `⌘L` | Palette — adresse, recherche, onglets ouverts |
| `⌘T` / `⌘W` | Nouvel onglet / fermer |
| `⌘]` / `⌘[` | Onglet suivant / précédent |
| `⌘R` | Recharger |
| `⌘,` | Réglages |
| `⌃S` | Compteurs de révélation par source |

Le curseur poussé contre le bord haut ou le bord gauche révèle l'interface.

## ⚠️ Décision en attente : l'interface reste visible

**L'interface est désormais visible en permanence par défaut.** L'escamotage automatique
existe toujours et se réactive dans Réglages › Apparence, mais il n'est plus le
comportement de départ.

C'est l'inverse du principe 1 de la spec, et ce n'est pas un réglage d'agrément : c'est le
risque n°2 de la roadmap — *« l'auto-masquage est fatigant à l'usage »*, dont la parade
prévue était précisément ce réglage. Deux lectures possibles, et elles n'ont pas les mêmes
conséquences :

1. **Confort de développement.** On garde l'interface visible pendant qu'on construit, et
   l'escamotage redevient le défaut plus tard. Rien à changer dans la spec.
2. **Verdict sur le concept.** Vivre sans interface est désagréable, et alors *« le
   navigateur qui disparaît »* ne tient pas comme thèse produit. Il faut réécrire le
   principe 1, l'identité (§9) et une partie de la roadmap.

**Tant que ce n'est pas tranché, le reste du projet avance sur une base incertaine.**

## Ce qui existe

- **Layout vertical ancré.** Sidebar à gauche, contenu après elle. Quand l'interface
  s'escamote, la sidebar sort par la gauche et le contenu reprend toute la fenêtre.
- **Révélation à l'intention**, avec hystérésis et délai réglables en direct.
  Désactivée par défaut — voir ci-dessus.
- **Palette omnibox** — adresse, recherche, et les onglets ouverts en tête des résultats.
- **Liseré de sécurité** pour les connexions non chiffrées, posé au-dessus du web view
  et non autour : la page ne se remet jamais en page.
- **Favicons**, récupérées depuis le site lui-même.
- **Réglages** — thème, interface toujours visible, délai d'escamotage, moteur de
  recherche, zoom, inspection Safari, et les seuils de révélation.
- **Icône**, générée par le dessin (`swift Resources/Icon/make-icon.swift`).

## Ce qui n'existe pas, et pourquoi

Pas d'historique, pas de favoris, pas de persistance, pas de restauration de session, pas
d'adblock, pas de session privée, pas de profils, pas de permissions par site. Tout ça
c'est J1 et J3 dans la roadmap.

**Rien n'est affiché pour ces fonctionnalités.** Pas de rangée grisée, pas d'interrupteur
inerte, pas de liseré simulé. Un contrôle qui ne fait rien donne l'illusion d'un produit
plus avancé qu'il ne l'est — c'est exactement ce qui rend une maquette trompeuse quand on
la prend pour un cahier des charges.

## La question ouverte : le geste de révélation

Deux doigts vers le haut sur trackpad, **c'est le défilement de la page**. Le geste des
maquettes entre en collision frontale avec la lecture. `←`/`→` est déjà pris par
`allowsBackForwardNavigationGestures`, que beaucoup de sites captent.

Les candidats s'activent un par un dans **Réglages › Avancé**, avec leurs seuils :

| | Candidat | Ce qu'il faut constater |
|---|---|---|
| A | Overscroll en haut de page | Sur une page **non défilable**, `scrollY` vaut toujours 0 : toute tentative de défilement vers le haut déclenche. Acceptable ou rédhibitoire ? |
| B | Trois doigts | **Conflit système attendu** : sans « Balayer entre les pages » réglé sur trois doigts, le geste part dans Mission Control. Le constater est un résultat. |
| C | Curseur au bord | Le seul qui marche aussi à la souris. Repli sûr, actif par défaut. |
| D | Clavier seul (`⌘L`) | Repli minimal, toujours disponible |

**Protocole :** un candidat par jour, isolé. Tant que plusieurs sont actifs, on ne sait pas
lequel a réellement servi. `⌃S` donne les compteurs par source, imprimés aussi à la
fermeture.

### Note technique

Sur macOS, `WKWebView` n'expose pas son scroll view et avale `scrollWheel(with:)`. La page
elle-même est le seul endroit d'où l'on voit à la fois la position de défilement et
l'intention de la molette — d'où un `WKUserScript` injecté dans **chaque** page pour le
candidat A. C'est un module au coût permanent, donc en tension avec le principe 4. Si A
gagne, il gagne avec cette dette.

## L'autre question ouverte : la sidebar ancrée

Révéler la sidebar redimensionne la vue web, donc la page se remet en page pendant toute
l'animation. C'est le coût du layout ancré. Si ça saccade sur une page lourde, il faudra
trancher entre sidebar ancrée et sidebar flottante — c'est une décision de design, pas
d'optimisation.

## Ce que l'usage a déjà corrigé

Des défauts que seule la manipulation révèle, pas la relecture :

- **La palette était amorcée avec l'URL courante**, donc elle filtrait dessus et
  n'affichait aucun onglet ouvert — exactement ce qu'on vient chercher à `⌘L`.
- **Le chrome invisible volait des clics à la page** : dans AppKit, une vue à `alpha 0`
  continue de recevoir les événements.
- **Chaque vue calculait sa propre position**, et finissait par se superposer à une autre.
  Toute la géométrie est maintenant dans `BrowserLayout` et `Tokens.Chrome`.
- **`print` est bufferisé hors terminal**, donc les compteurs n'apparaissaient qu'à la
  fermeture. `setbuf(stdout, nil)` dans `main.swift`.

## Non vérifié

`esc` pour fermer la palette et `⌘,` pour ouvrir les réglages : ces touches, injectées par
l'automatisation, n'atteignent pas l'application alors qu'elle est au premier plan. Le code
n'est pas en cause — le menu et le clic à côté empruntent les mêmes chemins et fonctionnent
— mais **les deux demandent une vraie frappe clavier pour être confirmés**.
