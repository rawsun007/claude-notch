#!/bin/bash
# Create a STABLE self-signed code-signing identity so macOS keeps your
# Accessibility / Input Monitoring grants across rebuilds & updates.
#
# Why: ad-hoc signing (`codesign -s -`) gives every build a different code
# hash, so TCC treats each new ClaudeNotch as a brand-new app and the
# permission ticks reset. A self-signed cert with a fixed identity keeps the
# app's "designated requirement" constant, so the grants stick.
#
# DEVELOPMENT ONLY, and only needed on a machine without the release
# certificate. Published releases are signed with the Developer ID
# (team PS8FJ3MQB2) and notarized, which gives the same stable identity plus
# everything this cannot: Gatekeeper acceptance and an Apple-anchored chain a
# user can verify. If build.sh reports "Code signed with Developer ID", you do
# not need this script and running it changes nothing about your builds.
#
# Kept because the fallback tier it feeds still exists, and a contributor
# without the certificate would otherwise re-grant Accessibility and Input
# Monitoring after every single rebuild. See SIGNING.md.
#
# Run this ONCE. macOS may ask for your login password to add the key.
set -euo pipefail

CN="ClaudeNotch Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity 2>/dev/null | grep -q "$CN"; then
    echo "✓ Signing identity already present: $CN"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 7300 -nodes -config "$TMP/openssl.cnf" >/dev/null 2>&1
# -legacy: openssl 3.x defaults to a PKCS12 MAC that macOS `security` can't
# verify; the legacy (SHA1/3DES) format imports cleanly.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:claudenotch -name "$CN" >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:claudenotch -name "$CN" >/dev/null 2>&1

# Import with -A so codesign can use the private key without an ACL prompt
# (no keychain password needed). The cert stays untrusted, which is fine —
# signing only needs the key, and TCC matches the (stable) cert, not trust.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P claudenotch -A >/dev/null 2>&1

echo "✓ Created signing identity: $CN"
echo "  Now run ./build.sh && ./install.sh — builds are signed with this"
echo "  stable identity, so your Accessibility / Input Monitoring grants"
echo "  persist across rebuilds and updates."
