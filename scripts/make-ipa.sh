#!/bin/bash
# Builds an unsigned Orbrisa IPA for sideloading (Sideloadly & co. sign it with your Apple ID).
#
#   ./scripts/make-ipa.sh            → Orbrisa-<version>-unsigned.ipa in the project folder
#   ./scripts/make-ipa.sh ~/Desktop  → same, but saved to the given folder
#
# Needs a Mac with Xcode. No Apple ID or signing setup required.

set -euo pipefail

# Resolve the output folder before changing directory, so relative paths work too.
if [ -n "${1:-}" ]; then
    mkdir -p "$1"
    OUTPUT_DIR="$(cd "$1" && pwd)"
fi
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR}"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/Build/Products/Release-appletvos/Orbrisa.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "✗ xcodebuild not found – install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

echo "▸ Building Orbrisa (Release, tvOS, unsigned) …"
xcodebuild -project Orbrisa.xcodeproj -scheme Orbrisa -configuration Release \
    -sdk appletvos -destination 'generic/platform=tvOS' -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    -quiet build

if [ ! -d "$APP" ]; then
    echo "✗ Build finished, but Orbrisa.app was not found at $APP" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo dev)"
# Beta builds carry their label in the name, e.g. Orbrisa-1.1.0-Beta-1-unsigned.ipa
LABEL="$(/usr/libexec/PlistBuddy -c 'Print :OrbrisaReleaseLabel' "$APP/Info.plist" 2>/dev/null || true)"
if [ -n "$LABEL" ]; then
    VERSION="$VERSION-${LABEL// /-}"
fi
IPA="$OUTPUT_DIR/Orbrisa-$VERSION-unsigned.ipa"

echo "▸ Packing $(basename "$IPA") …"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
rm -f "$IPA"
(cd "$STAGING" && zip -qry "$IPA" Payload)

echo "✓ Done: $IPA ($(du -h "$IPA" | cut -f1))"
echo "  Install it on your Apple TV with a sideloading tool such as Sideloadly."
