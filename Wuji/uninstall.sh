#!/bin/bash
#
# Désinstallation complète de Wuji.
#
# Par défaut, ce script **ne supprime rien** : il affiche ce qu'il supprimerait. C'est
# délibéré — un script de désinstallation qui efface au premier lancement ne laisse aucune
# chance de vérifier qu'il vise juste.
#
#   ./uninstall.sh              liste ce qui serait supprimé
#   ./uninstall.sh --confirmer  supprime pour de bon
#
# Ne touche que ce qui porte le nom de Wuji ou son identifiant : aucun chemin générique,
# aucun joker qui pourrait attraper autre chose.
set -uo pipefail

BUNDLE_ID="com.wuji.browser"
APP_NAME="Wuji"
DRY_RUN=1
[ "${1:-}" = "--confirmer" ] && DRY_RUN=0

echo "Désinstallation de $APP_NAME ($BUNDLE_ID)"
[ $DRY_RUN -eq 1 ] && echo "→ SIMULATION. Relancer avec --confirmer pour supprimer." || echo "→ SUPPRESSION RÉELLE."
echo

# Les emplacements que macOS crée pour une application, un par un et nommément.
TARGETS=(
  "/Applications/$APP_NAME.app"
  "$HOME/Applications/$APP_NAME.app"

  # Les données de Wuji : session, réglages, listes de filtres, userscripts.
  "$HOME/Library/Application Support/$APP_NAME"

  # Les dépôts que le système remplit tout seul pour le compte de l'app.
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  "$HOME/Library/Containers/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
  "$HOME/Library/Cookies/$BUNDLE_ID.binarycookies"
  "$HOME/Library/Logs/$APP_NAME"

  # WebKit garde le stockage des sites visités hors du dossier de l'app : sans cette
  # ligne, une désinstallation laisserait derrière elle localStorage, IndexedDB et les
  # bases des sites — soit précisément ce qu'on promet de ne pas laisser traîner.
  "$HOME/Library/WebKit/$BUNDLE_ID"
)

FOUND=0
for path in "${TARGETS[@]}"; do
  if [ -e "$path" ]; then
    FOUND=1
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    echo "  ✗ $path  (${size:-?})"
    [ $DRY_RUN -eq 0 ] && rm -rf "$path"
  fi
done

if [ $FOUND -eq 0 ]; then
  echo "  Rien trouvé — l'application est déjà désinstallée."
fi

echo
if [ $DRY_RUN -eq 0 ]; then
  # L'application tourne peut-être encore : la laisser vivante réécrirait ses fichiers
  # juste après leur suppression.
  pkill -f "$APP_NAME.app" 2>/dev/null && echo "  ✗ processus $APP_NAME arrêté"

  # Les autorisations accordées à l'app (caméra, micro, position) vivent dans la base de
  # confidentialité du système, hors de tout dossier. Sans cette remise à zéro, réinstaller
  # Wuji retrouverait des permissions qu'on croyait effacées.
  tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 && echo "  ✗ autorisations système réinitialisées"

  # Le registre des applications garde une entrée même après suppression du bundle.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "/Applications/$APP_NAME.app" >/dev/null 2>&1

  echo
  echo "Désinstallation terminée."
else
  echo "Rien n'a été supprimé."
fi
