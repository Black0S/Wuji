#!/bin/bash
# Installe Wuji dans /Applications et le lance. C'est la boucle de test.
#
# **On teste là où l'application vivra.** Lancée depuis `.build`, elle n'a ni la place ni
# l'identité qu'elle aura chez quelqu'un : macOS l'enregistre autrement, et les
# autorisations qu'il accorde ne sont pas rangées au même nom. Un test fait ailleurs que
# dans /Applications ne dit donc rien de ce qui se passera après l'installation.
#
# **`open` ne relance pas une application déjà ouverte**, il la ramène au premier plan : on
# se retrouve alors à tester l'ancien binaire en croyant tester le nouveau. Ce piège a déjà
# coûté un mauvais diagnostic, d'où la fermeture préalable — et l'attente qu'elle aboutisse.
#
# Release par défaut, comme ce qui sera distribué. `./run.sh debug` pour l'autre.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh "${1:-release}"

osascript -e 'tell application "Wuji" to quit' >/dev/null 2>&1 || true
while pgrep -x Wuji >/dev/null; do sleep 0.2; done

TARGET="/Applications/Wuji.app"
rm -rf "$TARGET"
cp -R .build/Wuji.app "$TARGET"
# LaunchServices garde en cache ce qu'il sait d'un paquet : sans ce rappel, il peut ouvrir
# la version précédente, ou afficher l'ancienne icône.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$TARGET" >/dev/null 2>&1 || true

echo "→ $TARGET"
open "$TARGET"
