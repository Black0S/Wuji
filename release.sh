#!/bin/bash
# Produit un Wuji.dmg signé, notarisé et agrafé — celui qu'on peut donner à quelqu'un.
#
# **La différence avec dmg.sh tient en un mot : Gatekeeper.** Une signature ad-hoc ne vaut
# que sur la machine qui a compilé ; ailleurs, macOS refuse d'ouvrir l'application et ne
# propose qu'un clic droit → Ouvrir, ce que personne ne devrait avoir à faire pour un
# navigateur. La notarisation est le seul moyen de s'en passer.
#
# Ce qu'il faut, une fois pour toutes :
#
#   1. un certificat « Developer ID Application » — Xcode › Settings › Accounts ›
#      Manage Certificates › + › Developer ID Application. Le certificat « Apple
#      Development » ne convient pas : il sert à tester sur ses propres appareils.
#
#   2. les identifiants de notarisation rangés dans le trousseau :
#      xcrun notarytool store-credentials wuji-notary \
#            --apple-id VOTRE-ID --team-id VOTRE-TEAM --password MOT-DE-PASSE-APP
#
# Le mot de passe est un « app-specific password » créé sur appleid.apple.com, pas celui
# du compte.
set -euo pipefail
cd "$(dirname "$0")"

PROFIL="${WUJI_NOTARY_PROFILE:-wuji-notary}"
DMG="Wuji.dmg"

# L'identité, cherchée dans le trousseau plutôt que codée en dur : elle change de nom à
# chaque renouvellement de certificat.
#
# Le `|| true` n'est pas de la superstition : sans certificat, `grep` ne trouve rien et
# rend 1, ce qui, sous `set -e`, tuait le script **avant** le message qui explique quoi
# faire. Une aide qu'on n'atteint jamais ne vaut pas mieux qu'une absence d'aide.
IDENTITE="${WUJI_IDENTITY:-}"
if [ -z "$IDENTITE" ]; then
    IDENTITE="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
fi

if [ -z "$IDENTITE" ]; then
    cat >&2 <<'AIDE'
Aucun certificat « Developer ID Application » sur cette machine.

Sans lui, on ne peut produire qu'un paquet ad-hoc — celui de ./dmg.sh, qui ne s'ouvre
proprement que sur la machine qui l'a compilé. Il ne sert à rien de continuer : la
notarisation le refuserait.

  Xcode › Settings › Accounts › votre compte › Manage Certificates › + ›
  Developer ID Application    (il faut être Account Holder de l'équipe)
AIDE
    exit 1
fi
echo "→ identité : $IDENTITE"

# ---------------------------------------------------------------- l'application
./build.sh release

# `--options runtime` : le durcissement de l'exécution, exigé par la notarisation. Il
# interdit à d'autres processus de s'injecter dans Wuji — ce qui est bien le moins pour un
# navigateur.
#
# `--timestamp` : un horodatage signé par Apple. Sans lui, la signature expire avec le
# certificat, et une version distribuée cesserait de s'ouvrir un an plus tard.
echo "→ signature"
codesign --force --sign "$IDENTITE" --options runtime --timestamp \
         --generate-entitlement-der .build/Wuji.app

# On vérifie avant d'aller plus loin : la notarisation coûte une minute d'attente, autant
# ne pas l'engager sur un paquet mal formé.
codesign --verify --deep --strict --verbose=2 .build/Wuji.app
spctl --assess --type execute --verbose .build/Wuji.app || true

# ------------------------------------------------------------------------ l'image
echo "→ image disque"
ETAPE="$(mktemp -d)"
trap 'rm -rf "$ETAPE"' EXIT
cp -R .build/Wuji.app "$ETAPE/"
ln -s /Applications "$ETAPE/Applications"
rm -f "$DMG"
hdiutil create -volname "Wuji" -srcfolder "$ETAPE" -ov -format UDZO -quiet "$DMG"

# L'image se signe aussi : c'est elle qu'on télécharge, donc c'est elle que macOS examine
# en premier.
codesign --force --sign "$IDENTITE" --timestamp "$DMG"

# ------------------------------------------------------------------ la notarisation
echo "→ notarisation (une à quelques minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFIL" --wait

# L'agrafage colle le ticket sur l'image : sans lui, une première ouverture sans réseau
# est refusée, alors même que la notarisation a réussi.
echo "→ agrafage"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "→ $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"
echo "  vérification finale :"
spctl --assess --type open --context context:primary-signature -v "$DMG"
