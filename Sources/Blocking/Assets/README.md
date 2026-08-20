# Les règles de Wuji

Six fichiers, une famille chacun. Ils sont écrits **dans le format de
`WKContentRuleList`** — celui que WebKit compile directement. Rien n'est traduit, ni au
démarrage ni ailleurs : le fichier part tel quel dans le moteur.

C'est la raison d'être de ce choix. Un convertisseur, si rapide soit-il, est du travail
fait à chaque lancement pour retrouver un résultat qui ne change pas. Autant écrire le
résultat.

| Fichier | Ce qu'il vise | Règles |
|---|---|---|
| `wuji-tracking.json` | mesure d'audience, comportement, attribution, courtiers d'identité, empreinte | 72 |
| `wuji-ads.json` | régies, enchères en temps réel, articles sponsorisés, notifications poussées | 84 |
| `wuji-telemetry.json` | ce que les systèmes et les appareils renvoient à leur fabricant | 57 |
| `wuji-cosmetic.json` | masquage d'éléments dont la classe annonce une publicité | 20 |
| `wuji-social.json` | boutons et pixels sociaux, hors du site du réseau | 15 |
| `wuji-session-replay.json` | l'enregistrement de vos mouvements et de vos frappes | 12 |

**Chaque fichier est compilé séparément**, et chacun s'éteint dans `wuji://ad-block/lists`.
C'est ce qui décide du découpage : une famille n'existe que si l'on peut vouloir la garder
en éteignant les autres. Ajouter un septième fichier ne suffit pas à créer une liste — il
faut aussi une entrée dans `RuleList.all`, avec son nom et sa phrase.

Les fichiers portent des repères de lecture — les lignes en `//` qui nomment les sections.
Le chargeur ne retient que les lignes qui sont des règles ; le moteur ne voit jamais rien
d'autre, et le fichier reste relisible.

## Ajouter un domaine

Une ligne, dans le fichier de sa famille, à sa place dans la section, en ordre
alphabétique :

```json
  {"action":{"type":"block"},"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?exemple\\.com[/:]"}},
```

Le motif se lit ainsi : n'importe quel protocole, n'importe quel sous-domaine, puis le
domaine dont **chaque point est échappé**, et enfin `/` ou `:`. C'est ce dernier crochet qui
évite qu'`exemple.com` attrape `exemple.com.pirate.net`.

Pour ne bloquer un domaine que lorsqu'il est appelé depuis un autre site — utile quand il
héberge aussi un vrai service — ajoutez la charge :

```json
  {"action":{"type":"block"},"trigger":{"url-filter":"…","load-type":["third-party"]}},
```

## Quatre règles pour que ces listes restent utiles

1. **Un domaine, pas un chemin.** Les chemins changent tous les mois, les domaines tiennent
   dix ans. Ces listes visent ce qui dure.
2. **Rien qui casse.** Une règle qui empêche une page de fonctionner coûte plus cher que la
   publicité qu'elle retire. Dans le doute, `third-party`.
3. **Une seule fois, dans une seule liste.** Un domaine recopié dans deux fichiers
   resterait bloqué après en avoir éteint un : l'interrupteur mentirait. Un test refuse le
   doublon entre listes.
4. **Rangée sous sa section**, en ordre alphabétique. Une liste qu'on ne peut pas relire ne
   se corrige pas.

## Ce que ces listes ne font pas

Elles ne visent que des domaines. Les publicités servies **depuis le domaine du site
lui-même** — YouTube au premier chef — leur sont hors de portée : les retirer demande
d'exécuter du code dans la page et de le corriger chaque semaine. Wuji ne le fait pas, et
ne prétend pas le faire.

Deux familles restent exclues **même quand les listes de référence les bloquent** : les
gestionnaires de consentement et les anti-robots. Absents, ils ne retirent pas la
publicité — ils verrouillent la page. C'est à ce titre que `dd.leboncoin.fr`, un DataDome
en première partie, a été retiré au moment du découpage.
