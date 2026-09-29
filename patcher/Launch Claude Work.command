#!/bin/bash
set -euo pipefail

MAIN_APP="/Applications/Claude.app"
MAIN_ASAR="$MAIN_APP/Contents/Resources/app.asar"
SOURCE_APP="$MAIN_APP"
SOURCE_ASAR="$MAIN_ASAR"
TARGET_APP="$HOME/Applications/Claude Work.app"
PROFILE="$HOME/Library/Application Support/Claude-Work"
WORK_CODE_CONFIG="$PROFILE/claude-code-config"
METADATA="$HOME/Applications/.Claude-Work.source"
LOCK_DIR="$HOME/Applications/.Claude-Work.lock"
PORT_ROOT="$HOME/Library/Application Support/Claude-Work-Patcher"
PORT_REPO="$PORT_ROOT/claude-desktop-extra"
PRISTINE_ROOT="$PORT_ROOT/pristine"
MAIN_STATE="$PORT_ROOT/main-source"
BASE_ASAR="$PORT_ROOT/patched-base.asar"
BASE_METADATA="$PORT_ROOT/patched-base.source"
APP_ID="com.anthropic.claudefordesktop.work"
PATCH_VERSION="13"
TMP_DIR=""
STAGE_APP=""
BACKUP_APP=""
MAIN_STAGE_APP=""
MAIN_BACKUP_APP=""
PRISTINE_STAGE_APP=""
MAIN_PATCHED_THIS_RUN=0

log() {
    printf '[%s] INFO %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

remove_tree() {
    python3 - "$1" <<'PYCODE'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PYCODE
}

app_pids() {
    ps -axo pid=,command= | awk -v app="$1" -v required="${2:-}" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0); if (($0 == app || index($0, app " ") == 1) && (required == "" || index($0, required) > 0)) print pid }'
}

