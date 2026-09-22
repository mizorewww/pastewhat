#!/bin/bash
set -euo pipefail

# Create a persistent self-signed code-signing identity for local builds.
# Ad-hoc signing changes the cdhash on every build, and macOS privacy grants
# (Accessibility, clipboard access) are tied to the signature's designated
# requirement — so every rebuild silently invalidates them. A stable identity
# keeps the designated requirement constant, so grants survive rebuilds.
# Idempotent: does nothing if the identity already exists.

IDENTITY="PasteWhat Development"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Signing identity already exists: $IDENTITY"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = PasteWhat Development
[ ext ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -days 3650 \
    -config "$work/cert.cnf" -out "$work/cert.pem" 2>/dev/null
# -legacy: OpenSSL 3's default PKCS#12 encryption is not accepted by Security.framework.
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
    -passout pass:pastewhat -out "$work/identity.p12"

security import "$work/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P pastewhat -T /usr/bin/codesign
# codesign only lists identities whose chain reaches a trusted anchor; a
# self-signed root must be marked trusted (one-time, may prompt).
security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$work/cert.pem" || true

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "The identity was imported but is not visible to codesign." >&2
    exit 1
fi

echo "Created signing identity: $IDENTITY (valid 10 years)"
echo "On the first signed build macOS may ask to let codesign use this key — choose \"Always Allow\"."
echo "build-app.sh picks this identity automatically; PASTEWHAT_SIGNING_IDENTITY still overrides it."
