#!/bin/bash
# Assemble le bundle .app, sans le lancer.
#
# **Un seul endroit qui sait ce qu'il faut mettre dedans.** `run.sh` et `dmg.sh` appellent
# celui-ci : à la première divergence, l'un des deux oublierait une ressource et l'oubli ne
# se verrait qu'au lancement — la liste des suffixes publics, par exemple, est fatale par
# son absence.
#
# Un exécutable SPM nu n'est pas une application pour macOS : pas d'Info.plist, donc pas de
# permissions système (caméra, micro, position) et pas d'identité au niveau du Dock.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP=".build/Wuji.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp ".build/$CONFIG/Wuji" "$APP/Contents/MacOS/Wuji"

# L'icône est redessinée, pas redimensionnée : le halo de l'anneau devient une bouillie
# grise en dessous de 128 px. `swift Resources/Icon/make-icon.swift` la régénère.
[ -f Resources/Icon/AppIcon.icns ] && cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/"

# La liste des suffixes publics. Elle va dans les ressources comme le reste — c'est ce que
# macOS exige pour signer le paquet, et c'est là que le code la cherche. Son absence est
# fatale au lancement : elle décide où s'arrête « ce site ».
cp Sources/PublicSuffix/Data/*.bin "$APP/Contents/Resources/"

# Signature ad-hoc, sans droits. Le seul qu'il y avait — `get-task-allow` — servait à rendre
# les pages inspectables depuis Safari, fonction retirée ; et il est de toute façon refusé à
# la notarisation.
#
# **Une copie signée ad-hoc n'a pas tous les pouvoirs de la version publiée**, et c'est
# mesuré, pas supposé : un élément de trousseau à contrôle biométrique rend -34018 ici, et
# Wuji retombe alors sur sa protection logicielle en le disant dans ses réglages.
# `release.sh` signe avec l'identité Developer ID et fabrique le fichier de droits qui va
# avec.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "→ $APP"