die() {
    printf '[%s] ERROR %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        remove_tree "$TMP_DIR"
    fi
    if [[ -n "$STAGE_APP" && -d "$STAGE_APP" ]]; then
        remove_tree "$STAGE_APP"
    fi
    if [[ -n "$MAIN_STAGE_APP" && -d "$MAIN_STAGE_APP" ]]; then
        remove_tree "$MAIN_STAGE_APP"
    fi
    if [[ -n "$PRISTINE_STAGE_APP" && -d "$PRISTINE_STAGE_APP" ]]; then
        remove_tree "$PRISTINE_STAGE_APP"
    fi
    if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || die "This launcher requires macOS."
[[ -d "$MAIN_APP" && -f "$MAIN_ASAR" ]] || die "Claude.app was not found at $MAIN_APP."
command -v node >/dev/null 2>&1 || die "Node.js is required so npx can run the Electron archive tools."
command -v npx >/dev/null 2>&1 || die "npx is required so the launcher can patch Claude's app archive."
command -v codesign >/dev/null 2>&1 || die "codesign is unavailable. Install the Xcode Command Line Tools."
command -v ditto >/dev/null 2>&1 || die "ditto is unavailable."
command -v python3 >/dev/null 2>&1 || die "Python 3 is required by the macOS feature patcher."
command -v git >/dev/null 2>&1 || die "Git is required to sync claude-desktop-extra."
[[ -f "$(dirname "$0")/claude_work_extra_port.py" ]] || die "claude_work_extra_port.py must sit beside this launcher."

mkdir -p "$PORT_ROOT"
if ! UPSTREAM_COMMIT=$(python3 "$(dirname "$0")/claude_work_extra_port.py" sync "$PORT_ROOT"); then
    die "Could not sync the claude-desktop-extra feature source."
fi
[[ "$UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "The upstream feature source returned an invalid commit ID."

mkdir -p "$HOME/Applications" "$PROFILE/Logs" "$WORK_CODE_CONFIG" "$PRISTINE_ROOT"
mkdir "$LOCK_DIR" 2>/dev/null || die "Another Claude Work refresh is already running."

INSTALLED_MAIN_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MAIN_APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAIN_APP/Contents/Info.plist")
INSTALLED_MAIN_HASH=$(shasum -a 256 "$MAIN_ASAR" | awk '{print $1}')
if [[ -f "$MAIN_STATE" ]]; then
    RECORDED_MAIN_VERSION=$(sed -n '1p' "$MAIN_STATE")
    RECORDED_SOURCE_HASH=$(sed -n '2p' "$MAIN_STATE")
    RECORDED_PATCHED_HASH=$(sed -n '3p' "$MAIN_STATE")
    if [[ "$INSTALLED_MAIN_VERSION" == "$RECORDED_MAIN_VERSION" && "$INSTALLED_MAIN_HASH" == "$RECORDED_PATCHED_HASH" && "$RECORDED_SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]]; then
        SOURCE_APP="$PRISTINE_ROOT/Claude-$RECORDED_SOURCE_HASH.app"
        SOURCE_ASAR="$SOURCE_APP/Contents/Resources/app.asar"
        [[ -f "$SOURCE_ASAR" ]] || die "The pristine Claude backup is missing: $SOURCE_APP"
        [[ "$(shasum -a 256 "$SOURCE_ASAR" | awk '{print $1}')" == "$RECORDED_SOURCE_HASH" ]] || die "The pristine Claude backup does not match its recorded hash."
    fi
fi

SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
SOURCE_ASAR_HASH=$(shasum -a 256 "$SOURCE_ASAR" | awk '{print $1}')
SOURCE_STATE=$(printf '%s\n%s\n%s\n%s\n' "$PATCH_VERSION" "$SOURCE_VERSION" "$SOURCE_ASAR_HASH" "$UPSTREAM_COMMIT")
TARGET_ID=""

if [[ -d "$TARGET_APP" ]]; then
    TARGET_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)
    [[ "$TARGET_ID" == "$APP_ID" ]] || die "$TARGET_APP already exists but does not have the expected app identifier."
fi

if [[ -f "$METADATA" && "$(cat "$METADATA")" == "$SOURCE_STATE" && -d "$TARGET_APP" && -f "$BASE_ASAR" && -f "$BASE_METADATA" && "$(cat "$BASE_METADATA")" == "$SOURCE_STATE" ]]; then
    log "Claude Work is current for Claude $SOURCE_VERSION and extras ${UPSTREAM_COMMIT:0:8}."
else
    log "Preparing Claude Work from Claude $SOURCE_VERSION with extras ${UPSTREAM_COMMIT:0:8}."

    if [[ -d "$TARGET_APP" ]]; then
        TARGET_PIDS=$(app_pids "$TARGET_APP/Contents/MacOS/Claude")
        if [[ -n "$TARGET_PIDS" ]]; then
            log "Stopping the running Claude Work clone before refreshing its app bundle."
            while IFS= read -r pid; do
                [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
            done <<< "$TARGET_PIDS"
        for attempt in {1..10}; do
            TARGET_PIDS=$(app_pids "$TARGET_APP/Contents/MacOS/Claude")
            [[ -z "$TARGET_PIDS" ]] && break
            sleep 0.3
            done
            if [[ -n "$TARGET_PIDS" ]]; then
                warn "Claude Work did not exit cleanly; stopping its remaining main process before refresh."
                while IFS= read -r pid; do
                    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
                done <<< "$TARGET_PIDS"
            fi
        fi
    fi

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-work.XXXXXX")
    STAGE_APP="$HOME/Applications/.Claude Work stage-$$.app"
    BACKUP_APP="$HOME/Applications/.Claude Work backup-$$.app"
    ditto "$SOURCE_APP" "$STAGE_APP" || die "Could not copy Claude.app into the staging location."

    CURRENT_SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
    CURRENT_SOURCE_ASAR_HASH=$(shasum -a 256 "$SOURCE_ASAR" | awk '{print $1}')
    [[ "$SOURCE_VERSION" == "$CURRENT_SOURCE_VERSION" && "$SOURCE_ASAR_HASH" == "$CURRENT_SOURCE_ASAR_HASH" ]] || die "Claude.app changed while the clone was being copied. Run the launcher again."

    STAGE_ASAR="$STAGE_APP/Contents/Resources/app.asar"
    [[ -f "$STAGE_ASAR" ]] || die "The staged Claude app does not contain app.asar."
    APP_CONTENTS="$TMP_DIR/app.asar.contents"
    npx --yes @electron/asar extract "$STAGE_ASAR" "$APP_CONTENTS" || die "Could not extract Claude's app archive."
    python3 "$(dirname "$0")/claude_work_extra_port.py" apply "$PORT_REPO" "$APP_CONTENTS" "$TMP_DIR" || die "The upstream macOS feature port did not match this Claude build. The previous Claude Work copy is preserved."

    BUILD_DIR="$APP_CONTENTS/.vite/build"
    PACKAGE_JSON="$APP_CONTENTS/package.json"
    [[ -d "$BUILD_DIR" && -f "$PACKAGE_JSON" ]] || die "Claude's Electron bundle layout changed; the font patch was not applied."

    MAIN_ENTRY=$(node -e 'const p=require(process.argv[1]);process.stdout.write(p.main||"")' "$PACKAGE_JSON")
    [[ -n "$MAIN_ENTRY" ]] || die "Could not identify Claude's Electron main-process entry."


    npx --yes @electron/asar pack "$APP_CONTENTS" "$TMP_DIR/app.asar.base" || die "Could not rebuild Claude's shared app archive."
    node - "$PROFILE" "$WORK_CODE_CONFIG" > "$TMP_DIR/work-profile-bootstrap.js" <<'JSCODE'
const profile = JSON.stringify(process.argv[2]);
const codeConfig = JSON.stringify(process.argv[3]);
process.stdout.write(`;(function(){var a=require("electron").app;var p=${profile};process.env.CLAUDE_PROFILE="Work";process.env.CLAUDE_CONFIG_DIR=${codeConfig};a.setPath("userData",p);a.setPath("logs",p+"/Logs")})()`);
JSCODE
    python3 - "$APP_CONTENTS/$MAIN_ENTRY" "$TMP_DIR/work-profile-bootstrap.js" <<'PYCODE'
from pathlib import Path
import sys
entry = Path(sys.argv[1])
bootstrap = Path(sys.argv[2]).read_text()
source = entry.read_text()
marker = '"use strict";'
if not source.startswith(marker) or not bootstrap:
    raise SystemExit("Claude's main entry changed; Work profile isolation was not applied.")
entry.write_text(marker + bootstrap + ";\n" + source[len(marker):])
PYCODE
    node --check "$APP_CONTENTS/$MAIN_ENTRY" || die "The Claude Work profile bootstrap did not pass JavaScript syntax validation."
    npx --yes @electron/asar pack "$APP_CONTENTS" "$TMP_DIR/app.asar.work" || die "Could not rebuild Claude Work's isolated app archive."
    mv -f "$TMP_DIR/app.asar.work" "$STAGE_ASAR"
    npx --yes @electron/fuses write --app "$STAGE_APP" EnableEmbeddedAsarIntegrityValidation=off || die "Could not update Claude's ASAR integrity fuse."

    SOURCE_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
    while IFS= read -r -d '' plist; do
        bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)
        case "$bundle_id" in
            "$SOURCE_BUNDLE_ID")
                /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID" "$plist"
                ;;
            "$SOURCE_BUNDLE_ID".*)
                suffix=${bundle_id#"$SOURCE_BUNDLE_ID"}
                /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID$suffix" "$plist"
                ;;
        esac
    done < <(find "$STAGE_APP" -type f -name Info.plist -print0)
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Claude Work' "$STAGE_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Claude' "$STAGE_APP/Contents/Info.plist"
    INFO_PLIST="$STAGE_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$INFO_PLIST" 2>/dev/null || true
    if /usr/libexec/PlistBuddy -c 'Print :LSEnvironment:CLAUDE_PROFILE' "$INFO_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c 'Set :LSEnvironment:CLAUDE_PROFILE Work' "$INFO_PLIST"
    else
        /usr/libexec/PlistBuddy -c 'Add :LSEnvironment:CLAUDE_PROFILE string Work' "$INFO_PLIST"
    fi
    if /usr/libexec/PlistBuddy -c 'Print :LSEnvironment:CLAUDE_CONFIG_DIR' "$INFO_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CLAUDE_CONFIG_DIR $WORK_CODE_CONFIG" "$INFO_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CLAUDE_CONFIG_DIR string $WORK_CODE_CONFIG" "$INFO_PLIST"
    fi

    ENTITLEMENTS_FILE="$TMP_DIR/entitlements.plist"
    if codesign -d --entitlements :- "$SOURCE_APP" > "$ENTITLEMENTS_FILE" 2>/dev/null && [[ -s "$ENTITLEMENTS_FILE" ]]; then
        /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$ENTITLEMENTS_FILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.team-identifier' "$ENTITLEMENTS_FILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$ENTITLEMENTS_FILE" 2>/dev/null || true
        codesign --force --deep --sign - --entitlements "$ENTITLEMENTS_FILE" "$STAGE_APP" || die "Could not ad-hoc sign the Claude Work app."
    else
        codesign --force --deep --sign - "$STAGE_APP" || die "Could not ad-hoc sign the Claude Work app."
    fi
    xattr -dr com.apple.quarantine "$STAGE_APP" 2>/dev/null || true
    codesign --verify --deep --strict "$STAGE_APP" || die "The cloned app signature did not verify."

    if [[ -d "$TARGET_APP" ]]; then
        mv -f "$TARGET_APP" "$BACKUP_APP"
    fi
    if mv -f "$STAGE_APP" "$TARGET_APP"; then
        STAGE_APP=""
    else
        if [[ -d "$BACKUP_APP" ]]; then
            mv -f "$BACKUP_APP" "$TARGET_APP"
        fi
        die "Could not install the staged Claude Work app."
    fi
    if [[ -d "$BACKUP_APP" ]]; then
        remove_tree "$BACKUP_APP"
    fi
    cp -f "$TMP_DIR/app.asar.base" "$BASE_ASAR" || die "Could not save the shared Claude patch archive."
    printf '%s\n%s\n%s\n%s\n' "$PATCH_VERSION" "$SOURCE_VERSION" "$SOURCE_ASAR_HASH" "$UPSTREAM_COMMIT" > "$TMP_DIR/patched-base.source"
    mv -f "$TMP_DIR/patched-base.source" "$BASE_METADATA"
    printf '%s\n%s\n%s\n%s\n' "$PATCH_VERSION" "$SOURCE_VERSION" "$SOURCE_ASAR_HASH" "$UPSTREAM_COMMIT" > "$METADATA"
    log "Installed Claude Work as a separate app with identifier $APP_ID."
fi

TARGET_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")
[[ "$TARGET_VERSION" == "$SOURCE_VERSION" ]] || die "The Claude Work version does not match its pristine Claude source."
[[ -f "$TARGET_APP/Contents/Resources/app.asar" ]] || die "The patched Claude Work archive is missing."
PATCHED_ASAR="$BASE_ASAR"
[[ -f "$PATCHED_ASAR" ]] || die "The shared Claude patch archive is missing."
PATCHED_ASAR_HASH=$(shasum -a 256 "$PATCHED_ASAR" | awk '{print $1}')

if [[ "$INSTALLED_MAIN_VERSION" == "$SOURCE_VERSION" && "$INSTALLED_MAIN_HASH" == "$PATCHED_ASAR_HASH" ]]; then
    log "Main Claude already has the same font and Extra patches."
else
    log "Preparing the same font and Extra patches for main Claude."
    PRISTINE_APP="$PRISTINE_ROOT/Claude-$SOURCE_ASAR_HASH.app"
    if [[ ! -d "$PRISTINE_APP" ]]; then
        [[ "$SOURCE_APP" == "$MAIN_APP" ]] || die "The pristine Claude source is unavailable."
        PRISTINE_STAGE_APP="$PRISTINE_ROOT/.Claude-$SOURCE_ASAR_HASH-stage-$$.app"
        ditto "$MAIN_APP" "$PRISTINE_STAGE_APP" || die "Could not save the original Claude app."
        [[ "$(shasum -a 256 "$PRISTINE_STAGE_APP/Contents/Resources/app.asar" | awk '{print $1}')" == "$SOURCE_ASAR_HASH" ]] || die "Claude changed while the original app was being saved."
        mv -f "$PRISTINE_STAGE_APP" "$PRISTINE_APP" || die "Could not install the pristine Claude backup."
        PRISTINE_STAGE_APP=""
        log "Saved the pristine Claude app before patching main Claude."
    fi
    [[ "$(shasum -a 256 "$PRISTINE_APP/Contents/Resources/app.asar" | awk '{print $1}')" == "$SOURCE_ASAR_HASH" ]] || die "The pristine Claude backup has the wrong archive hash."

    if [[ -z "$TMP_DIR" ]]; then
        TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-main.XXXXXX")
    fi
    MAIN_STAGE_APP="/Applications/.Claude main stage-$$.app"
    MAIN_BACKUP_APP="/Applications/.Claude main backup-$$.app"
    ditto "$PRISTINE_APP" "$MAIN_STAGE_APP" || die "Could not stage main Claude."
    cp -f "$PATCHED_ASAR" "$MAIN_STAGE_APP/Contents/Resources/app.asar" || die "Could not copy the patched archive into main Claude."
    npx --yes @electron/fuses write --app "$MAIN_STAGE_APP" EnableEmbeddedAsarIntegrityValidation=off || die "Could not update main Claude's ASAR integrity fuse."

    MAIN_ENTITLEMENTS_FILE="$TMP_DIR/main-entitlements.plist"
    if codesign -d --entitlements :- "$PRISTINE_APP" > "$MAIN_ENTITLEMENTS_FILE" 2>/dev/null && [[ -s "$MAIN_ENTITLEMENTS_FILE" ]]; then
        /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$MAIN_ENTITLEMENTS_FILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.team-identifier' "$MAIN_ENTITLEMENTS_FILE" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$MAIN_ENTITLEMENTS_FILE" 2>/dev/null || true
        codesign --force --deep --sign - --entitlements "$MAIN_ENTITLEMENTS_FILE" "$MAIN_STAGE_APP" || die "Could not sign the patched main Claude app."
    else
        codesign --force --deep --sign - "$MAIN_STAGE_APP" || die "Could not sign the patched main Claude app."
    fi
    xattr -dr com.apple.quarantine "$MAIN_STAGE_APP" 2>/dev/null || true
    codesign --verify --deep --strict "$MAIN_STAGE_APP" || die "The patched main Claude signature did not verify."
    [[ "$(shasum -a 256 "$MAIN_STAGE_APP/Contents/Resources/app.asar" | awk '{print $1}')" == "$PATCHED_ASAR_HASH" ]] || die "The staged main Claude archive differs from the shared patch archive."

    CURRENT_MAIN_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MAIN_APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAIN_APP/Contents/Info.plist")
    CURRENT_MAIN_HASH=$(shasum -a 256 "$MAIN_ASAR" | awk '{print $1}')
    [[ "$CURRENT_MAIN_VERSION" == "$INSTALLED_MAIN_VERSION" && "$CURRENT_MAIN_HASH" == "$INSTALLED_MAIN_HASH" ]] || die "Main Claude changed while the patched app was being staged. Run the launcher again."

    MAIN_PIDS=$(app_pids "$MAIN_APP/Contents/MacOS/Claude")
    if [[ -n "$MAIN_PIDS" ]]; then
        log "Stopping main Claude before installing its patched app bundle."
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
        done <<< "$MAIN_PIDS"
        for attempt in {1..10}; do
            MAIN_PIDS=$(app_pids "$MAIN_APP/Contents/MacOS/Claude")
            [[ -z "$MAIN_PIDS" ]] && break
            sleep 0.3
        done
        if [[ -n "$MAIN_PIDS" ]]; then
            warn "Main Claude did not exit cleanly; stopping its remaining process before refresh."
            while IFS= read -r pid; do
                [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
            done <<< "$MAIN_PIDS"
        fi
    fi

    mv -f "$MAIN_APP" "$MAIN_BACKUP_APP" || die "Could not move the previous main Claude app aside."
    if mv -f "$MAIN_STAGE_APP" "$MAIN_APP"; then
        MAIN_STAGE_APP=""
    else
        mv -f "$MAIN_BACKUP_APP" "$MAIN_APP" || true
        die "Could not install the patched main Claude app."
    fi
    if ! codesign --verify --deep --strict "$MAIN_APP"; then
        MAIN_STAGE_APP="/Applications/.Claude main failed-$$.app"
        mv -f "$MAIN_APP" "$MAIN_STAGE_APP" || true
        mv -f "$MAIN_BACKUP_APP" "$MAIN_APP" || true
        die "The installed main Claude signature failed verification; the prior app was restored."
    fi
    remove_tree "$MAIN_BACKUP_APP"
    printf '%s\n%s\n%s\n%s\n%s\n' "$SOURCE_VERSION" "$SOURCE_ASAR_HASH" "$PATCHED_ASAR_HASH" "$PATCH_VERSION" "$UPSTREAM_COMMIT" > "$TMP_DIR/main-source"
    mv -f "$TMP_DIR/main-source" "$MAIN_STATE"
    MAIN_PATCHED_THIS_RUN=1
    log "Installed the shared font and Extra patches into main Claude and verified its signature."
fi

LEGACY_PIDS=$(app_pids "$MAIN_APP/Contents/MacOS/Claude" "--user-data-dir=$PROFILE")
if [[ -n "$LEGACY_PIDS" ]]; then
    log "Stopping the original Claude process that currently owns the Claude-Work profile."
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done <<< "$LEGACY_PIDS"
    for attempt in {1..30}; do
        LEGACY_PIDS=$(app_pids "$MAIN_APP/Contents/MacOS/Claude" "--user-data-dir=$PROFILE")
        [[ -z "$LEGACY_PIDS" ]] && break
        sleep 0.5
    done
    if [[ -n "$LEGACY_PIDS" ]]; then
        warn "The original Claude profile process did not exit cleanly; stopping its remaining main process."
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
        done <<< "$LEGACY_PIDS"
    fi
fi

if [[ "$MAIN_PATCHED_THIS_RUN" -eq 1 ]]; then
    log "Launching patched main Claude with its existing profile."
    open -a "$MAIN_APP"
fi

WORK_PIDS=$(app_pids "$TARGET_APP/Contents/MacOS/Claude")
if [[ -n "$WORK_PIDS" ]]; then
    log "Claude Work is already running with its isolated profile."
else
    log "Launching Claude Work with profile $PROFILE."
    open -a "$TARGET_APP" --args "--user-data-dir=$PROFILE"
fi
