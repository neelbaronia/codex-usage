#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_DIR=
OUTPUT_DIR="$PROJECT_DIR/dist"
DS_STORE=
BACKGROUND="$PROJECT_DIR/Resources/dmg-background.tiff"
LAYOUT_PYTHON=${DMG_LAYOUT_PYTHON:-python3}
REVISION=
if [ -f "$PROJECT_DIR/Resources/dmg-layout.dsstore" ]; then
  DS_STORE="$PROJECT_DIR/Resources/dmg-layout.dsstore"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app|--output-dir|--ds-store)
      OPTION=$1
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' "$OPTION requires a path." >&2; exit 64; }
      case "$OPTION" in
        --app) APP_DIR=$2 ;;
        --output-dir) OUTPUT_DIR=$2 ;;
        --ds-store) DS_STORE=$2 ;;
      esac
      shift 2 ;;
    --revision)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' '--revision requires a positive integer.' >&2; exit 64; }
      case "$2" in
        *[!0-9]*|0*) printf '%s\n' '--revision must be a positive integer without leading zeros.' >&2; exit 64 ;;
      esac
      REVISION=$2
      shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: /bin/sh package-dmg.sh --app PATH [--output-dir DIR] [--ds-store PATH] [--revision N]' \
        'Packages an existing Developer ID signed, stapled, universal app into a read-only UDZO disk image.' \
        'The app is never rebuilt, re-signed, or modified. The default output directory is dist/.' \
        'Uses Resources/dmg-layout.dsstore when present; --ds-store overrides that Finder layout template.' \
        'Includes Resources/dmg-background.tiff as the hidden drag-to-Applications background.' \
        'Requires ds-store==1.3.3 and mac-alias==2.2.3 in DMG_LAYOUT_PYTHON (default: python3).' \
        'An optional positive --revision N adds -rN to the DMG filename without changing the app version.' \
        'Set CODE_SIGN_IDENTITY explicitly to a Developer ID Application name or SHA-1 to sign the DMG with a secure timestamp.' \
        'Without that variable the DMG itself is unsigned. Outer-DMG notarization and checksums are separate release steps.' \
        'Existing output files are never overwritten; ZIP releases and their checksums are untouched.'
      exit 0 ;;
    *) printf '%s\n' "Unknown option: $1" >&2; exit 64 ;;
  esac
done
[ -n "$APP_DIR" ] || { printf '%s\n' '--app is required; supply the existing notarized app.' >&2; exit 64; }
APP_DIR=$(CDPATH= cd -- "$APP_DIR" && pwd)
[ "$(basename "$APP_DIR")" = 'Codex Usage.app' ] || { printf '%s\n' 'The app must be named Codex Usage.app.' >&2; exit 1; }
if [ -n "$DS_STORE" ]; then
  [ -f "$DS_STORE" ] || { printf '%s\n' 'The supplied .DS_Store template is not a file.' >&2; exit 1; }
fi
[ -f "$BACKGROUND" ] || { printf '%s\n' 'Missing Resources/dmg-background.tiff; regenerate the DMG background before packaging.' >&2; exit 1; }
if ! "$LAYOUT_PYTHON" -c 'from importlib.metadata import version; import ds_store, mac_alias; assert version("ds-store") == "1.3.3"; assert version("mac-alias") == "2.2.3"' >/dev/null 2>&1; then
  printf '%s\n' 'DMG layout generation requires Python with ds-store==1.3.3 and mac-alias==2.2.3.' \
    'Prepare an isolated build environment from the project directory:' \
    '  python3 -m venv build/dmg-layout-venv' \
    '  build/dmg-layout-venv/bin/python -m pip install ds-store==1.3.3 mac-alias==2.2.3' \
    'Then set DMG_LAYOUT_PYTHON="$PWD/build/dmg-layout-venv/bin/python" when running this script.' >&2
  exit 1
fi

SIGNING_IDENTITY=${CODE_SIGN_IDENTITY-}
if [ -n "$SIGNING_IDENTITY" ]; then
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
fi

/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
case "$VERSION" in ''|*[!0-9A-Za-z._-]*) printf '%s\n' 'The app version is not safe for a release filename.' >&2; exit 1 ;; esac
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" = com.nbaronia.codex-usage ] || {
  printf '%s\n' 'Unexpected app bundle identifier.' >&2; exit 1;
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")" = 13.0 ] || {
  printf '%s\n' 'The supplied app must target macOS 13.0.' >&2; exit 1;
}
DMG_NAME="Codex-Usage-$VERSION-macos-universal${REVISION:+-r$REVISION}.dmg"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)
FINAL_DMG="$OUTPUT_DIR/$DMG_NAME"
[ ! -e "$FINAL_DMG" ] || { printf '%s\n' "Output already exists: $FINAL_DMG. Choose another output directory." >&2; exit 1; }

