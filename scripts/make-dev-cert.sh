#!/bin/bash
# Create a stable self-signed code-signing identity in a DEDICATED keychain whose
# password we control. This lets us authorize codesign non-interactively (partition
# list), so TCC grants persist across rebuilds with zero keychain prompts.
# Idempotent. The keychain password protects only a throwaway dev cert — not sensitive.
set -euo pipefail
CN="SessionMaster Dev Cert"
KC_NAME="sessionmaster-dev.keychain-db"
KC="$HOME/Library/Keychains/$KC_NAME"
PW="smdev"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "Dev signing keychain already configured: $KC"
  exit 0
fi

# Remove any earlier copy from the login keychain (it would trigger prompts).
security delete-certificate -c "$CN" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true

TMP="$(mktemp -d)"
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
# -legacy: Apple's `security` can't verify OpenSSL 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:"$PW" -name "$CN"

security delete-keychain "$KC_NAME" 2>/dev/null || true
security create-keychain -p "$PW" "$KC_NAME"
security set-keychain-settings "$KC"                       # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -A -T /usr/bin/codesign
# Authorize codesign to use the key without a GUI prompt (known keychain password).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1

# Append (not replace) the dev keychain to the user search list so codesign finds the
# identity by name. Preserves the login keychain and anything else already present.
CUR=$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')
if ! grep -qF "$KC" <<<"$CUR"; then
  security list-keychains -d user -s $CUR "$KC"
fi

rm -rf "$TMP"

echo "Configured dev signing keychain: $KC"
security find-identity -p codesigning "$KC" | grep "$CN" || { echo "ERROR: identity missing"; exit 1; }
