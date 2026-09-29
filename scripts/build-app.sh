#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${BARRACKS_VERSION:-0.1.0}"
BUILD_NUMBER="${BARRACKS_BUILD:-$(date +%Y%m%d%H%M)}"
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

log "building release binaries version=$VERSION build=$BUILD_NUMBER"
swift build --package-path "$ROOT" -c release --arch arm64 --product BarracksApp
swift build --package-path "$ROOT" -c release --arch arm64 --product barracks
swift build --package-path "$ROOT" -c release --arch arm64 --product barracks-launcher
BIN_DIR="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)"

log "assembling bundle path=$APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN_DIR/BarracksApp" "$APP/Contents/MacOS/Barracks"
cp -f "$BIN_DIR/barracks" "$APP/Contents/Resources/barracks"
cp -f "$BIN_DIR/barracks-launcher" "$APP/Contents/Resources/barracks-launcher"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
"$BIN_DIR/barracks" icon "$APP/Contents/Resources/AppIcon.icns" --barracks
printf 'APPL????' > "$APP/Contents/PkgInfo"

log "signing ad-hoc"
codesign --force --sign - --options runtime "$APP/Contents/Resources/barracks"
codesign --force --sign - "$APP/Contents/Resources/barracks-launcher"
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
log "built path=$APP"

if [[ "$INSTALL" -eq 1 ]]; then
    TARGET="$HOME/Applications/Barracks.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    log "installed path=$TARGET"
fi
