#!/bin/bash
# Optional, run once: creates a self-signed code-signing certificate called "Clean Mirror Local Signing"
# in your login keychain. scripts/make-app.sh then signs with it, so macOS sees rebuilt versions of
# Clean Mirror.app as the same app and keeps its Screen Recording permission.
#
# The certificate only ever exists on this Mac. Its private key is created in a temporary folder,
# imported into the login keychain (with codesign allowed to use it), and the temporary files deleted.
# Keychain Access shows it as "not trusted", which is expected and doesn't matter for this.
# To remove it later: Keychain Access > login > My Certificates > "Clean Mirror Local Signing" > Delete.
set -euo pipefail

NAME="Clean Mirror Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cert.cnf <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# macOS's own openssl (LibreSSL) writes a .p12 the keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
PW=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PW" -name "$NAME"
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -T /usr/bin/codesign

echo "Created \"$NAME\". Run ./scripts/make-app.sh to sign the app with it."
