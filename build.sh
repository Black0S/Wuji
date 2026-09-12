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

# **Ad-hoc par défaut, et c'est délibéré.**
#
# Quelqu'un qui clone ce dépôt doit pouvoir taper `./build.sh` et obtenir une application qui
# se lance : pas de compte Apple, pas de certificat, rien à configurer. C'est la condition
# pour qu'un projet ouvert le soit vraiment, et elle passe avant le confort de celui qui en a
# un.
#
# **Ce que l'ad-hoc coûte, mesuré et non supposé.** Un élément de trousseau gardé par
# l'Enclave sécurisée rend -34018 faute du droit `keychain-access-groups`, que seule une
# signature portant un identifiant d'équipe peut déclarer ; et l'empreinte d'une signature
# ad-hoc est celle du binaire, donc elle change à chaque compilation — le trousseau ne
# reconnaît alors jamais l'application d'un lancement à l'autre. Touch ID retombe en
# conséquence sur un fichier gardé par une vérification d'empreinte, ce que les réglages
# écrivent en toutes lettres.
#
# **Qui veut l'Enclave le demande, explicitement.** Une identité prise d'office dans le
# trousseau signerait Wuji avec le certificat qu'une autre équipe y a laissé, et écrirait son
# identifiant d'équipe dans les droits, sans que personne l'ait voulu :
#
#   WUJI_IDENTITY="Apple Development: …"  ./build.sh     — pour une fois
#   echo auto > .identite-signature                      — une fois pour toutes
. "$(dirname "$0")/tools/signature.sh"
# `|| true` en plus du `return 0` de la fonction : une ceinture et des bretelles pour une
# ligne dont l'échec, la dernière fois, a produit un paquet non signé en silence.
IDENTITE="$(wuji_identite || true)"
if [ -n "$IDENTITE" ]; then
    # **On ne retombe pas sur l'ad-hoc en silence.** L'identité a été demandée
    # explicitement ; signer autrement donnerait une application qui ressemble à ce qu'on
    # voulait sans l'être, et l'on chercherait longtemps pourquoi le coffre redemande le
    # mot de passe du trousseau.
    DROITS="$(wuji_droits "$IDENTITE" || true)"
    if [ -n "$DROITS" ]; then
        SIGNE=(codesign --force --sign "$IDENTITE" --entitlements "$DROITS" --generate-entitlement-der "$APP")
    else
        SIGNE=(codesign --force --sign "$IDENTITE" "$APP")
    fi
    if ! "${SIGNE[@]}" >/dev/null 2>&1; then
        {
            echo "Signature impossible avec « $IDENTITE »."
            echo "  Identités disponibles sur cette machine :"
            security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /'
            echo "  Effacez .identite-signature ou videz WUJI_IDENTITY pour revenir à l'ad-hoc."
        } >&2
        exit 1
    fi
    if [ -n "$DROITS" ]; then
        echo "→ signé : $IDENTITE · keychain-access-groups"
    else
        echo "→ signé : $IDENTITE · sans identifiant d'équipe"
        echo "  (Touch ID retombera sur la protection logicielle)"
    fi
else
    # Le cas ordinaire. Le seul droit qu'il y avait — `get-task-allow` — servait à rendre les
    # pages inspectables depuis Safari, fonction retirée ; il est de toute façon refusé à la
    # notarisation.
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "→ $APP"
