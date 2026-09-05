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

# **On ne publie que ce qui est dans l'historique.**
#
# Le script compile l'arbre de travail, pas un commit. Sans cette barrière, un `.dmg`
# distribué pourrait contenir du code qui n'existe nulle part — impossible à retrouver, à
# corriger ou à vérifier par qui que ce soit. Sur un projet ouvert, c'est la promesse même
# du dépôt qui tombe.
if [ -n "$(git status --porcelain)" ]; then
    echo "Dépôt modifié. Commitez ou remisez avant de publier :" >&2
    git status --short >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
# Le numéro de construction est le nombre de commits : il augmente tout seul, ne se
# néglige jamais, et dit exactement d'où vient le paquet.
CONSTRUCTION="$(git rev-list --count HEAD)"
echo "→ version $VERSION ($CONSTRUCTION) · $(git rev-parse --short HEAD)"

# Les tests avant la signature, pas après. Signer d'abord reviendrait à apposer son nom
# sur du code qu'on n'a pas vérifié — et c'est précisément ce que la signature affirme.
echo "→ tests"
swift test 2>&1 | tail -1

# ---------------------------------------------------------------- l'application
./build.sh release

# Le numéro de construction est posé dans le paquet, donc avant la signature qui le scelle.
plutil -replace CFBundleVersion -string "$CONSTRUCTION" .build/Wuji.app/Contents/Info.plist

# `--options runtime` : le durcissement de l'exécution, exigé par la notarisation. Il
# interdit à d'autres processus de s'injecter dans Wuji — ce qui est bien le moins pour un
# navigateur.
#
# `--timestamp` : un horodatage signé par Apple. Sans lui, la signature expire avec le
# certificat, et une version distribuée cesserait de s'ouvrir un an plus tard.
# **Le droit du trousseau, et pourquoi il est fabriqué ici.**
#
# Un élément de trousseau gardé par l'Enclave sécurisée — c'est ce qui fait que Touch ID
# ouvre le coffre — demande `keychain-access-groups`, dont le groupe commence par
# l'identifiant de l'équipe. Cet identifiant est dans le certificat, pas dans le dépôt :
# l'écrire en dur ferait un fichier faux pour tout le monde sauf une machine. On le lit
# donc dans l'identité qu'on vient de trouver, et on écrit le fichier au moment de signer.
#
# Sans ce droit, `SecItemAdd` rend -34018 et Wuji retombe sur sa protection logicielle —
# ce qu'il dit alors dans ses réglages, plutôt que de laisser croire à l'Enclave.
EQUIPE="$(security find-certificate -c "$IDENTITE" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | head -1)"
DROITS=".build/wuji.entitlements"
if [ -n "$EQUIPE" ]; then
  cat > "$DROITS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key>
  <array><string>${EQUIPE}.com.wuji.browser</string></array>
</dict></plist>
PLIST
  echo "→ droits : keychain-access-groups ${EQUIPE}.com.wuji.browser"
else
  echo "→ droits : identifiant d'équipe introuvable, signature sans keychain-access-groups"
  echo "  (Touch ID retombera sur la protection logicielle)"
  rm -f "$DROITS"
fi

echo "→ signature"
if [ -f "$DROITS" ]; then
  codesign --force --sign "$IDENTITE" --options runtime --timestamp \
           --entitlements "$DROITS" --generate-entitlement-der .build/Wuji.app
else
  codesign --force --sign "$IDENTITE" --options runtime --timestamp \
           --generate-entitlement-der .build/Wuji.app
fi

# On vérifie avant d'aller plus loin : la notarisation coûte une minute d'attente, autant
# ne pas l'engager sur un paquet mal formé.
codesign --verify --deep --strict --verbose=2 .build/Wuji.app
spctl --assess --type execute --verbose .build/Wuji.app || true

# --------------------------------------------------------------- la notarisation
# **L'application part chez Apple avant l'image, et pas l'inverse.**
#
# Notariser l'image seule suffit à la faire ouvrir : Gatekeeper trouve son ticket agrafé au
# moment du téléchargement. Mais l'application qu'on glisse ensuite dans `/Applications`
# n'en porte aucun — elle est alors vérifiée en ligne au premier lancement, et refusée si
# la machine est hors réseau ce jour-là. Vérifié : `stapler validate Wuji.app` répondait
# « does not have a ticket stapled to it ».
#
# On notarise donc l'application, on lui agrafe son ticket, **puis** on construit l'image
# autour d'elle. Les deux chemins portent alors leur preuve.
echo "→ notarisation de l'application (une à quelques minutes)"
ARCHIVE="$(mktemp -d)/Wuji.zip"
ditto -c -k --keepParent .build/Wuji.app "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFIL" --wait

echo "→ agrafage de l'application"
xcrun stapler staple .build/Wuji.app
xcrun stapler validate .build/Wuji.app

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

echo "→ notarisation de l'image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFIL" --wait

# L'agrafage colle le ticket sur l'image : sans lui, une première ouverture sans réseau
# est refusée, alors même que la notarisation a réussi.
echo "→ agrafage de l'image"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "→ $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))  ·  version $VERSION ($CONSTRUCTION)"
echo "  vérifications finales :"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v .build/Wuji.app
echo
echo "  pour publier :"
echo "    git tag -a v$VERSION -m \"Wuji $VERSION\" && git push origin v$VERSION"
echo "    puis déposer $DMG dans la release du même nom"
