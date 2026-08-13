#!/bin/bash
# Compile le spike et l'assemble en bundle .app.
#
# Un exécutable SPM nu n'est pas une application pour macOS : pas d'Info.plist, donc pas
# de permissions système (caméra, micro, position) et pas d'identité au niveau du Dock.
# Le bundle est jetable comme le reste — il vit dans .build/, qui est ignoré par git.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP=".build/WujiSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp ".build/$CONFIG/WujiSpike" "$APP/Contents/MacOS/WujiSpike"

# Signature ad-hoc : suffit pour que macOS accorde les permissions localement.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "→ $APP"
open "$APP"
