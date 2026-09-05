#!/bin/bash
# Désinstalle Wuji et efface tout ce qu'il a laissé sur la machine.
#
# **Un test qui repart d'un dossier non vide ne prouve rien.** Les réglages, le stockage
# des extensions, les cookies et les autorisations survivent à une simple suppression de
# l'application : on croit alors observer un premier lancement alors qu'on observe le
# précédent. C'est ce qui rend certains défauts invisibles chez soi et évidents chez les
# autres.
#
# **C'est irréversible, et ça touche à vos données** — historique, favoris, session,
# scripts écrits à la main. D'où la liste avant, et la confirmation.
#
#   ./uninstall.sh              montre puis demande
#   ./uninstall.sh --dry-run    montre seulement
#   ./uninstall.sh -y           ne demande pas
set -euo pipefail

BUNDLE="com.wuji.browser"
DRY=false
YES=false
for argument in "$@"; do
    case "$argument" in
        --dry-run|-n) DRY=true ;;
        --yes|-y)     YES=true ;;
        *) echo "argument inconnu : $argument" >&2; exit 2 ;;
    esac
done

# Rangé par ce que ça représente, pas par chemin : on doit pouvoir décider en lisant.
TARGETS=(
    "/Applications/Wuji.app"                                  # l'application
    "$HOME/Library/Application Support/Wuji"                  # historique, favoris, session, scripts, coffre
    "$HOME/Library/Preferences/$BUNDLE.plist"                 # réglages
    "$HOME/Library/WebKit/$BUNDLE"                            # extensions, données des sites
    "$HOME/Library/Caches/$BUNDLE"                            # cache réseau
    "$HOME/Library/HTTPStorages/$BUNDLE"                      # stockage local des sites
    "$HOME/Library/HTTPStorages/$BUNDLE.binarycookies"        # cookies
    "$HOME/Library/Saved Application State/$BUNDLE.savedState" # état des fenêtres
    "$HOME/Library/Cookies/$BUNDLE.binarycookies"             # cookies, ancien emplacement
)

FOUND=()
for target in "${TARGETS[@]}"; do
    [ -e "$target" ] && FOUND+=("$target")
done

if [ ${#FOUND[@]} -eq 0 ]; then
    echo "Rien à effacer : Wuji n'a rien laissé."
    exit 0
fi

echo "À effacer :"
for target in "${FOUND[@]}"; do
    printf "  %-7s %s\n" "$(du -sh "$target" 2>/dev/null | cut -f1)" "$target"
done
echo "  —       autorisations caméra, micro et position accordées à Wuji"

if $DRY; then
    echo
    echo "(--dry-run : rien n'a été touché)"
    exit 0
fi

if ! $YES; then
    echo
    read -r -p "Effacer tout cela ? [o/N] " answer
    case "$answer" in
        o|O|y|Y) ;;
        *) echo "Annulé."; exit 1 ;;
    esac
fi

# L'application d'abord, et on attend qu'elle soit morte : effacer ses fichiers sous elle
# la ferait les réécrire en partant.
osascript -e 'tell application "Wuji" to quit' >/dev/null 2>&1 || true
while pgrep -x Wuji >/dev/null; do sleep 0.2; done

for target in "${FOUND[@]}"; do
    rm -rf "$target"
done

# Les réglages vivent aussi dans le démon des préférences, qui les réécrirait depuis sa
# mémoire au prochain lancement — effacer le fichier ne suffit pas.
defaults delete "$BUNDLE" >/dev/null 2>&1 || true

# Les autorisations sont dans une base du système, hors de tout dossier : sans ça, un
# « premier lancement » hériterait des réponses données à la caméra, au micro et à la
# position.
tccutil reset All "$BUNDLE" >/dev/null 2>&1 || true

# Et ce que LaunchServices garde de l'application, sinon macOS continue de proposer une
# version qui n'existe plus.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "/Applications/Wuji.app" >/dev/null 2>&1 || true

echo "Effacé. Le prochain lancement sera un vrai premier lancement."
