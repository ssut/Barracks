#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${BARRACKS_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${BARRACKS_BUILD:-$(date +%Y%m%d%H%M)}"
IDENTITY="${BARRACKS_SIGN_IDENTITY:--}"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/Barracks.app"
INSTALL=0

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) printf '[%s] ERROR unknown option %s\n' "$(date '+%H:%M:%S')" "$arg" >&2; exit 64 ;;
    esac
done

log() { printf '[%s] INFO %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ "$(uname -m)" == "arm64" ]] || { printf 'Apple Silicon only\n' >&2; exit 1; }
[[ -n "$VERSION" ]] || { printf 'VERSION is empty\n' >&2; exit 1; }

if [[ "$IDENTITY" == "-" ]]; then
    SIGN_FLAGS=(--options runtime)
    SIGN_KIND=adhoc
else
    SIGN_FLAGS=(--options runtime --timestamp)
    SIGN_KIND=developer-id
fi

sign() { codesign --force --sign "$IDENTITY" "${SIGN_FLAGS[@]}" "$@"; }

log "building release binaries version=$VERSION build=$BUILD_NUMBER signing=$SIGN_KIND"
swift build --package-path "$ROOT" -c release --arch arm64 --product BarracksApp
swift build --package-path "$ROOT" -c release --arch arm64 --product barracks
swift build --package-path "$ROOT" -c release --arch arm64 --product barracks-launcher
BIN_DIR="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)"

log "assembling bundle path=$APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp -f "$BIN_DIR/BarracksApp" "$APP/Contents/MacOS/Barracks"
cp -f "$BIN_DIR/barracks" "$APP/Contents/Resources/barracks"
cp -f "$BIN_DIR/barracks-launcher" "$APP/Contents/Resources/barracks-launcher"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

EXTRA_KEY=$( (shasum -a 256 "$ROOT/Resources/extra/extra_port.py"; printf '%s' "$IDENTITY") | shasum -a 256 | cut -c1-16)
EXTRA_OUT="$ROOT/.build/extra-bundle/$EXTRA_KEY"
if [[ ! -f "$EXTRA_OUT/manifest.json" ]]; then
    BARRACKS_SIGN_IDENTITY="$IDENTITY" python3 "$ROOT/Resources/extra/extra_port.py" bundle "$ROOT/.build/extra-src" "$EXTRA_OUT"
fi
rm -rf "$APP/Contents/Resources/Extra"
cp -Rf "$EXTRA_OUT" "$APP/Contents/Resources/Extra"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
"$BIN_DIR/barracks" icon "$APP/Contents/Resources/AppIcon.icns" --barracks
printf 'APPL????' > "$APP/Contents/PkgInfo"

log "signing kind=$SIGN_KIND"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Updater.app"
sign --preserve-metadata=entitlements "$SPARKLE/Autoupdate"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/Resources/barracks"
sign "$APP/Contents/Resources/barracks-launcher"
sign "$APP"
codesign --verify --deep --strict "$APP"
log "built path=$APP version=$VERSION build=$BUILD_NUMBER signing=$SIGN_KIND"

if [[ "$INSTALL" -eq 1 ]]; then
    TARGET="$HOME/Applications/Barracks.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    log "installed path=$TARGET"
fi
