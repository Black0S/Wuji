# Contribuer à Wuji

## La licence, et pourquoi il y a un accord

Wuji est sous **GPL-3.0**. Personne ne peut en faire un produit fermé : qui redistribue
une version modifiée doit en publier le code sous la même licence.

Cette protection a une condition que les projets oublient souvent. Pour qu'elle tienne, et
pour que Wuji puisse aussi être **vendu** ou publié ailleurs — un magasin d'applications,
une licence commerciale pour une entreprise qui ne veut pas de la GPL —, il faut que les
droits soient réunis en une seule main. Dès qu'une contribution extérieure entre sans
accord, plus personne ne peut relicencier quoi que ce soit, y compris l'auteur du reste.

D'où l'accord ci-dessous. Il ne vous retire rien : votre contribution reste publiée sous
GPL-3.0 comme le reste du projet, et vous en gardez la paternité et vos propres droits
d'usage.

## Accord de contribution

En proposant une modification (*pull request*, correctif, ou tout autre envoi), vous
déclarez :

1. que vous êtes l'auteur de cette contribution, ou que vous avez le droit de la soumettre ;
2. qu'elle n'est couverte par aucune obligation contraire — celle d'un employeur, d'un
   client, ou d'une licence incompatible ;
3. que vous accordez à Liam Jutteau (Black0S) une licence **irrévocable, mondiale, sans redevance**
   pour utiliser, modifier, publier et **redistribuer sous d'autres conditions** votre
   contribution, y compris sous une licence commerciale ;
4. que vous conservez tous vos droits d'auteur sur ce que vous avez écrit, et le droit de
   l'utiliser ailleurs comme bon vous semble.

Rien n'est à signer : proposer une modification vaut acceptation. Votre nom reste attaché
à vos commits.

« Black0S » est le pseudonyme sous lequel le projet est publié ; le titulaire des droits est
Liam Jutteau. Les deux sont écrits ensemble parce qu'un accord de contribution n'a de valeur
que s'il désigne une personne identifiable.

## Ce qui est attendu d'une contribution

Le projet a des règles, tenues depuis le début et lisibles dans l'historique :

- **Aucun contrôle mort.** Un réglage qui ne pilote rien est pire qu'un réglage absent.
- **On mesure avant de décider.** Les commits de ce dépôt disent ce qui a été mesuré et
  comment. Une affirmation de performance sans chiffre n'entre pas.
- **On écrit ce qu'on ne sait pas.** Le journal de blocage dit « aucune règle ne vise cette
  adresse » plutôt que de s'attribuer un mérite ; c'est la même exigence partout.
- **Les commentaires disent *pourquoi*, pas *quoi*.** Le code dit déjà ce qu'il fait.
- **Ce qui se vérifie sans fenêtre a un test.** `swift test` doit rester vert.

## Une règle de blocage

Elles ont leur propre marche à suivre, plus stricte, dans
[`Sources/Blocking/Assets/README.md`](Sources/Blocking/Assets/README.md) : un domaine et
non un chemin, adossé à au moins une liste de référence, jamais deux fois dans deux
listes, et rien qui casse une page.

## Construire

```bash
./run.sh
```

Compile en release, installe dans `/Applications` et lance depuis là — **on teste où
l'application vivra**. `swift test` pour la logique pure, `./uninstall.sh` pour repartir
d'un état vide.
