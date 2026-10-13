#!/usr/bin/env bash
# build.sh — compile + assemble .app.
# Flags:
#   --install   copy to /Applications, refresh Launch Services, relaunch Dock
#   --run       kill running instance and open fresh
#   --sign      sign with Apple Development / Developer ID cert + hardened runtime
#               (defaults to the first codesigning identity in your keychain)
#   (combine freely: `bash build.sh --sign --install --run`)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Launcher"
BUNDLE_ID="com.github.hormold.launcher"
APP_DIR="${APP_NAME}.app"
INSTALL_DIR="/Applications/${APP_DIR}"

DO_INSTALL=0
DO_RUN=0
DO_SIGN=0
SIGN_ID=""
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        --run)     DO_RUN=1 ;;
        --sign)    DO_SIGN=1 ;;
        --sign=*)  DO_SIGN=1; SIGN_ID="${arg#*=}" ;;
        *) echo "unknown flag: $arg"; exit 2 ;;
    esac
done

echo "→ swift build -c release"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi

echo "→ generating app icon"
ICON_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET_DIR="${ICON_WORK_DIR}/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" icon.png --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" icon.png --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o Resources/AppIcon.icns

echo "→ assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

if [ "$DO_SIGN" = "1" ]; then
    # Auto-pick first codesigning identity if not supplied.
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID="$(security find-identity -v -p codesigning | awk -F\" 'NR==1{print $2}')"
        if [ -z "$SIGN_ID" ]; then
            echo "✗ no codesigning identity found in keychain"
            exit 1
        fi
    fi
    echo "→ signing with: $SIGN_ID (+ hardened runtime)"
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGN_ID" \
        "$APP_DIR"
    echo "→ verifying signature"
    codesign --verify --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/    /'
    spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/    /' || true
else
    # Ad-hoc sign (local use only).
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

echo "✓ built $APP_DIR"

if [ "$DO_INSTALL" = "1" ]; then
    echo "→ installing to ${INSTALL_DIR}"
    # Kill running instance before overwriting binary (dyld will crash otherwise).
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    # In-place replace contents (preserves /Applications dir inode).
    mkdir -p "$INSTALL_DIR"
    ditto "$APP_DIR" "$INSTALL_DIR"
    codesign --verify --deep --strict "$INSTALL_DIR"
    touch "$INSTALL_DIR"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR" >/dev/null 2>&1 || true
    killall Dock 2>/dev/null || true
    echo "✓ installed"
fi

if [ "$DO_RUN" = "1" ]; then
    TARGET="$APP_DIR"
    [ "$DO_INSTALL" = "0" ] || TARGET="$INSTALL_DIR"
    echo "→ launching $TARGET"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.2
    open "$TARGET"
fi

if [ "$DO_INSTALL" = "0" ] && [ "$DO_RUN" = "0" ]; then
    echo "  run:     bash build.sh --run"
    echo "  install: bash build.sh --install"
    echo "  both:    bash build.sh --install --run"
fi
