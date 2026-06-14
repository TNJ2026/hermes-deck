#!/usr/bin/env bash
#
# Build Hermes Deck and package separate DMGs for Apple Silicon (arm64)
# and Intel (x86_64).
#
# Prerequisites (run once):
#   sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
#   brew install create-dmg        # already installed if create-dmg is on PATH
#
# Distribution signing + notarization (so others can double-click, no warning):
#   Requires a paid Apple Developer Program account.
#   1. Create a "Developer ID Application" cert (Xcode > Settings > Accounts >
#      Manage Certificates > + > Developer ID Application).
#   2. Store notary credentials once:
#        xcrun notarytool store-credentials "hermes-notary" \
#          --apple-id "you@example.com" --team-id "WAYR2C4W9U" \
#          --password "app-specific-password"
#   3. Run with the two env vars set:
#        DEVID_IDENTITY="Developer ID Application: Name (WAYR2C4W9U)" \
#        NOTARY_PROFILE="hermes-notary" \
#        ./scripts/build_dmg.sh
#
# Without DEVID_IDENTITY the script falls back to ad-hoc signing (local use only;
# other machines need to strip the quarantine flag manually).
#
# Usage:
#   ./scripts/build_dmg.sh             # build both architectures
#   ./scripts/build_dmg.sh arm64       # build only Apple Silicon
#   ./scripts/build_dmg.sh x86_64      # build only Intel
#
set -euo pipefail

PROJECT="hermes_deck.xcodeproj"
SCHEME="hermes_deck"
CONFIG="Release"
APP_NAME="Hermes Deck"

# Distribution config (empty = ad-hoc fallback).
DEVID_IDENTITY="${DEVID_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
mkdir -p "$BUILD" "$DIST"

# Read marketing version for nicer dmg names; fall back to "dev".
VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')"
[ -z "$VERSION" ] && VERSION="dev"

if [ -n "$DEVID_IDENTITY" ]; then
  echo "Signing mode: Developer ID  ($DEVID_IDENTITY)"
  [ -n "$NOTARY_PROFILE" ] && echo "Notarization: profile '$NOTARY_PROFILE'" \
    || echo "Notarization: SKIPPED (set NOTARY_PROFILE to enable)"
else
  echo "Signing mode: ad-hoc (local use only)"
fi

build_arch() {
  local arch="$1" label="$2"
  local archive="$BUILD/HermesDeck-$arch.xcarchive"
  local stage="$BUILD/stage-$arch"
  local dmg="$DIST/HermesDeck-$VERSION-$label.dmg"

  echo "==> Archiving for $arch ($label)"
  rm -rf "$archive" "$stage"
  local args=(
    archive
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -archivePath "$archive"
    -destination "generic/platform=macOS"
    ARCHS="$arch" ONLY_ACTIVE_ARCH=NO
  )
  if [ -n "$DEVID_IDENTITY" ]; then
    # Hardened runtime + timestamp are required for notarization.
    args+=(
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="$DEVID_IDENTITY"
      OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"
      CODE_SIGNING_REQUIRED=YES
      CODE_SIGNING_ALLOWED=YES
    )
  else
    args+=(
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="-"
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGNING_ALLOWED=YES
    )
  fi

  if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "${args[@]}" | xcbeautify
  else
    xcodebuild "${args[@]}"
  fi

  local app="$archive/Products/Applications/$APP_NAME.app"
  [ -d "$app" ] || { echo "ERROR: app not found at $app"; exit 1; }

  if [ -n "$DEVID_IDENTITY" ]; then
    # Deep re-sign the bundle with hardened runtime + secure timestamp.
    echo "==> Developer ID signing $arch"
    codesign --force --deep --timestamp --options runtime \
      --sign "$DEVID_IDENTITY" "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
  else
    echo "==> Ad-hoc signing $arch"
    codesign --force --deep --sign - "$app"
  fi

  echo "==> Staging + creating DMG: $dmg"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  rm -f "$dmg"
  create-dmg \
    --volname "$APP_NAME" \
    --window-size 600 320 \
    --icon-size 120 \
    --icon "$APP_NAME.app" 150 160 \
    --app-drop-link 450 160 \
    "$dmg" "$stage" \
    || hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO "$dmg"

  rm -rf "$stage"

  # Sign the dmg itself + notarize + staple so download-and-open works clean.
  if [ -n "$DEVID_IDENTITY" ]; then
    codesign --force --timestamp --sign "$DEVID_IDENTITY" "$dmg"
  fi
  if [ -n "$DEVID_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing $dmg (waits for Apple)"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling ticket"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -vvv -t open --context context:primary-signature "$dmg" || true
  fi

  echo "==> Done: $dmg"
  echo
}

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(arm64 x86_64)

for t in "${TARGETS[@]}"; do
  case "$t" in
    arm64)  build_arch arm64  AppleSilicon ;;
    x86_64) build_arch x86_64 Intel ;;
    *) echo "Unknown arch: $t (use arm64 or x86_64)"; exit 1 ;;
  esac
done

echo "All DMGs in: $DIST"
ls -lh "$DIST"/*.dmg
