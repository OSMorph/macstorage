#!/usr/bin/env bash
# Signs an app bundle with the project's self-signed certificate (option A in docs/PLAN.md).
# The same certificate is used for every release so macOS keeps Full Disk Access across updates.
#
# Needs: SIGNING_P12_BASE64, SIGNING_P12_PASSWORD (repository secrets), RUNNER_TEMP.
# Usage: ci-sign.sh <app bundle> <bundle id>
set -euo pipefail
app=$1 bundle_id=$2
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cert_pem="$repo_root/signing/macstorage-selfsigned.pem"

keychain="$RUNNER_TEMP/signing.keychain-db"
keychain_password=$(uuidgen)
p12="$RUNNER_TEMP/signing.p12"
printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$p12"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -P "$SIGNING_P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
# Put the temporary keychain first in the search list, keeping the existing ones.
existing=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
# shellcheck disable=SC2086
security list-keychains -d user -s "$keychain" $existing
rm -f "$p12"

identity=$(openssl x509 -in "$cert_pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
echo "Signing identity (SHA-1): $identity"

sign() {
  codesign --force --timestamp=none --sign "$identity" --keychain "$keychain" \
    --identifier "$bundle_id" "$app"
}
if ! sign; then
  echo "Signing failed with an untrusted certificate; trusting it for code signing on this runner and retrying."
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$cert_pem"
  sign
fi

codesign --verify --strict --verbose=2 "$app"
echo "Designated requirement:"
codesign --display --requirements - "$app" 2>&1 | sed -n 's/^designated => /  /p'
codesign --display --verbose=2 "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature)' || true
echo "Gatekeeper assessment (expected to reject: not notarized):"
spctl --assess --type execute --verbose=2 "$app" 2>&1 || true

security delete-keychain "$keychain" || true
