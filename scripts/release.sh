#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="ssut/Barracks"
APP_NAME="Barracks"
APPCAST_BRANCH="gh-pages"
APPCAST_FILE="appcast.xml"
SPARKLE_ACCOUNT="${BARRACKS_SPARKLE_ACCOUNT:-barracks}"
NOTARY_PROFILE="${BARRACKS_NOTARY_PROFILE:-barracks-notary}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NOTES_FILE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) printf '[%s] ERROR unknown option %s\n' "$(date '+%H:%M:%S')" "$1" >&2; exit 64 ;;
    esac
done

log() { printf '[%s] INFO %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

TAG="v$VERSION"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST="$ROOT/dist"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "version malformed value=$VERSION"
case "$VERSION" in *-*) CHANNEL=preview; PRERELEASE=1 ;; *) CHANNEL=stable; PRERELEASE=0 ;; esac

log "preflight version=$VERSION tag=$TAG channel=$CHANNEL dry_run=$DRY_RUN"
git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet || die "tracked changes are not committed"
git -C "$ROOT" fetch -q origin main
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse origin/main)" ]] || die "HEAD is not pushed to origin/main"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then die "release already exists tag=$TAG"; fi

IDENTITY="${BARRACKS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk '{print $2}')}"
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity in the keychain"

swift package --package-path "$ROOT" resolve >/dev/null
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "sparkle tools missing path=$SPARKLE_BIN"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null | tail -1)"
PLIST_KEY="$(plutil -extract SUPublicEDKey raw "$ROOT/Resources/Info.plist")"
[[ -n "$KEYCHAIN_KEY" && "$KEYCHAIN_KEY" == "$PLIST_KEY" ]] || die "sparkle key mismatch account=$SPARKLE_ACCOUNT"
FIREBASE_PLIST="$ROOT/Resources/GoogleService-Info.plist"
[[ -f "$FIREBASE_PLIST" ]] || die "firebase config missing path=$FIREBASE_PLIST"
[[ "$(plutil -extract BUNDLE_ID raw "$FIREBASE_PLIST")" == "$(plutil -extract CFBundleIdentifier raw "$ROOT/Resources/Info.plist")" ]] || die "firebase config bundle id mismatch"
UPLOAD_SYMBOLS="$ROOT/.build/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die "notary profile missing name=$NOTARY_PROFILE (run: xcrun notarytool store-credentials $NOTARY_PROFILE)"
log "preflight ok identity=${IDENTITY:0:8} sparkle_account=$SPARKLE_ACCOUNT notary_profile=$NOTARY_PROFILE"

BARRACKS_VERSION="$VERSION" BARRACKS_BUILD="$BUILD_NUMBER" BARRACKS_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"
APP="$ROOT/build/$APP_NAME.app"
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] || die "bundle version mismatch"
[[ -f "$APP/Contents/Resources/GoogleService-Info.plist" ]] || die "firebase config not bundled"
BIN_DIR="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)"
DSYM="$BIN_DIR/BarracksApp.dSYM"
APP_UUID="$(dwarfdump --uuid "$APP/Contents/MacOS/$APP_NAME" | awk '{print $2}')"
DSYM_UUID="$(dwarfdump --uuid "$DSYM" | awk '{print $2}')"
[[ -n "$APP_UUID" && "$APP_UUID" == "$DSYM_UUID" ]] || die "dsym uuid mismatch app=$APP_UUID dsym=$DSYM_UUID"
log "dsym matched uuid=$APP_UUID"

mkdir -p "$DIST"
"$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "$APP_NAME"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
log "dmg signed path=$DMG bytes=$(wc -c < "$DMG" | tr -d ' ')"

set +e
SUBMIT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format json)"
set -e
STATUS="$(printf '%s' "$SUBMIT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo unknown)"
SUBMISSION="$(printf '%s' "$SUBMIT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "")"
log "notarize submission=$SUBMISSION status=$STATUS"
if [[ "$STATUS" != "Accepted" ]]; then
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization failed status=$STATUS"
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -Eo '/Volumes/.*$' | head -1)"
spctl -a -vv "$MOUNT/$APP_NAME.app"
hdiutil detach "$MOUNT" -quiet
log "notarize status=stapled dmg=$DMG"

if xcrun stapler staple "$APP"; then
    log "app ticket stapled path=$APP"
else
    log "app ticket not stapled; zip relies on online check"
fi
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
log "zip created path=$ZIP bytes=$(wc -c < "$ZIP" | tr -d ' ')"

NOTES="$WORK/notes.md"
if [[ -n "$NOTES_FILE" ]]; then
    cp -f "$NOTES_FILE" "$NOTES"
else
    PREVIOUS="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    RANGE="${PREVIOUS:+$PREVIOUS..}HEAD"
    git -C "$ROOT" log --no-merges --format='- %s' "$RANGE" > "$NOTES"
fi
[[ -s "$NOTES" ]] || printf -- '- Release %s\n' "$VERSION" > "$NOTES"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry run stop before publishing dmg=$DMG zip=$ZIP"
    exit 0
fi

"$UPLOAD_SYMBOLS" -gsp "$FIREBASE_PLIST" -p mac -- "$DSYM"
log "dsym uploaded uuid=$APP_UUID"

FLAGS=(--target "$(git -C "$ROOT" rev-parse HEAD)" --title "$TAG" --notes-file "$NOTES")
[[ "$PRERELEASE" -eq 1 ]] && FLAGS+=(--prerelease)
gh release create "$TAG" "$DMG" "$ZIP" -R "$REPO" "${FLAGS[@]}"
log "release status=created tag=$TAG"

APPCAST_DIR="$WORK/appcast"
if git clone -q --branch "$APPCAST_BRANCH" --depth 1 "git@github.com:$REPO.git" "$APPCAST_DIR" 2>/dev/null; then
    log "appcast branch=existing"
else
    mkdir -p "$APPCAST_DIR"
    git -C "$APPCAST_DIR" init -q
    git -C "$APPCAST_DIR" checkout -q -b "$APPCAST_BRANCH"
    git -C "$APPCAST_DIR" remote add origin "git@github.com:$REPO.git"
    log "appcast branch=created"
fi
python3 "$ROOT/scripts/make-appcast.py" \
    --appcast "$APPCAST_DIR/$APPCAST_FILE" \
    --archive "$DMG" \
    --download-url "https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")" \
    --version "$BUILD_NUMBER" \
    --short-version "$VERSION" \
    --channel "$CHANNEL" \
    --min-system "$(plutil -extract LSMinimumSystemVersion raw "$ROOT/Resources/Info.plist")" \
    --release-notes-file "$NOTES" \
    --full-release-notes-url "https://github.com/$REPO/releases" \
    --sign-update "$SPARKLE_BIN/sign_update" \
    --account "$SPARKLE_ACCOUNT" \
    --feed-url "https://raw.githubusercontent.com/$REPO/$APPCAST_BRANCH/$APPCAST_FILE"
git -C "$APPCAST_DIR" add "$APPCAST_FILE"
git -C "$APPCAST_DIR" commit -q -m "appcast: $TAG ($CHANNEL)"
git -C "$APPCAST_DIR" push -q origin "$APPCAST_BRANCH"
log "appcast status=published url=https://raw.githubusercontent.com/$REPO/$APPCAST_BRANCH/$APPCAST_FILE"
