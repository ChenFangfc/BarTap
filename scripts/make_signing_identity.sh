#!/bin/zsh
# One-time: creates a self-signed code-signing identity in its own keychain, so every build is
# signed by the same certificate. macOS ties privacy grants (Accessibility, Screen Recording) to
# the signature's designated requirement: with ad-hoc signing that is the exact binary hash, so
# each rebuild silently loses the grant; with this identity it is "BarTap + this certificate".
#
#   scripts/make_signing_identity.sh
#
# The private key stays in ~/Library/Keychains/bartap-signing.keychain-db; its password is in
# .signing/ (git-ignored). Never commit either.
set -euo pipefail
cd "$(dirname "$0")/.."
KC=$HOME/Library/Keychains/bartap-signing.keychain-db
NAME="BarTap Self-Signed Code Signing"
if [[ -f $KC ]]; then
  echo "signing keychain already exists: $KC"
  exit 0
fi
OPENSSL=$(command -v openssl)
mkdir -p .signing && chmod 700 .signing
TMP=$(mktemp -d) && trap 'rm -rf "$TMP"' EXIT
PW=$("$OPENSSL" rand -hex 24)
print -rn -- "$PW" > .signing/keychain-password && chmod 600 .signing/keychain-password

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 7300 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
P12PW=$("$OPENSSL" rand -hex 16)
# 3DES/SHA1 PKCS#12: the encryption `security import` understands.
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out "$TMP/id.p12" -passout "pass:$P12PW"

security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# codesign looks identities up through the search list; add ours, keep everything already there.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
cp "$TMP/cert.pem" .signing/certificate.pem
echo "created: $(security find-identity -p codesigning "$KC" | awk -v n="$NAME" 'index($0, n) {print $2; exit}')  $NAME"
