# Wuji — prototype de travail

Navigateur macOS. Voir `../WUJI - Spécification & Identité.md` pour le quoi et le pourquoi,
`../WUJI - Roadmap.md` pour l'ordre.

```bash
./run.sh
```

Le script compile et assemble un bundle `.app`. Un exécutable SPM nu n'est pas une
application pour macOS : sans `Info.plist`, pas de permissions système et pas d'identité
au niveau du Dock. Le bundle vit dans `.build/`, ignoré par git.

## ⚠️ L'interface ne disparaît plus

**Tout le masquage automatique a été retiré.** L'interface est permanente : sidebar et
barre du haut restent affichées, la fenêtre ne s'escamote pas.

Ce qui est parti avec : la révélation à l'intention et ses quatre candidats de geste, les
seuils et l'hystérésis, l'escamotage différé, le `WKUserScript` d'overscroll injecté dans
chaque page, les feux de circulation escamotables, la section « Avancé » des réglages.

**Les documents du projet ne disent plus la vérité.** Le principe 1 (« Zéro interface »),
le pitch (« Wuji disparaît deux fois »), l'identité §9 (« Designed to Disappear ») et une
partie de la roadmap décrivent un produit qui n'existe plus. Il reste à décider ce que
Wuji est maintenant — les autres piliers (zéro télémétrie, zéro IA, zéro cloud, 100 %
natif) tiennent toujours, mais ils ne suffisent pas à eux seuls à définir un navigateur.

## Arborescence

Calquée sur les modules de la spec §6.1. Une seule cible SPM pour l'instant : on n'extrait
un paquet que le jour où un module doit devenir désactivable.

```
Sources/Wuji/
├── App/           point d'entrée, assemblage, menus
├── Window/        la fenêtre et toute la géométrie du layout
├── Chrome/        barre du haut, sidebar, palette omnibox
├── WebContent/    hôte WKWebView, liseré de sécurité, favicons
├── Settings/      modèle de réglages et fenêtre de réglages
└── DesignSystem/  tokens : couleurs, espacements, métriques du chrome
```

## Raccourcis

| | |
|---|---|
| `⌘L` | Palette — adresse, recherche, onglets ouverts |
| `⌘F` | Rechercher dans la page · `⌘G` / `⇧⌘G` résultat suivant / précédent |
| `⌘T` / `⌘W` | Nouvel onglet / fermer |
| `⌘]` / `⌘[` | Onglet suivant / précédent |
| `⌘R` | Recharger |
| `⌘,` | Réglages |

## Ce qui existe

- **Layout vertical ancré.** Sidebar à gauche, contenu après elle.
- **Palette omnibox** — adresse, recherche, et les onglets ouverts en tête des résultats.
- **Recherche dans la page** (`⌘F`), en pilule flottante sur le contenu.
- **Liseré de sécurité** pour les connexions non chiffrées, posé au-dessus du web view
  et non autour : la page ne se remet jamais en page.
- **Favicons**, récupérées depuis le site lui-même et jamais d'un service tiers de
  résolution — celui-ci apprendrait chaque domaine visité.
- **Réglages** — thème, page de démarrage, moteur de recherche, zoom, inspection Safari.
- **Icône**, générée par le dessin (`swift Resources/Icon/make-icon.swift`), avec une
  variante simplifiée en dessous de 128 px : le halo y devient une bouillie grise.

## Ce qui n'existe pas, et pourquoi

Pas d'historique, pas de favoris, pas de persistance, pas de restauration de session, pas
d'adblock, pas de session privée, pas de profils, pas de permissions par site.

**Rien n'est affiché pour ces fonctionnalités.** Pas de rangée grisée, pas d'interrupteur
inerte, pas de liseré simulé, pas de section vide. Un contrôle qui ne fait rien donne
l'illusion d'un produit plus avancé qu'il ne l'est.

## Approximation assumée : le compteur de la recherche

`WKFindResult` ne dit que « trouvé ou non » — **ni total, ni position**. La navigation et
le surlignage viennent bien de WebKit, mais le « 2/6 » est reconstitué par un balayage
`innerText` de notre côté.

Ce balayage ignore les iframes et compte différemment un mot coupé entre deux nœuds : sur
une page ordinaire il tombe juste, sur une page composite il peut diverger de ce que la
navigation surligne réellement. Le seul moyen d'un compteur exact serait de refaire la
recherche entièrement en JS, donc de renoncer au moteur de WebKit — ce n'est pas un bon
échange pour un chiffre.

## Ce que l'usage a déjà corrigé

Des défauts que seule la manipulation révèle, pas la relecture :

- **La palette était amorcée avec l'URL courante**, donc elle filtrait dessus et
  n'affichait aucun onglet ouvert — exactement ce qu'on vient chercher à `⌘L`.
- **Les fonds ne suivaient pas le thème.** Un `NSColor` dynamique affecté à `textColor` se
  résout à chaque affichage ; le même converti en `CGColor` pour un `layer` est résolu une
  seule fois. Les textes basculaient, les fonds non : du noir sur noir. D'où `ThemedView`.
- **Chaque vue calculait sa propre position**, et finissait par se superposer à une autre.
  Toute la géométrie est dans `BrowserLayout` et `Tokens.Chrome`.
- **`print` est bufferisé hors terminal.** `setbuf(stdout, nil)` dans `main.swift`.
