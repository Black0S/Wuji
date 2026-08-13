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

# Signature ad-hoc : suffit pour que macOS accorde les permissions localement.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "→ $APP"
open "$APP"
