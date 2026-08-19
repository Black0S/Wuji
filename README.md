# Wuji

Un navigateur pour macOS, écrit en Swift et AppKit, posé sur WebKit. Apple Silicon
uniquement, macOS 26 au minimum.

Il tient en une fenêtre : une colonne d'onglets à gauche, la page à droite, et une palette
au centre quand on cherche quelque chose. Pas de barre d'outils qui s'accumule, pas de
bouton qui ne fait rien.

---

## Le dépôt

```
Package.swift          une seule cible, le chemin des sources dit pourquoi
Sources/
├── App/               point d'entrée, assemblage, menus, délégués WebKit
├── Window/            la fenêtre, la géométrie, le journal de blocage
├── Chrome/            barre du haut, colonne d'onglets, palette, feuilles, bulles
├── WebContent/        hôte du WKWebView, liseré de sécurité, favicons, menu de page
├── Blocking/          les règles, leur asset, le sélecteur d'élément, le journal
├── InternalPages/     tout ce qui s'ouvre en wuji://
├── Scripts/ Settings/ Store/ Tabs/
└── DesignSystem/      les tokens : couleurs, espacements, métriques
Resources/             Info.plist, entitlements, icône
Tests/                 ce qui se vérifie sans fenêtre
build.sh run.sh dmg.sh uninstall.sh
```

Les scripts restent à la racine : ce sont les points d'entrée, et `./run.sh` se tape sans
réfléchir.

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
| `./dmg.sh` | produit `Wuji.dmg` à côté |
| `./uninstall.sh` | efface l'application **et tout ce qu'elle a laissé** |
| `swift test` | la logique pure : fabrication des règles, nom d'un site, validité de l'asset |

La signature est ad-hoc. Sur une autre machine, le premier lancement demandera un clic
droit → Ouvrir : il faudrait une identité Developer ID et la notarisation pour s'en passer.

`uninstall.sh` mérite un mot : supprimer le dossier de l'application ne suffit pas. Les
réglages restent dans le démon des préférences, les autorisations caméra et position dans
une base du système. Un test qui repart d'un état non vide fait croire à un premier
lancement alors qu'il observe le précédent — c'est ce qui rend certains défauts invisibles
chez soi et évidents chez les autres. `--dry-run` liste sans rien toucher.

---

## Le blocage

[`Sources/Blocking/Assets/wuji-rules.json`](Sources/Blocking/Assets/wuji-rules.json) —
**261 règles écrites directement dans le format de `WKContentRuleList`**, celui que WebKit
compile : 241 blocages et 20 masquages. Rien n'est téléchargé, rien n'est converti
au démarrage — le navigateur lit le fichier et le donne au moteur.

Un convertisseur, si rapide soit-il, refait à chaque lancement un travail dont le résultat
ne change pas. Autant écrire le résultat.

**Un seul format dans toute l'application.** Ce que le sélecteur d'élément produit, ce que
vous ajoutez à la main, les exceptions par site : toutes des règles WebKit. Il ne reste
nulle part de traduction à maintenir.

### Ce que ces règles font, et ce qu'elles ne font pas

Elles visent des domaines, quelques noms de classes et quelques chemins. Trois
conséquences, dites ici parce qu'elles sont dites aussi dans l'application :

- **Les publicités servies depuis le domaine du site lui-même passent** — YouTube au
  premier chef. Les retirer demande d'exécuter du code dans la page et de le corriger
  chaque semaine. Wuji ne le fait pas et ne prétend pas le faire.
- **Les domaines jetables passent aussi.** Les sites les plus agressifs tirent leurs
  publicités de noms générés au hasard sur des extensions à bas prix ; EasyList y consacre
  plus de cinq mille règles pour trois extensions, renouvelées sans fin. Une liste tenue à
  la main ne suit pas ce rythme.
- **Ce qui protège vraiment sur ces sites-là**, c'est que WebKit refuse les requêtes des
  régies connues et que les fenêtres non sollicitées n'aboutissent pas.

### Comment une règle entre dans la liste

Chacune est adossée à au moins une liste de référence — EasyList, EasyPrivacy, AdGuard
Base et Tracking, uBlock Origin, Peter Lowe, Turtlecute — et à une règle qui **bloque le
domaine entier**, jamais à une simple mention.

La distinction n'est pas théorique : un hôte figure aussi dans ces listes en **exception**
(`@@||accounts.google.com^`), en **portée** d'une règle cosmétique (`www.bbc.co.uk##.pub`)
ou dans une règle **avec chemin** (`||jsdelivr.net/gh/…/reklam.js`). Chercher le nom
n'importe où ferait bloquer un CDN majeur et la page de connexion Google.

