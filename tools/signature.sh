#!/bin/bash
# L'identité de signature et le droit du trousseau — **au même endroit pour tous les scripts**.
#
# Il y avait deux façons de signer Wuji : `build.sh` en ad-hoc, `release.sh` avec l'identité
# Developer ID et le fichier de droits. La seconde savait des choses que la première ignorait,
# et la copie qu'on utilise tous les jours était donc moins capable que celle qu'on publie —
# sans que rien ne le dise. Ce fichier est sourcé par les deux.
#
# **Ce qu'une identité stable change, concrètement.** Le trousseau attache chaque élément à
# l'application qui l'a créé, reconnue à sa signature. Une signature ad-hoc a pour empreinte
# celle du binaire : elle change à chaque compilation, mesuré — deux compilations d'affilée,
# deux CDHash. macOS ne reconnaît alors jamais l'application d'un lancement à l'autre et
# redemande le mot de passe du trousseau à chaque accès. Avec un certificat, l'exigence porte
# sur le certificat et non sur le binaire : elle survit aux recompilations.

# L'identité à utiliser, ou rien. `WUJI_IDENTITY` a le dernier mot.
#
# « Developer ID Application » d'abord, parce que c'est celle qui sert aussi à publier.
# « Apple Development » ensuite : elle ne vaut rien pour la distribution, mais elle porte un
# identifiant d'équipe et elle est stable — c'est tout ce qu'il faut pour compiler chez soi,
# et elle s'obtient en une minute depuis Xcode.
wuji_identite() {
    if [ -n "${WUJI_IDENTITY:-}" ]; then echo "$WUJI_IDENTITY"; return; fi
    local liste
    liste="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local motif
    for motif in "Developer ID Application" "Apple Development" "Apple Distribution"; do
        local trouvee
        trouvee="$(printf '%s\n' "$liste" | grep "$motif" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
        if [ -n "$trouvee" ]; then echo "$trouvee"; return; fi
    done
}

# L'identifiant d'équipe lu dans le certificat, jamais écrit en dur : il diffère d'une
# machine à l'autre, et un fichier de droits codé en dur serait faux pour tout le monde
# sauf une.
wuji_equipe() {
    security find-certificate -c "$1" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | head -1
}

# Écrit le fichier de droits et rend son chemin, ou rien s'il n'y a pas d'équipe.
#
# **Le droit du trousseau est le seul qu'on demande.** Un élément gardé par l'Enclave
# sécurisée — ce qui fait que Touch ID ouvre le coffre sans que rien d'autre ne puisse lire
# la clé — exige `keychain-access-groups`, dont le groupe commence par l'identifiant de
# l'équipe. Sans lui, `SecItemAdd` rend -34018 et Wuji retombe sur un fichier gardé par une
# vérification d'empreinte, ce qu'il dit dans ses réglages plutôt que de laisser croire à
# l'Enclave.
wuji_droits() {
    local identite="$1" fichier="${2:-.build/wuji.entitlements}"
    local equipe
    equipe="$(wuji_equipe "$identite")"
    [ -n "$equipe" ] || { rm -f "$fichier"; return; }
    cat > "$fichier" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key>
  <array><string>${equipe}.com.wuji.browser</string></array>
</dict></plist>
PLIST
    echo "$fichier"
}
