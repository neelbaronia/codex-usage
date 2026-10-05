#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_MODE=host
case "${1-}" in
  "") ;;
  --universal) BUILD_MODE=universal ;;
  -h|--help)
    printf '%s\n' 'Usage: /bin/sh build.sh [--universal]' \
      'Builds a macOS 13+ app for this Mac, or both arm64 and x86_64.' \
      'Default signing is offline/ad hoc. CODE_SIGN_IDENTITY may explicitly select a' \
      'Developer ID Application certificate (name or SHA-1); this enables hardened runtime' \
      'and a secure timestamp, which requires network access.'
    exit 0 ;;
  *) printf '%s\n' "Unknown option: $1" >&2; exit 64 ;;
esac
if [ "$#" -gt 1 ]; then
  printf '%s\n' 'Expected at most one option. Use --help for usage.' >&2
  exit 64
fi

SIGNING_IDENTITY=${CODE_SIGN_IDENTITY:--}
if [ "$SIGNING_IDENTITY" != - ]; then
  # Resolve only the explicitly requested identity. In particular, an Apple
  # Development certificate cannot produce a distributable notarized release.
  SIGNING_HASH=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v requested="$SIGNING_IDENTITY" '
    /"Developer ID Application: / {
      name = substr($0, index($0, "\"") + 1); sub(/"[[:space:]]*$/, "", name)
      if (name == requested || (length(requested) == 40 && toupper($2) == toupper(requested))) print $2
    }
  ')
  if [ -z "$SIGNING_HASH" ] || [ "$(printf '%s\n' "$SIGNING_HASH" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" != 1 ]; then
    printf '%s\n' 'CODE_SIGN_IDENTITY must uniquely match an installed, valid Developer ID Application certificate.' >&2
    exit 1
  fi
  SIGNING_IDENTITY=$SIGNING_HASH
fi

if [ "$BUILD_MODE" = universal ]; then
  ARCHITECTURES='arm64 x86_64'
  OUTPUT_DIR="$PROJECT_DIR/build/universal"
else
  ARCHITECTURES=$(/usr/bin/uname -m)
  case "$ARCHITECTURES" in
    arm64|x86_64) ;;
    *) printf '%s\n' "Unsupported architecture: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  OUTPUT_DIR="$PROJECT_DIR/build"
fi

/usr/bin/plutil -lint "$PROJECT_DIR/Info.plist" >/dev/null
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_DIR/Info.plist")
MINIMUM_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_DIR/Info.plist")
if [ "$MINIMUM_OS" != 13.0 ]; then
  printf '%s\n' 'Info.plist must declare LSMinimumSystemVersion 13.0 to match the build target.' >&2
  exit 1
fi
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$OUTPUT_DIR"
BUILD_TEMP=$(mktemp -d "$OUTPUT_DIR/.codex-usage-build.XXXXXX")
trap 'rm -rf "$BUILD_TEMP"' EXIT
trap 'exit 1' HUP INT TERM
STAGED_APP="$BUILD_TEMP/Codex Usage.app"
APP_DIR="$OUTPUT_DIR/Codex Usage.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

for ARCH in $ARCHITECTURES; do
  xcrun swiftc -swift-version 5 -O \
    -target "$ARCH-apple-macosx13.0" -sdk "$SDK_PATH" \
    -file-prefix-map "$PROJECT_DIR=." -debug-prefix-map "$PROJECT_DIR=." \
    -framework AppKit -framework ServiceManagement \
    "$PROJECT_DIR/Sources/UsageModels.swift" \
    "$PROJECT_DIR/Sources/UsageProvider.swift" \
    "$PROJECT_DIR/Sources/LocalUsageHistory.swift" \
    "$PROJECT_DIR/Sources/UsageForecast.swift" \
    "$PROJECT_DIR/Sources/ModelUsageRates.swift" \
    "$PROJECT_DIR/Sources/ModelPricing.swift" \
    "$PROJECT_DIR/Sources/UsageAnalytics.swift" \
    "$PROJECT_DIR/Sources/AnalyticsViews.swift" \
    "$PROJECT_DIR/Sources/UsageTimeline.swift" \
    "$PROJECT_DIR/Sources/UsageBrand.swift" \
    "$PROJECT_DIR/Sources/Dashboard.swift" \
    "$PROJECT_DIR/Sources/main.swift" \
    -o "$BUILD_TEMP/CodexUsage-$ARCH"
done

if [ "$BUILD_MODE" = universal ]; then
  xcrun lipo -create "$BUILD_TEMP/CodexUsage-arm64" "$BUILD_TEMP/CodexUsage-x86_64" \
    -output "$STAGED_APP/Contents/MacOS/CodexUsage"
  xcrun lipo "$STAGED_APP/Contents/MacOS/CodexUsage" -verify_arch arm64 x86_64
else
  cp "$BUILD_TEMP/CodexUsage-$ARCHITECTURES" "$STAGED_APP/Contents/MacOS/CodexUsage"
fi

# Explicit resource inputs keep local logs, caches, and other workspace files
# out of the app. COPYFILE_DISABLE avoids copying Finder metadata/xattrs.
export COPYFILE_DISABLE=1
cp "$PROJECT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
for RESOURCE in UsageKnot.pdf openai.svg SimpleIcons-LICENSE.md; do
  cp "$PROJECT_DIR/Resources/$RESOURCE" "$STAGED_APP/Contents/Resources/$RESOURCE"
done
for DOCUMENT in LICENSE THIRD_PARTY_NOTICES.md; do
  if [ -f "$PROJECT_DIR/$DOCUMENT" ]; then
    cp "$PROJECT_DIR/$DOCUMENT" "$STAGED_APP/Contents/Resources/$DOCUMENT"
  fi
done

# The default remains offline. Developer ID releases use hardened runtime with
# no exception entitlements: this app does not load third-party code in process.
if [ "$SIGNING_IDENTITY" = - ]; then
  /usr/bin/codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" "$STAGED_APP"
else
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
    --identifier "$BUNDLE_ID" "$STAGED_APP"
  SIGNATURE_DETAILS=$(/usr/bin/codesign -dv --verbose=4 "$STAGED_APP" 2>&1)
  case "$SIGNATURE_DETAILS" in
    *"Authority=Developer ID Application: "*) ;;
    *) printf '%s\n' 'The signed app is missing its Developer ID Application authority.' >&2; exit 1 ;;
  esac
  case "$SIGNATURE_DETAILS" in
    *"(runtime)"*) ;;
    *) printf '%s\n' 'The signed app is missing hardened runtime.' >&2; exit 1 ;;
  esac
  case "$SIGNATURE_DETAILS" in
    *"Timestamp="*) ;;
    *) printf '%s\n' 'The signed app is missing a secure timestamp.' >&2; exit 1 ;;
  esac
fi
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

# Replace only the generated build artifact, after a complete validated build.
# The installed app in ~/Applications is never modified by this script.
if [ -e "$APP_DIR" ]; then
  mv "$APP_DIR" "$BUILD_TEMP/previous.app"
fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
  if [ -e "$BUILD_TEMP/previous.app" ]; then
    mv "$BUILD_TEMP/previous.app" "$APP_DIR"
  fi
  exit 1
fi
printf '%s\n' "$APP_DIR"
