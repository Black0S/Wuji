#!/bin/bash
# Vérifie tout ce qui peut l'être sans Xcode : compilation, essais, et cohérence du paquet.
#
# **Pourquoi ce script existe.** `swift test` a besoin du module `Testing`, qui n'est livré
# qu'avec Xcode — sur une machine qui n'a que les outils en ligne de commande, il échoue par
# « no such module 'Testing' » et **aucun** essai n'est vérifié. Le piège est qu'on croit
# alors ne rien avoir cassé, alors qu'on n'a rien regardé.
#
# Ce script tente d'abord la vraie exécution. Si le module manque, il retombe sur un contrôle
# de types : les fichiers d'essai sont réécrits sans `Testing` — `#expect` devient un appel
# ordinaire — et compilés contre les sources. Cela ne prouve pas qu'un essai passe ; cela
# prouve qu'il compile encore contre le code d'aujourd'hui, ce qui attrape tout renommage,
# toute signature changée et toute suppression d'API. C'est le contrôle le plus fort qu'on
# puisse faire ici, et il est meilleur que rien — qui était l'autre option.
set -uo pipefail

cd "$(dirname "$0")"
STATUT=0

echo "→ compilation (debug)"
swift build 2>&1 | tail -3 || STATUT=1

echo "→ compilation (release)"
swift build -c release 2>&1 | tail -3 || STATUT=1

echo "→ essais"
if swift test 2>&1 | tee /tmp/wuji-test.log | tail -5; then
    echo "  essais exécutés."
elif grep -q "no such module 'Testing'" /tmp/wuji-test.log; then
    echo "  module Testing absent (pas d'Xcode) — contrôle de types à la place."
    BAC="$(mktemp -d)"
    trap 'rm -rf "$BAC"' EXIT
    for f in Tests/*.swift; do
        python3 - "$f" "$BAC/$(basename "$f")" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = src.replace("import Testing\n", "").replace("@testable import Wuji", "")
src = re.sub(r'@Test\s+func', 'func', src)
src = re.sub(r'#expect\(', '_ = _essai(', src)
src = re.sub(r'try #require\(', 'try _requis(', src)
src = re.sub(r'#require\(', '_requis(', src)
open(sys.argv[2], 'w').write(src)
PY
    done
    cat > "$BAC/_socle.swift" <<'SWIFT'
func _essai(_ valeur: Bool, _ message: String = "") -> Bool { valeur }
struct _Absent: Error {}
func _requis<T>(_ valeur: T?) throws -> T {
    guard let valeur else { throw _Absent() }
    return valeur
}
SWIFT
    if swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 \
        $(find Sources -name '*.swift') "$BAC"/*.swift 2>&1 | grep -E "error" | head -10; then
        echo "  ✗ le contrôle de types a échoué"
        STATUT=1
    else
        echo "  ✓ $(ls Tests/*.swift | wc -l | tr -d ' ') fichiers d'essai compilent contre les sources"
    fi
else
    echo "  ✗ les essais ont échoué"
    STATUT=1
fi

echo "→ paquet"
./build.sh release >/dev/null && codesign --verify --strict .build/Wuji.app \
    && echo "  ✓ .build/Wuji.app assemblé et signé" || STATUT=1

[ "$STATUT" -eq 0 ] && echo "→ tout est vert" || echo "→ il reste des erreurs"
exit "$STATUT"
