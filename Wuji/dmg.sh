#!/bin/bash
# Construit l'application en release et l'empaquette dans Wuji.dmg, à la racine du dépôt.
#
# **Release et pas debug** : c'est la seule différence qui compte pour ce qu'on distribue —
# le binaire optimisé, sans les vérifications de développement.
#
# **La signature reste ad-hoc.** Sans identité Developer ID ni notarisation, macOS refusera
# d'ouvrir cette application sur une autre machine que celle qui l'a compilée : le premier
# lancement demandera un clic droit → Ouvrir. C'est dit ici pour que personne ne découvre la
# limite après avoir envoyé le fichier.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh release

DMG="../Wuji.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R .build/Wuji.app "$STAGE/"
# Le raccourci vers Applications : c'est ce qui rend le glisser-déposer évident sans
# écrire un mode d'emploi dans la fenêtre.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# UDZO : compressé. L'image d'une application de cette taille passe de quelques dizaines de
# mégaoctets à quelques-uns, et se monte tout aussi vite.
hdiutil create -volname "Wuji" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo "→ $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"
