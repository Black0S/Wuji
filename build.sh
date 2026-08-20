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

# Les règles de Wuji, déjà dans le format de WebKit : rien à convertir, ni ici ni au
# démarrage.
# Les listes de règles, une par famille : le bloqueur en compile une par fichier.
cp Sources/Blocking/Assets/wuji-*.json "$APP/Contents/Resources/"

# La liste des suffixes publics. Elle va dans les ressources comme le reste — c'est ce que
# macOS exige pour signer le paquet, et c'est là que le code la cherche. Son absence est
# fatale au lancement : elle décide où s'arrête « ce site ».
cp Sources/PublicSuffix/Data/*.bin "$APP/Contents/Resources/"

# Signature ad-hoc, avec l'autorisation de débogage : suffit pour que macOS accorde les
# permissions localement, et c'est ce qui rend les pages inspectables depuis Safari.
# Signature ad-hoc, sans entitlement. Le seul qu'il y avait — `get-task-allow` — servait
# à rendre les pages inspectables depuis Safari, fonction retirée ; et il est de toute
# façon refusé à la notarisation. Le jour d'une vraie identité, ce fichier reviendra avec
# ce qu'elle demande.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "→ $APP"
