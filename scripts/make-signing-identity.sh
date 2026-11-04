#!/bin/zsh
# Create a local, self-signed code-signing identity for OpenClicky builds in its own keychain.
# A stable identity keeps macOS privacy permissions (microphone, screen recording, accessibility) across
# rebuilds; codesign can use it without a Keychain prompt because the key's partition list allows codesign.
# The keychain password only protects this throwaway signing key on this Mac.
set -euo pipefail
NAME="OpenClicky Local Signing"
KC="$HOME/Library/Keychains/openclicky-signing.keychain-db"
PW="openclicky-local"
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists in $KC"; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$PW" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$PW"
[[ -f "$KC" ]] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# Add to the search list so codesign finds it, keeping the existing keychains.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "Created \"$NAME\" in $KC"
