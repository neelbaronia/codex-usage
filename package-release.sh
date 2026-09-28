#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      printf '%s\n' 'Usage: /bin/sh package-release.sh' \
        'Builds and verifies a universal macOS 13+ app, then writes a ZIP and SHA256SUMS.txt to dist/.' \
        'Signing defaults to ad hoc. CODE_SIGN_IDENTITY is honored only when explicitly supplied.'
      exit 0 ;;
    *) printf '%s\n' 'This script takes no arguments. Use --help for usage.' >&2; exit 64 ;;
  esac
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")
case "$VERSION" in
  ''|*[!0-9A-Za-z._-]*) printf '%s\n' 'The plist version is not safe for a release filename.' >&2; exit 1 ;;
esac
for DOCUMENT in LICENSE THIRD_PARTY_NOTICES.md; do
  if [ ! -f "$PROJECT_DIR/$DOCUMENT" ]; then
    printf '%s\n' "Release requires $DOCUMENT at the project root." >&2
    exit 1
  fi
done

/bin/sh "$PROJECT_DIR/build.sh" --universal
APP_DIR="$PROJECT_DIR/build/universal/Codex Usage.app"
BINARY="$APP_DIR/Contents/MacOS/CodexUsage"
DIST_DIR="$PROJECT_DIR/dist"
ARCHIVE_NAME="Codex-Usage-$VERSION-macos-universal.zip"
ARCHIVE="$DIST_DIR/$ARCHIVE_NAME"

xcrun lipo "$BINARY" -verify_arch arm64 x86_64
ARCHITECTURES=$(xcrun lipo -archs "$BINARY")
set -- $ARCHITECTURES
if [ "$#" -ne 2 ]; then
  printf '%s\n' 'Release binary must contain exactly arm64 and x86_64.' >&2
  exit 1
fi
for ARCH in arm64 x86_64; do
  if ! xcrun vtool -arch "$ARCH" -show-build "$BINARY" | /usr/bin/awk '
    $1 == "minos" { found = 1; if ($2 != "13.0") exit 1 }
    END { if (!found) exit 1 }
  '; then
    printf '%s\n' "$ARCH slice does not target macOS 13.0." >&2
    exit 1
  fi
done
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
PACKAGED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
if [ "$PACKAGED_VERSION" != "$VERSION" ]; then
  printf '%s\n' 'Info.plist version changed while building. Run packaging again.' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

# The release has an explicit file allowlist. Never package account data,
# workspace history, caches, debug files, or machine-specific preferences.
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
    *) printf '%s\n' "Unexpected release file: $RELATIVE" >&2; exit 1 ;;
  esac
done
for RESOURCE in UsageKnot.pdf openai.svg SimpleIcons-LICENSE.md LICENSE THIRD_PARTY_NOTICES.md; do
  if [ ! -f "$APP_DIR/Contents/Resources/$RESOURCE" ]; then
    printf '%s\n' "Required release resource missing: $RESOURCE" >&2
    exit 1
  fi
done

mkdir -p "$DIST_DIR"
PACKAGE_TEMP=$(mktemp -d "$DIST_DIR/.codex-usage-package.XXXXXX")
trap 'rm -rf "$PACKAGE_TEMP"' EXIT
trap 'exit 1' HUP INT TERM
export COPYFILE_DISABLE=1
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn \
  "$APP_DIR" "$PACKAGE_TEMP/$ARCHIVE_NAME"
/usr/bin/unzip -tq "$PACKAGE_TEMP/$ARCHIVE_NAME" >/dev/null

# Verify the extracted artifact as well as the source bundle: ZIP attributes
# must preserve the executable and its code signature.
/usr/bin/ditto -x -k --noextattr --noqtn "$PACKAGE_TEMP/$ARCHIVE_NAME" "$PACKAGE_TEMP/unpacked"
UNPACKED_APP="$PACKAGE_TEMP/unpacked/Codex Usage.app"
test -x "$UNPACKED_APP/Contents/MacOS/CodexUsage"
/usr/bin/codesign --verify --deep --strict "$UNPACKED_APP"
xcrun lipo "$UNPACKED_APP/Contents/MacOS/CodexUsage" -verify_arch arm64 x86_64
mv "$PACKAGE_TEMP/$ARCHIVE_NAME" "$ARCHIVE"
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$PACKAGE_TEMP/SHA256SUMS.txt"
)
mv "$PACKAGE_TEMP/SHA256SUMS.txt" "$DIST_DIR/SHA256SUMS.txt"
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
printf '%s\n' "$ARCHIVE" "$DIST_DIR/SHA256SUMS.txt"
