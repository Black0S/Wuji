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

# **La signature, avec un certificat s'il y en a un.**
#
# Ce n'était pas le cas : `build.sh` signait toujours en ad-hoc, et seul `release.sh` savait
# se servir d'une identité. La copie qu'on utilise tous les jours était donc moins capable
# que celle qu'on publie — sans que rien ne le dise. Deux conséquences, mesurées toutes les
# deux : un élément de trousseau gardé par l'Enclave rend -34018 faute du droit
# `keychain-access-groups`, et l'empreinte d'une signature ad-hoc change à chaque
# compilation, si bien que le trousseau ne reconnaît jamais l'application d'un lancement à
# l'autre et redemande son mot de passe à chaque accès.
#
# Avec un certificat — « Developer ID Application », ou simplement « Apple Development »
# qu'Xcode délivre en une minute —, l'exigence porte sur le certificat et non sur le
# binaire : elle survit aux recompilations, et Touch ID ouvre le coffre par l'Enclave.
. "$(dirname "$0")/tools/signature.sh"
IDENTITE="$(wuji_identite)"
if [ -n "$IDENTITE" ]; then
    DROITS="$(wuji_droits "$IDENTITE")"
    if [ -n "$DROITS" ]; then
        codesign --force --sign "$IDENTITE" --entitlements "$DROITS"                  --generate-entitlement-der "$APP" >/dev/null
        echo "→ signé : $IDENTITE · keychain-access-groups"
    else
        codesign --force --sign "$IDENTITE" "$APP" >/dev/null
        echo "→ signé : $IDENTITE · sans identifiant d'équipe"
    fi
else
    # Rien à signer avec : on retombe sur l'ad-hoc, qui suffit à lancer l'application ici.
    # Le seul droit qu'il y avait — `get-task-allow` — servait à rendre les pages
    # inspectables depuis Safari, fonction retirée ; il est de toute façon refusé à la
    # notarisation.
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "→ $APP"