Deux familles sont exclues **même quand les listes les bloquent** : les gestionnaires de
consentement et les anti-robots. Absents, ils ne retirent pas la publicité — ils
verrouillent la page.

Le format et la marche à suivre pour contribuer sont dans
[`Blocking/Assets/README.md`](Sources/Blocking/Assets/README.md).

---

## Ce que le navigateur sait faire

**Espaces et dossiers.** Les onglets appartiennent à un espace, pas à l'application. Un
espace peut être privé : magasin de données éphémère, rien sur le disque, un symbole qui ne
se change pas — `⇧⌘N`.

**Un onglet ne se ferme jamais tout seul.** Passé un délai réglable — jamais, une minute,
jusqu'à une heure — il rend sa mémoire sans quitter la colonne, et le survol le réveille
avant même le clic. Aucune durée ne convient à toutes les machines, d'où le choix. Un
onglet qui joue du son ne s'endort pas, et il porte un haut-parleur à droite de son titre.

**Zoom par site.** `⌘+` et `⌘−` règlent le site qu'on regarde, et il s'en souvient : un
site qui se lit mal n'impose pas sa correction à tout le web. `⌘0` lui rend le zoom par
défaut. Seuls les écarts sont conservés, et Réglages › Sites web les liste.

**Journal de blocage** — une fenêtre qui montre ce qui est arrêté, ligne par ligne. Pas de
compteur : un chiffre qui monte ne se vérifie pas, et il pousse à gonfler ce qu'on mesure.
Le journal note ce que Wuji observe vraiment, et dit ce qu'il ne sait pas.

**Scripts utilisateur** — installation depuis une adresse en `.user.js`, portée affichée
avant d'accepter, mise à jour à la demande. Leur icône quitte la barre quand la fonction
est éteinte.

**Autorisations par site** — caméra, micro, position. Demandées une fois, retenues,
révocables. La position passe par deux portes : le site vous demande, et macOS demande à
Wuji ; accorder la première sans la seconde donnait un refus que la page vous attribuait.

**Pages internes** en `wuji://` — favoris, historique, téléchargements, règles, réglages —
avec le même sommaire à gauche partout.

---

## Raccourcis

| | |
|---|---|
| `⌘L` | Palette — adresse, recherche, onglets ouverts |
| `⌘T` / `⌘W` | Nouvel onglet / fermer · `⇧⌘T` rouvrir le dernier fermé |
| `⌘]` / `⌘[` | Onglet suivant / précédent |
| `⇧⌘N` / `⌥⌘N` | Nouvel espace privé / nouveau dossier |
| `⌘F` | Rechercher dans la page · `⌘G` et `⇧⌘G` pour circuler |
| `⌘R` | Recharger · `⌘+` et `⌘−` pour le zoom |
| `⌘D` / `⇧⌘B` | Mettre en favori / ouvrir les favoris |
| `⌘Y` / `⌘J` | Historique / téléchargements |
| `⌘,` | Réglages |

---

## Ce que le projet s'interdit

- **Aucun contrôle mort.** Un réglage qui ne pilote rien est pire qu'un réglage absent : il
  donne l'illusion d'un produit plus avancé qu'il ne l'est.
- **Aucune télémétrie.** Rien ne part de cette machine que vous n'ayez demandé.
- **Aucune suggestion du moteur de recherche.** Elles supposent d'envoyer *chaque frappe* à
  un tiers — « c », « ch », « cha » — y compris pour les recherches qu'on efface avant de
  les valider. C'est une fuite continue, pas ponctuelle. La palette cherche donc chez vous
  seulement : onglets ouverts, historique, favoris. Décidé, pas en attente.
- **Les favicons viennent du site**, jamais d'un service tiers qui apprendrait au passage
  ce que vous visitez.
- **Aucune règle écrite pour faire passer un test.** Les pages de conformité proposent
  leurs propres filtres ; les adopter donne un bon score et ne protège personne.

---

## L'état réel

Ce dépôt a longtemps porté une feuille de route et une spécification qui décrivaient un
produit différent — une interface qui s'escamotait, un blocage adossé au convertisseur
d'AdGuard et à ses scriptlets. Les deux ont été abandonnés à l'usage : la première parce
qu'une colonne qui se dérobe fait chercher ce qu'on veut atteindre, le second parce que
425 Mo sur le disque et trente secondes de recompilation contredisaient la sobriété
promise. Ces documents ont été retirés plutôt que maquillés.

Ce qui reste ouvert est écrit dans les commits, qui disent aussi ce qui a été mesuré pour
en décider.
