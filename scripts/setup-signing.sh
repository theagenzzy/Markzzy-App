#!/usr/bin/env bash
# setup-signing.sh
# Crea UN certificado self-signed en tu login keychain para firmar Markzzy
# con una identidad estable. Ejecutar solo una vez.
#
# ¿Por qué? macOS TCC (Camera/Mic/ScreenCapture) asocia los permisos al
# "code signing identity" de la app. Ad-hoc (codesign -s -) genera un hash
# distinto cada rebuild, así que TCC invalida el permiso y vuelve a pedirlo.
# Un cert self-signed es ESTABLE → el permiso persiste.
set -euo pipefail

CERT_NAME="Markzzy Self Sign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ Certificado '$CERT_NAME' ya está instalado."
    exit 0
fi

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

echo "==> Empaquetando en PKCS12..."
P12_PASS="markzzy"
echo "==> Empaquetando en PKCS12 (3DES, compatible con macOS)..."
openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
    -out bundle.p12 -inkey key.pem -in cert.pem \
    -name "$CERT_NAME" -password "pass:$P12_PASS" 2>/dev/null

echo "==> Importando al login keychain..."
security import bundle.p12 -k "$KEYCHAIN" -P "$P12_PASS" -A >/dev/null

# Permite que codesign use la llave sin prompt cada vez (requiere password login)
echo "==> Autorizando codesign (puede pedirte tu password de login)..."
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || {
    echo "    (si no se pudo autorizar sin prompt, la primera firma pedirá keychain — click 'Always Allow')"
}

echo ""
echo "✅ Listo. Ahora corre:"
echo "    ./scripts/install-to-desktop.sh"