verify_developer_id() {
  SIGNATURE_DETAILS=$(/usr/bin/codesign -dv --verbose=4 "$1" 2>&1)
  case "$SIGNATURE_DETAILS" in *"Authority=Developer ID Application: "*) ;; *) printf '%s\n' 'Missing Developer ID Application signature.' >&2; return 1 ;; esac
  case "$SIGNATURE_DETAILS" in *"Timestamp="*) ;; *) printf '%s\n' 'Missing secure timestamp.' >&2; return 1 ;; esac
}
verify_app() {
  /usr/bin/codesign --verify --deep --strict "$1"
  verify_developer_id "$1"
  case "$SIGNATURE_DETAILS" in *"(runtime)"*) ;; *) printf '%s\n' 'The app is missing hardened runtime.' >&2; return 1 ;; esac
  xcrun lipo "$1/Contents/MacOS/CodexUsage" -verify_arch arm64 x86_64
  [ "$(xcrun lipo -archs "$1/Contents/MacOS/CodexUsage" | /usr/bin/wc -w | /usr/bin/tr -d ' ')" = 2 ] || {
    printf '%s\n' 'Expected exactly arm64 and x86_64 app slices.' >&2; return 1;
  }
  for ARCH in arm64 x86_64; do
    if ! xcrun vtool -arch "$ARCH" -show-build "$1/Contents/MacOS/CodexUsage" | /usr/bin/awk '
      $1 == "minos" { found = 1; if ($2 != "13.0") invalid = 1 }
      END { if (!found || invalid) exit 1 }
    '; then
      printf '%s\n' "$ARCH app slice does not target macOS 13.0." >&2
      return 1
    fi
  done
  xcrun stapler validate "$1"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$1"
}
app_manifest() {
  (
    cd "$1"
    /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r FILE; do
      /usr/bin/shasum -a 256 "$FILE"
    done
  )
}
verify_app "$APP_DIR"
[ -z "$(/usr/bin/find "$APP_DIR" -type l -print)" ] || { printf '%s\n' 'Unexpected symlink inside the app bundle.' >&2; exit 1; }

PACKAGE_TEMP=$(mktemp -d "$OUTPUT_DIR/.codex-usage-dmg.XXXXXX")
MOUNT_POINT="$PACKAGE_TEMP/mounted"
MOUNT_ACTIVE=false
cleanup() {
  # Never recursively remove the staging directory while its disk image is
  # mounted. Preserve it and print recovery details if detach fails.
  if [ "$MOUNT_ACTIVE" = true ]; then
    if /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet; then MOUNT_ACTIVE=false; else
      printf '%s\n' "Could not detach $MOUNT_POINT. Staging files retained at $PACKAGE_TEMP." >&2
      return
    fi
  fi
  /bin/rm -rf "$PACKAGE_TEMP"
}
trap 'cleanup' EXIT
trap 'exit 130' HUP INT TERM
mkdir -p "$PACKAGE_TEMP/contents" "$MOUNT_POINT"
app_manifest "$APP_DIR" > "$PACKAGE_TEMP/original-app.sha256"
export COPYFILE_DISABLE=1
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP_DIR" "$PACKAGE_TEMP/contents/Codex Usage.app"
/bin/ln -s /Applications "$PACKAGE_TEMP/contents/Applications"
cat > "$PACKAGE_TEMP/contents/Install Codex Usage.txt" <<'INSTALL'
Install Codex Usage

1. Drag Codex Usage.app onto Applications.
2. Open Codex Usage from Applications.
3. Look for the logo and percentage in your Mac's menu bar.

Requires macOS 13 or later and the Codex desktop app or CLI. If you have not
signed in yet, open Terminal, run `codex`, and choose “Sign in with ChatGPT”.
Codex Usage will show these steps if it detects that sign-in is needed. No API
key or separate Codex Usage account is needed.

