#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=
DIST_DIR="$PROJECT_DIR/dist"
REQUIRE_NOTARIZED=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--output-dir)
      OPTION=$1
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' "$OPTION requires a path." >&2; exit 64; }
      if [ "$OPTION" = --app ]; then APP_DIR=$2; else DIST_DIR=$2; fi
      shift 2 ;;
    --require-notarized) REQUIRE_NOTARIZED=true; shift ;;
    -h|--help)
      printf '%s\n' 'Usage: /bin/sh package-release.sh [--app PATH] [--output-dir DIR] [--require-notarized]' \
        'By default, builds and verifies a universal macOS 13+ app and writes a ZIP plus SHA256SUMS.txt to dist/.' \
        '--app packages that existing app without building or signing it.' \
        '--require-notarized also verifies Developer ID, runtime, timestamp, stapled ticket, and Gatekeeper.'
      exit 0 ;;
    *) printf '%s\n' "Unknown option: $1" >&2; exit 64 ;;
  esac
done

if [ -z "$APP_DIR" ]; then
  for DOCUMENT in LICENSE THIRD_PARTY_NOTICES.md; do
    [ -f "$PROJECT_DIR/$DOCUMENT" ] || { printf '%s\n' "Release requires $DOCUMENT at the project root." >&2; exit 1; }
  done
  SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")
  /bin/sh "$PROJECT_DIR/build.sh" --universal
  APP_DIR="$PROJECT_DIR/build/universal/Codex Usage.app"
fi
APP_DIR=$(CDPATH= cd -- "$APP_DIR" && pwd)
if [ "$(basename "$APP_DIR")" != 'Codex Usage.app' ]; then
  printf '%s\n' 'The release app must be named Codex Usage.app.' >&2
  exit 1
fi
BINARY="$APP_DIR/Contents/MacOS/CodexUsage"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
case "$VERSION" in
  ''|*[!0-9A-Za-z._-]*) printf '%s\n' 'The plist version is not safe for a release filename.' >&2; exit 1 ;;
esac
if [ "${SOURCE_VERSION-$VERSION}" != "$VERSION" ]; then
  printf '%s\n' 'Info.plist version changed while building. Run packaging again.' >&2
  exit 1
fi
ARCHIVE_NAME="Codex-Usage-$VERSION-macos-universal.zip"

xcrun lipo "$BINARY" -verify_arch arm64 x86_64
ARCHITECTURES=$(xcrun lipo -archs "$BINARY")
set -- $ARCHITECTURES
if [ "$#" -ne 2 ]; then
  printf '%s\n' 'Release binary must contain exactly arm64 and x86_64.' >&2
  exit 1
fi
for ARCH in arm64 x86_64; do
  if ! xcrun vtool -arch "$ARCH" -show-build "$BINARY" | /usr/bin/awk '
    $1 == "minos" { found = 1; if ($2 != "13.0") invalid = 1 }
    END { if (!found || invalid) exit 1 }
  '; then
    printf '%s\n' "$ARCH slice does not target macOS 13.0." >&2
    exit 1
  fi
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")" = 13.0 ] || {
  printf '%s\n' 'The bundle must declare macOS 13.0 as its minimum version.' >&2; exit 1;
}
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

verify_notarized() {
  SIGNATURE_DETAILS=$(/usr/bin/codesign -dv --verbose=4 "$1" 2>&1)
  case "$SIGNATURE_DETAILS" in
    *"Authority=Developer ID Application: "*) ;;
    *) printf '%s\n' 'Missing Developer ID Application signature.' >&2; return 1 ;;
  esac
  case "$SIGNATURE_DETAILS" in
    *"(runtime)"*) ;;
    *) printf '%s\n' 'Missing hardened runtime.' >&2; return 1 ;;
  esac
  case "$SIGNATURE_DETAILS" in
    *"Timestamp="*) ;;
    *) printf '%s\n' 'Missing secure timestamp.' >&2; return 1 ;;
  esac
  xcrun stapler validate "$1"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$1"
}

# An explicit allowlist prevents packaging local account data, caches, debug
# files, or preferences. Stapler may add Contents/CodeResources to a signed app.
if [ -n "$(/usr/bin/find "$APP_DIR" -type l -print)" ]; then
  printf '%s\n' 'Unexpected symlink in release bundle.' >&2
  exit 1
fi
/usr/bin/find "$APP_DIR" -type f -print | while IFS= read -r FILE; do
  RELATIVE=${FILE#"$APP_DIR"/}
  case "$RELATIVE" in
    Contents/Info.plist|Contents/MacOS/CodexUsage|Contents/_CodeSignature/CodeResources|\
    Contents/Resources/UsageKnot.pdf|Contents/Resources/openai.svg|\
    Contents/Resources/SimpleIcons-LICENSE.md|Contents/Resources/LICENSE|\
    Contents/Resources/THIRD_PARTY_NOTICES.md) ;;
    Contents/CodeResources)
      [ "$REQUIRE_NOTARIZED" = true ] || { printf '%s\n' 'A stapled app requires --require-notarized.' >&2; exit 1; } ;;
    *) printf '%s\n' "Unexpected release file: $RELATIVE" >&2; exit 1 ;;
  esac
done
for RESOURCE in UsageKnot.pdf openai.svg SimpleIcons-LICENSE.md LICENSE THIRD_PARTY_NOTICES.md; do
  [ -f "$APP_DIR/Contents/Resources/$RESOURCE" ] || { printf '%s\n' "Required release resource missing: $RESOURCE" >&2; exit 1; }
done

mkdir -p "$DIST_DIR"
DIST_DIR=$(CDPATH= cd -- "$DIST_DIR" && pwd)
PACKAGE_TEMP=$(mktemp -d "$DIST_DIR/.codex-usage-package.XXXXXX")
trap 'rm -rf "$PACKAGE_TEMP"' EXIT
trap 'exit 1' HUP INT TERM
export COPYFILE_DISABLE=1
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn \
  "$APP_DIR" "$PACKAGE_TEMP/$ARCHIVE_NAME"
/usr/bin/unzip -tq "$PACKAGE_TEMP/$ARCHIVE_NAME" >/dev/null

# Validate the final extracted ZIP before replacing any existing release files.
/usr/bin/ditto -x -k --noextattr --noqtn "$PACKAGE_TEMP/$ARCHIVE_NAME" "$PACKAGE_TEMP/unpacked"
UNPACKED_APP="$PACKAGE_TEMP/unpacked/Codex Usage.app"
test -x "$UNPACKED_APP/Contents/MacOS/CodexUsage"
/usr/bin/codesign --verify --deep --strict "$UNPACKED_APP"
xcrun lipo "$UNPACKED_APP/Contents/MacOS/CodexUsage" -verify_arch arm64 x86_64
if [ "$REQUIRE_NOTARIZED" = true ]; then verify_notarized "$UNPACKED_APP"; fi
(
  cd "$PACKAGE_TEMP"
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS.txt
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
mv "$PACKAGE_TEMP/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME"
mv "$PACKAGE_TEMP/SHA256SUMS.txt" "$DIST_DIR/SHA256SUMS.txt"
printf '%s\n' "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/SHA256SUMS.txt"
