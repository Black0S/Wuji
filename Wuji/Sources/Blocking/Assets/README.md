# Les règles de Wuji

`wuji-rules.json` est la liste, et il n'y en a pas d'autre. Elle est écrite **dans le format de
`WKContentRuleList`** — celui que WebKit compile directement. Rien n'est traduit, ni au
démarrage ni ailleurs : le fichier part tel quel dans le moteur.

C'est la raison d'être de ce choix. Un convertisseur, si rapide soit-il, est du travail
fait à chaque lancement pour retrouver un résultat qui ne change pas. Autant écrire le
résultat.

Le fichier porte des repères de lecture — les lignes en `//` qui nomment les sections. Le
chargeur ne retient que les lignes qui sont des règles ; le moteur ne voit jamais rien
d'autre, et le fichier reste relisible.

## Ajouter un domaine

Une ligne, à sa place dans la section qui lui correspond, en ordre alphabétique :

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

## Trois règles pour que cette liste reste utile

1. **Un domaine, pas un chemin.** Les chemins changent tous les mois, les domaines tiennent
   dix ans. Cette liste vise ce qui dure.
2. **Rien qui casse.** Une règle qui empêche une page de fonctionner coûte plus cher que la
   publicité qu'elle retire. Dans le doute, `third-party`.
3. **Rangée sous sa section**, en ordre alphabétique. Une liste qu'on ne peut pas relire ne
   se corrige pas.

## Ce que cette liste ne fait pas

Elle ne vise que des domaines. Les publicités servies **depuis le domaine du site lui-même**
— YouTube au premier chef — lui sont hors de portée : les retirer demande d'exécuter du code
dans la page et de le corriger chaque semaine. Wuji ne le fait pas, et ne prétend pas le
faire.

## Sections

**Publicité** — Google · places de marché et enchères en temps réel · recommandation de
contenu et articles sponsorisés · régies vidéo · régies généralistes.

**Suivi** — mesure d'audience · produit et comportement · rejeu de session · empreinte de
navigateur · réseaux sociaux · attribution · courtiers d'identité · notifications poussées.
