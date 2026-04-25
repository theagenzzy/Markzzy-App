#!/usr/bin/env bash
# setup-signing.sh
# Crea UN certificado self-signed en tu login keychain para firmar Markzzy
# con una identidad estable, y autoriza a /usr/bin/codesign para usar la
# llave privada SIN preguntar password en cada build.
#
# ¿Por qué? macOS TCC (Camera/Mic/ScreenCapture) asocia los permisos al
# "code signing identity" de la app. Ad-hoc (codesign -s -) genera un hash
# distinto cada rebuild, así que TCC invalida el permiso y vuelve a pedirlo.
# Un cert self-signed es ESTABLE → el permiso persiste.
#
# El segundo problema (lo que te volvía loco): la "partition list" de la
# llave privada controla qué procesos pueden firmar con ella sin diálogo.
# Si no se setea bien, codesign te abre el "permitir keychain" 3-5 veces
# por build (una por cada binario anidado de Sparkle).
set -euo pipefail

CERT_NAME="Markzzy Self Sign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Pide el password de login una sola vez y lo usa para autorizar la
# partition list. Si el password es incorrecto, falla en ALTO (no swallow).
authorize_partition_list() {
    echo ""
    echo "==> Autorizando codesign para usar la llave sin pedir password en cada build."
    echo ""
    echo "    macOS necesita tu password de LOGIN (el mismo que usás para"
    echo "    desbloquear tu Mac). Lo necesita UNA sola vez para grabar que"
    echo "    /usr/bin/codesign tiene permiso de firmar con esta llave."
    echo ""
    # Read silently so the password doesn't show on screen.
    local password
    if ! IFS= read -r -s -p "    Password de login: " password; then
        echo ""
        echo "    ❌ No se pudo leer el password (¿estás corriendo este script no-interactivo?)"
        exit 1
    fi
    echo ""
    echo ""
    if [ -z "$password" ]; then
        echo "    ❌ Password vacío — abortando."
        exit 1
    fi

    # Unlock keychain explicitly (so the next operation doesn't hit a stale
    # "locked" state from a long idle session).
    if ! security unlock-keychain -p "$password" "$KEYCHAIN" 2>/dev/null; then
        echo "    ❌ Password incorrecto — no se pudo desbloquear el keychain."
        echo "       Volvé a correr este script con el password correcto."
        exit 1
    fi

    # The actual partition-list update. Note: we DON'T redirect stderr to
    # /dev/null here on purpose — if it fails we want to see why.
    if security set-key-partition-list \
        -S apple-tool:,apple:,codesign:,unsigned: \
        -s -k "$password" "$KEYCHAIN"; then
        echo ""
        echo "    ✅ Partition list autorizada para /usr/bin/codesign."
    else
        echo ""
        echo "    ❌ set-key-partition-list falló (ver error arriba)."
        echo "       Probable causa: el password no coincide con el del keychain"
        echo "       de login. Si cambiaste tu password de login en macOS sin"
        echo "       sincronizar el keychain, abrí Keychain Access.app y desde"
        echo "       el menú File > Change Password for Keychain 'login'…"
        exit 1
    fi
}

# Quick sanity check: is /usr/bin/codesign already trusted? We test by
# trying to read the private key with a no-op operation and seeing whether
# it requires user interaction. If the cert exists AND the partition list is
# already correct, we can skip the password prompt entirely.
already_authorized() {
    [ -z "$1" ] && return 1
    local cert_sha="$1"
    # Sign /tmp/.markzzy-codesign-probe (a tiny binary copy) and check that
    # codesign exits 0 without producing any "user interaction required" or
    # keychain-prompt output. If it just works, we know the partition list is
    # already in good shape.
    local probe="/tmp/.markzzy-codesign-probe"
    cp /usr/bin/true "$probe" 2>/dev/null || return 1
    if codesign --force --sign "$cert_sha" "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

# ---- main flow ----

if security find-identity -p codesigning -v "$KEYCHAIN" | grep -q "$CERT_NAME" \
   || security find-identity -p codesigning "$KEYCHAIN" | grep -q "$CERT_NAME"; then
    CERT_SHA=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
        | awk '/SHA-1 hash:/ {print $NF}' | head -1)
    echo "✅ Certificado '$CERT_NAME' ya está instalado ($CERT_SHA)."

    if already_authorized "$CERT_SHA"; then
        echo "✅ /usr/bin/codesign ya está autorizado — no se necesita password."
        echo ""
        echo "Listo. Corre: ./scripts/install-to-desktop.sh"
        exit 0
    fi

    echo "   Pero la partition list todavía pide confirmación. Re-autorizando…"
    authorize_partition_list

    # Verify it actually worked.
    if already_authorized "$CERT_SHA"; then
        echo ""
        echo "✅ Listo. Corre: ./scripts/install-to-desktop.sh"
        exit 0
    else
        echo ""
        echo "❌ La autorización quedó pero codesign sigue prompteando."
        echo "   Revisá Keychain Access.app → login → llave 'Markzzy Self Sign' →"
        echo "   click derecho → Get Info → Access Control → 'Allow all applications'"
        echo "   (o agregá /usr/bin/codesign manualmente)."
        exit 1
    fi
fi

# ---- cert doesn't exist yet — generate one ----

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > config.cnf <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ext
[dn]
CN = $CERT_NAME
O = Markzzy Local
[v3_ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generando certificado self-signed..."
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 3650 -nodes -config config.cnf 2>/dev/null

echo "==> Empaquetando en PKCS12 (3DES, compatible con macOS)..."
P12_PASS="markzzy"
openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
    -out bundle.p12 -inkey key.pem -in cert.pem \
    -name "$CERT_NAME" -password "pass:$P12_PASS" 2>/dev/null

echo "==> Importando al login keychain..."
# -A: cualquier app puede usar la llave (necesario combinado con partition list).
# -T: explícitamente permite estas tools sin diálogo (refuerzo).
security import bundle.p12 -k "$KEYCHAIN" -P "$P12_PASS" -A \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign >/dev/null

# Always run the partition-list authorization step on a fresh import.
authorize_partition_list

CERT_SHA=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
    | awk '/SHA-1 hash:/ {print $NF}' | head -1)

if already_authorized "$CERT_SHA"; then
    echo ""
    echo "✅ Listo. Corre: ./scripts/install-to-desktop.sh"
else
    echo ""
    echo "⚠️  Importado pero la verificación final falló."
    echo "   Probá correr de nuevo este script."
    exit 1
fi