If replacing an older copy, choose Settings > Quit in the widget first.
After copying the app, eject this disk image.
INSTALL
cp "$BACKGROUND" "$PACKAGE_TEMP/contents/.background.tiff"
if [ -n "$DS_STORE" ]; then cp "$DS_STORE" "$PACKAGE_TEMP/contents/.DS_Store"; fi
app_manifest "$PACKAGE_TEMP/contents/Codex Usage.app" > "$PACKAGE_TEMP/staged-app.sha256"
/usr/bin/cmp "$PACKAGE_TEMP/original-app.sha256" "$PACKAGE_TEMP/staged-app.sha256"

STAGED_DMG="$PACKAGE_TEMP/$DMG_NAME"
WRITABLE_DMG="$PACKAGE_TEMP/writable.dmg"
/usr/bin/hdiutil create -srcfolder "$PACKAGE_TEMP/contents" -volname 'Codex Usage' \
  -fs HFS+ -format UDRW -nospotlight "$WRITABLE_DMG"

# Finder needs the background's IDs and creation dates from this HFS+ image.
# An alias generated in the staging folder or copied from another image can
# resolve to the wrong volume when another Codex Usage image is mounted.
MOUNT_ACTIVE=true
/usr/bin/hdiutil attach "$WRITABLE_DMG" -readwrite -nobrowse -noautoopen -owners off \
  -mountpoint "$MOUNT_POINT" -plist > "$PACKAGE_TEMP/writable-attachment.plist"
if [ -n "$DS_STORE" ]; then
  "$LAYOUT_PYTHON" "$PROJECT_DIR/scripts/generate-dmg-layout.py" \
    --volume-root "$MOUNT_POINT" --output "$MOUNT_POINT/.DS_Store" --template "$DS_STORE"
else
  "$LAYOUT_PYTHON" "$PROJECT_DIR/scripts/generate-dmg-layout.py" \
    --volume-root "$MOUNT_POINT" --output "$MOUNT_POINT/.DS_Store"
fi
cp "$MOUNT_POINT/.DS_Store" "$PACKAGE_TEMP/contents/.DS_Store"
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_ACTIVE=false

/usr/bin/hdiutil convert "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 -o "$STAGED_DMG"
/usr/bin/hdiutil verify "$STAGED_DMG"
[ "$(/usr/bin/hdiutil imageinfo -format "$STAGED_DMG")" = UDZO ] || { printf '%s\n' 'Expected a read-only UDZO disk image.' >&2; exit 1; }
if [ -n "$SIGNING_IDENTITY" ]; then
  /usr/bin/codesign --sign "$SIGNING_HASH" --timestamp \
    --identifier com.nbaronia.codex-usage.dmg "$STAGED_DMG"
  /usr/bin/codesign --verify --strict "$STAGED_DMG"
  verify_developer_id "$STAGED_DMG"
fi

# Set the cleanup guard before attach so an interrupted attach cannot cause
# the mounted filesystem to be deleted by the staging cleanup.
mkdir -p "$MOUNT_POINT"
MOUNT_ACTIVE=true
/usr/bin/hdiutil attach "$STAGED_DMG" -readonly -nobrowse -noautoopen -owners off \
  -mountpoint "$MOUNT_POINT" -plist > "$PACKAGE_TEMP/attachment.plist"
[ -L "$MOUNT_POINT/Applications" ] && [ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" = /Applications ] || {
  printf '%s\n' 'The mounted Applications shortcut is incorrect.' >&2; exit 1;
}
/usr/bin/cmp "$PACKAGE_TEMP/contents/Install Codex Usage.txt" "$MOUNT_POINT/Install Codex Usage.txt"
/usr/bin/cmp "$BACKGROUND" "$MOUNT_POINT/.background.tiff"
/usr/bin/cmp "$PACKAGE_TEMP/contents/.DS_Store" "$MOUNT_POINT/.DS_Store"
app_manifest "$MOUNT_POINT/Codex Usage.app" > "$PACKAGE_TEMP/mounted-app.sha256"
/usr/bin/cmp "$PACKAGE_TEMP/original-app.sha256" "$PACKAGE_TEMP/mounted-app.sha256"
test -x "$MOUNT_POINT/Codex Usage.app/Contents/MacOS/CodexUsage"
verify_app "$MOUNT_POINT/Codex Usage.app"
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_ACTIVE=false

# A hard link publishes without overwriting an existing artifact, including
# one created by another packaging process after the initial existence check.
/bin/ln "$STAGED_DMG" "$FINAL_DMG"
printf '%s\n' "$FINAL_DMG" 'The outer DMG still requires notarization and stapling before publication.'
