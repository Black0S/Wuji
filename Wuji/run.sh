#!/bin/bash
# Compile le prototype et l'assemble en bundle .app.
#
# Un exécutable SPM nu n'est pas une application pour macOS : pas d'Info.plist, donc pas
# de permissions système (caméra, micro, position) et pas d'identité au niveau du Dock.
# Le bundle est jetable comme le reste — il vit dans .build/, qui est ignoré par git.
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

# Les bibliothèques d'AdGuard : les scriptlets sont développés au moment de la compilation
# des règles, les sélecteurs étendus s'exécutent dans la page.
cp Resources/JS/*.js "$APP/Contents/Resources/"

# Les listes de Wuji. Elles vivent en texte à la racine du dépôt pour qu'une contribution
# soit une ligne dans un diff, et sont recopiées dans le paquet à chaque assemblage.
cp Filters/*.txt "$APP/Contents/Resources/"

# La liste des suffixes publics, telle que SwiftPM l'empaquette. Elle est cherchée à côté
# de l'application et **pas** dans ses ressources, et son absence est fatale au lancement :
# la bibliothèque appelle `fatalError` plutôt que de se passer de ses données.
cp -R ".build/arm64-apple-macosx/$CONFIG/swift-psl_PublicSuffixList.bundle" "$APP/"

# Signature ad-hoc : suffit pour que macOS accorde les permissions localement.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "→ $APP"
open "$APP"
