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

# La racine du dépôt, pour trouver `.identite-signature` d'où qu'on appelle le script.
WUJI_RACINE="${WUJI_RACINE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# L'identité pour une compilation locale — **et seulement si on la demande**.
#
# **Le défaut est l'ad-hoc, et ce n'est pas un repli.** Quelqu'un qui clone le dépôt doit
# pouvoir taper `./build.sh` et obtenir une application qui se lance : pas de compte Apple,
# pas de certificat, rien à configurer. C'est la condition pour qu'un projet ouvert le soit
# vraiment, et elle passe avant le confort de celui qui a un compte.
#
# **Et chercher tout seul serait pire que de ne rien faire** : on signerait Wuji avec le
# certificat qu'une autre équipe a laissé dans le trousseau, en écrivant son identifiant
# d'équipe dans les droits, sans que personne l'ait demandé.
#
# Deux façons de le demander, toutes deux explicites :
#
#   WUJI_IDENTITY="Apple Development: …"  ./build.sh     — pour une fois
#   echo auto > .identite-signature                      — une fois pour toutes
#
# `auto` cherche dans le trousseau : « Developer ID Application » d'abord, puisqu'elle sert
# aussi à publier ; « Apple Development » ensuite — elle ne vaut rien pour la distribution,
# mais elle est stable et porte un identifiant d'équipe, ce qui suffit chez soi et s'obtient
# en une minute depuis Xcode.
wuji_identite() {
    local demande="${WUJI_IDENTITY:-}"
    if [ -z "$demande" ] && [ -f "$WUJI_RACINE/.identite-signature" ]; then
        demande="$(tr -d '[:space:]' < "$WUJI_RACINE/.identite-signature" | head -1)"
    fi
    [ -n "$demande" ] || return
    if [ "$demande" != "auto" ]; then echo "$demande"; return; fi

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
