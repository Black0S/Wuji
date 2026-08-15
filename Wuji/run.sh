#!/bin/bash
# Assemble le bundle et le lance.
#
# **`open` ne relance pas une application déjà ouverte**, il la ramène au premier plan : on
# se retrouve alors à tester l'ancien binaire en croyant tester le nouveau. Ce piège a déjà
# coûté un mauvais diagnostic, d'où la fermeture préalable.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh "${1:-debug}"

osascript -e 'tell application "Wuji" to quit' >/dev/null 2>&1 || true
while pgrep -x Wuji >/dev/null; do sleep 0.2; done

open .build/Wuji.app
