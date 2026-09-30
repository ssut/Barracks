#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="ssut/Barracks"
P12=""
API_KEY=""
ISSUER=""
SPARKLE_ACCOUNT="barracks"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --p12) P12="$2"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --issuer) ISSUER="$2"; shift 2 ;;
        *) printf 'usage: %s --api-key AuthKey_XXXX.p8 --issuer <issuer-id> [--p12 DeveloperID.p12]\n' "$0" >&2; exit 64 ;;
    esac
done

log() { printf '[%s] INFO %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

[[ -f "$API_KEY" ]] || die "api key file missing (--api-key)"
KEY_ID="$(basename "$API_KEY" .p8 | sed -E 's/^AuthKey_//')"
[[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || die "cannot read key id from file name $API_KEY"
[[ "$ISSUER" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "issuer id malformed (--issuer)"
FIREBASE="$ROOT/Resources/GoogleService-Info.plist"
[[ -f "$FIREBASE" ]] || die "firebase config missing path=$FIREBASE"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_keys" ]] || die "run 'swift package resolve' first"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

P12_PASSWORD="$(openssl rand -base64 24)"
if [[ -z "$P12" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
    [[ -n "$IDENTITY" ]] || die "no Developer ID Application identity in the keychain"
    P12="$WORK/developer-id.p12"
    cat > "$WORK/export.swift" <<'SWIFT'
import CryptoKit
import Foundation
import Security
let args = CommandLine.arguments
let wanted = args[1].uppercased(), output = args[2], passphrase = args[3]
let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { exit(2) }
for identity in identities {
    var certificate: SecCertificate?
    SecIdentityCopyCertificate(identity, &certificate)
    guard let certificate else { continue }
    let sha = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
    guard sha == wanted else { continue }
    var params = SecItemImportExportKeyParameters()
    params.passphrase = Unmanaged.passUnretained(passphrase as CFString)
    var data: CFData?
    guard SecItemExport(identity, .formatPKCS12, [], &params, &data) == errSecSuccess, let data else { exit(3) }
    try (data as Data).write(to: URL(filePath: output))
    exit(0)
}
exit(4)
SWIFT
    log "exporting Developer ID ${IDENTITY:0:8} (approve the keychain prompt)"
    xcrun swift "$WORK/export.swift" "$IDENTITY" "$P12" "$P12_PASSWORD" || die "developer id export failed"
else
    [[ -f "$P12" ]] || die "p12 missing path=$P12"
    read -rs -p "Password for $(basename "$P12"): " P12_PASSWORD
    echo
fi

"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$WORK/sparkle.key" >/dev/null
[[ -s "$WORK/sparkle.key" ]] || die "sparkle key export failed"

set_secret() { gh secret set "$1" -R "$REPO" >/dev/null; log "secret set name=$1"; }
base64 -i "$P12" | set_secret MACOS_CERTIFICATE_P12_BASE64
printf '%s' "$P12_PASSWORD" | set_secret MACOS_CERTIFICATE_PASSWORD
base64 -i "$API_KEY" | set_secret APPLE_API_KEY_P8_BASE64
printf '%s' "$KEY_ID" | set_secret APPLE_API_KEY_ID
printf '%s' "$ISSUER" | set_secret APPLE_API_ISSUER_ID
set_secret SPARKLE_ED_PRIVATE_KEY < "$WORK/sparkle.key"
base64 -i "$FIREBASE" | set_secret GOOGLE_SERVICE_INFO_PLIST_BASE64
log "all release secrets set repo=$REPO"
