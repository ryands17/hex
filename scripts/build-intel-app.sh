#!/bin/sh
# Fork-only: build Hex.app for this Intel Mac and sign it with a stable,
# self-signed identity, so macOS keeps Microphone and Accessibility grants
# across rebuilds (an ad-hoc signature changes with every build).
#
#   scripts/build-intel-app.sh            build target/app/Hex.app
#   scripts/build-intel-app.sh --install  also replace /Applications/Hex.app
#
# The first run creates the "Hex Local Signing" certificate in the login
# keychain and asks once for your password to trust it for code signing.
# Override the name with HEX_LOCAL_SIGN_IDENTITY.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
identity=${HEX_LOCAL_SIGN_IDENTITY:-Hex Local Signing}
keychain="$HOME/Library/Keychains/login.keychain-db"

ensure_identity() {
  if security find-identity -v -p codesigning "$keychain" | grep -qF "\"$identity\""; then
    return
  fi
  echo "Creating the self-signed code-signing identity \"$identity\"." >&2
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$identity" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  # macOS's importer reads only the older PKCS#12 algorithms.
  openssl pkcs12 -export -legacy -passout pass:hex \
    -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/identity.p12"
  security import "$work/identity.p12" -k "$keychain" -P hex -T /usr/bin/codesign >&2
  echo "macOS asks for your password to trust the certificate for code signing." >&2
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
  rm -rf "$work"
  trap - EXIT
  security find-identity -v -p codesigning "$keychain" | grep -qF "\"$identity\"" || {
    echo "The identity \"$identity\" is not valid for code signing." >&2
    exit 1
  }
}

ensure_identity

bundle=$(HEX_RELEASE_UNSIGNED=1 HEX_LOCAL_BUILD=1 "$root/scripts/build-app.sh")
case "$(lipo -archs "$bundle/Contents/MacOS/hex")" in
  x86_64) ;;
  *) echo "Expected an x86_64 executable in $bundle." >&2; exit 1 ;;
esac

# Sign again, inside out, in the same order and with the same identifiers
# as scripts/build-app.sh.
sign() { codesign --force --sign "$identity" "$@"; }
sign "$bundle/Contents/Library/HexMicrophone.driver"
sign --identifier anomaly.hex.scrawl-helper "$bundle/Contents/MacOS/scrawl-helper"
sign --entitlements "$root/.github/release/hex.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"

if [ "${1:-}" = --install ]; then
  installed=/Applications/Hex.app
  "$root/target/release/hex" quit >/dev/null 2>&1 || true
  attempts=15
  while pgrep -f "$installed/Contents/MacOS/hex" >/dev/null; do
    [ "$attempts" -gt 0 ] || { echo "Hex did not quit." >&2; exit 1; }
    attempts=$((attempts - 1))
    sleep 1
  done
  rm -rf "$installed"
  ditto "$bundle" "$installed"
  open "$installed"
  echo "$installed"
else
  echo "$bundle"
fi
