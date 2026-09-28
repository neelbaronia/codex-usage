#!/bin/sh
set -eu
umask 077

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK_DIR=
MANUAL_ID=
LOCK_HELD=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resume|--submission-id)
      OPTION=$1
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' "$OPTION requires a value." >&2; exit 64; }
      if [ "$OPTION" = --resume ]; then WORK_DIR=$2; else MANUAL_ID=$2; fi
      shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: CODE_SIGN_IDENTITY="Developer ID Application: ..." NOTARY_KEYCHAIN_PROFILE=profile /bin/sh notarize-release.sh' \
        '       /bin/sh notarize-release.sh --resume WORK_DIR [--submission-id UUID]' \
        'Builds once, submits using an existing Keychain profile, then waits at most NOTARY_WAIT_SECONDS (default 60).' \
        'Pending requests exit 75; resume uses the saved app and request, without rebuilding, signing, or uploading again.' \
        'Only one invocation may use a work directory at a time; an existing lock also exits 75.' \
        '--submission-id is only for reconciling a submission whose upload response did not contain an ID.' \
        'Writes final dist/ artifacts only after Apple acceptance, log retrieval, stapling, and extracted-ZIP verification.' \
        'Does not create credentials, certificates, accounts, or a GitHub release.'
      exit 0 ;;
    *) printf '%s\n' "Unknown option: $1" >&2; exit 64 ;;
  esac
done
WAIT_SECONDS=${NOTARY_WAIT_SECONDS:-60}
case "$WAIT_SECONDS" in ''|*[!0-9]*) printf '%s\n' 'NOTARY_WAIT_SECONDS must be an integer from 1 to 600.' >&2; exit 64 ;; esac
if [ "$WAIT_SECONDS" -lt 1 ] || [ "$WAIT_SECONDS" -gt 600 ]; then
  printf '%s\n' 'NOTARY_WAIT_SECONDS must be an integer from 1 to 600.' >&2; exit 64
fi
if [ -n "$MANUAL_ID" ] && [ -z "$WORK_DIR" ]; then
  printf '%s\n' '--submission-id requires --resume.' >&2; exit 64
fi
valid_id() {
  printf '%s\n' "$1" | /usr/bin/awk '
    /^[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+$/ {
      n = split($0, parts, "-")
      if (n == 5 && length(parts[1]) == 8 && length(parts[2]) == 4 && length(parts[3]) == 4 && length(parts[4]) == 4 && length(parts[5]) == 12) valid = 1
    }
    END { exit !valid }
  '
}
json_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}
verify_signed_app() {
  /usr/bin/codesign --verify --deep --strict "$APP_DIR"
  SIGNATURE_DETAILS=$(/usr/bin/codesign -dv --verbose=4 "$APP_DIR" 2>&1)
  case "$SIGNATURE_DETAILS" in *"Authority=Developer ID Application: "*) ;; *) printf '%s\n' 'Missing Developer ID Application signature.' >&2; exit 1 ;; esac
  case "$SIGNATURE_DETAILS" in *"(runtime)"*) ;; *) printf '%s\n' 'Missing hardened runtime.' >&2; exit 1 ;; esac
  case "$SIGNATURE_DETAILS" in *"Timestamp="*) ;; *) printf '%s\n' 'Missing secure timestamp.' >&2; exit 1 ;; esac
}

cleanup_work_lock() {
  # Never remove another invocation's lock, even if a user moved our original
  # lock while we were running. An interrupted owner leaves recoverable state.
  if [ "$LOCK_HELD" = true ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    /bin/rm "$LOCK_DIR/pid" && /bin/rmdir "$LOCK_DIR" ||
      printf '%s\n' "Could not remove this invocation's lock: $LOCK_DIR" >&2
  fi
}
acquire_work_lock() {
  WORK_DIR=$(CDPATH= cd -- "$WORK_DIR" && pwd)
  LOCK_DIR="$WORK_DIR/.notarization-lock"
  trap 'cleanup_work_lock' EXIT
  trap 'printf "\nInterrupted. Resume with: /bin/sh notarize-release.sh --resume \"%s\"\n" "$WORK_DIR" >&2; exit 130' HUP INT TERM
  # mkdir is the atomic claim. Hold it across all shared reads/writes, including
  # upload reconciliation, response files, ticket stapling, and final packaging.
  if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_OWNER=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    printf '%s\n' "Notarization work directory is locked: $LOCK_DIR" \
      "Recorded owner PID: ${LOCK_OWNER:-not yet recorded}. No shared files were changed." \
      'Wait for the other invocation to finish, then resume.' \
      'For a stale lock, check the recorded PID with ps and confirm no notarization process is using this directory.' \
      'Only then remove its pid file and the empty lock directory. Never remove a lock owned by an active process.' >&2
    exit 75
  fi
  LOCK_HELD=true
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

if [ -z "$WORK_DIR" ]; then
  [ -n "${NOTARY_KEYCHAIN_PROFILE-}" ] || { printf '%s\n' 'Set NOTARY_KEYCHAIN_PROFILE to an existing notarytool Keychain profile.' >&2; exit 1; }
  case "${CODE_SIGN_IDENTITY-}" in ''|-) printf '%s\n' 'Explicit Developer ID Application CODE_SIGN_IDENTITY is required.' >&2; exit 1 ;; esac
  /bin/sh "$PROJECT_DIR/build.sh" --universal
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/build/universal/Codex Usage.app/Contents/Info.plist")
  case "$VERSION" in ''|*[!0-9A-Za-z._-]*) printf '%s\n' 'Unsafe release version.' >&2; exit 1 ;; esac
  mkdir -p "$PROJECT_DIR/build/notarization"
  WORK_DIR=$(mktemp -d "$PROJECT_DIR/build/notarization/$VERSION.XXXXXX")
  acquire_work_lock
  printf '%s\n' "$NOTARY_KEYCHAIN_PROFILE" > "$WORK_DIR/keychain-profile"
  # From here onward the exact submitted bundle is retained, including after
  # timeouts, interruptions, Apple rejection, or failed local verification.
  /usr/bin/ditto --noextattr --noqtn "$PROJECT_DIR/build/universal/Codex Usage.app" "$WORK_DIR/Codex Usage.app"
  APP_DIR="$WORK_DIR/Codex Usage.app"
  verify_signed_app
  /bin/sh "$PROJECT_DIR/package-release.sh" --app "$APP_DIR" --output-dir "$WORK_DIR/upload"
  printf '%s\n' "upload/Codex-Usage-$VERSION-macos-universal.zip" > "$WORK_DIR/archive-path"
  (
    cd "$WORK_DIR"
    /usr/bin/shasum -a 256 'Codex Usage.app/Contents/MacOS/CodexUsage' > signed-executable.sha256
    /usr/bin/shasum -a 256 "upload/Codex-Usage-$VERSION-macos-universal.zip" > submitted-archive.sha256
  )
else
  acquire_work_lock
fi
APP_DIR="$WORK_DIR/Codex Usage.app"
printf '%s\n' "Retained notarization files: $WORK_DIR"
for REQUIRED in keychain-profile archive-path signed-executable.sha256 submitted-archive.sha256; do
  [ -f "$WORK_DIR/$REQUIRED" ] || { printf '%s\n' "Incomplete work directory: missing $REQUIRED. Nothing was submitted by this invocation." >&2; exit 1; }
done
PROFILE=$(cat "$WORK_DIR/keychain-profile")
[ -n "$PROFILE" ] || { printf '%s\n' 'Saved Keychain profile is empty.' >&2; exit 1; }
ARCHIVE_RELATIVE=$(cat "$WORK_DIR/archive-path")
case "$ARCHIVE_RELATIVE" in upload/Codex-Usage-*-macos-universal.zip) ;; *) printf '%s\n' 'Unexpected saved archive path.' >&2; exit 1 ;; esac
(
  cd "$WORK_DIR"
  /usr/bin/shasum -a 256 -c signed-executable.sha256
  /usr/bin/shasum -a 256 -c submitted-archive.sha256
)
verify_signed_app

if [ -n "$MANUAL_ID" ]; then
  valid_id "$MANUAL_ID" || { printf '%s\n' 'Submission ID must be a UUID.' >&2; exit 64; }
  if [ -f "$WORK_DIR/submission-id" ] && [ "$(cat "$WORK_DIR/submission-id")" != "$MANUAL_ID" ]; then
    printf '%s\n' 'Refusing to replace an existing submission ID.' >&2; exit 1
  fi
  printf '%s\n' "$MANUAL_ID" > "$WORK_DIR/submission-id"
fi
if [ ! -f "$WORK_DIR/submission-id" ]; then
  # Recover an ID from a response saved just before an interruption.
  RECOVERED_ID=$(json_value "$WORK_DIR/submit.json" id || true)
  if valid_id "$RECOVERED_ID"; then printf '%s\n' "$RECOVERED_ID" > "$WORK_DIR/submission-id"; fi
fi
if [ ! -f "$WORK_DIR/submission-id" ]; then
  if [ -e "$WORK_DIR/submission-attempted" ]; then
    printf '%s\n' 'The upload response is uncertain; automatic resubmission is disabled.' \
      'Inspect notarytool history using the saved Keychain profile, then resume with --submission-id UUID.' >&2
    exit 1
  fi
  : > "$WORK_DIR/submission-attempted"
  if xcrun notarytool submit "$WORK_DIR/$ARCHIVE_RELATIVE" --keychain-profile "$PROFILE" \
    --no-wait --output-format json > "$WORK_DIR/submit.json" 2> "$WORK_DIR/submit.stderr"; then
    :
  else
    printf '%s\n' "Upload did not complete cleanly; response retained in $WORK_DIR/submit.stderr." >&2
  fi
  REQUEST_ID=$(json_value "$WORK_DIR/submit.json" id || true)
  if ! valid_id "$REQUEST_ID"; then
    printf '%s\n' 'No submission ID was returned. Reconcile Apple submission history before resuming with --submission-id UUID.' >&2
    exit 1
  fi
  printf '%s\n' "$REQUEST_ID" > "$WORK_DIR/submission-id"
fi
REQUEST_ID=$(cat "$WORK_DIR/submission-id")
valid_id "$REQUEST_ID" || { printf '%s\n' 'Saved submission ID is invalid.' >&2; exit 1; }
printf '%s\n' "Apple submission: $REQUEST_ID"

# Each invocation waits only for a bounded period. The request continues at
# Apple after timeout, and the next invocation polls the same request.
if xcrun notarytool wait "$REQUEST_ID" --keychain-profile "$PROFILE" \
  --timeout "${WAIT_SECONDS}s" --output-format json > "$WORK_DIR/wait.json" 2> "$WORK_DIR/wait.stderr"; then :; fi
xcrun notarytool info "$REQUEST_ID" --keychain-profile "$PROFILE" \
  --output-format json > "$WORK_DIR/info.json"
RETURNED_ID=$(json_value "$WORK_DIR/info.json" id)
[ "$RETURNED_ID" = "$REQUEST_ID" ] || { printf '%s\n' 'Apple returned an unexpected submission ID.' >&2; exit 1; }
STATUS=$(json_value "$WORK_DIR/info.json" status)
case "$STATUS" in
  Accepted) ;;
  'In Progress')
    printf '%s\n' 'Apple is still processing this submission. No dist files were changed.' \
      "Resume: /bin/sh notarize-release.sh --resume \"$WORK_DIR\""
    exit 75 ;;
  *)
    xcrun notarytool log "$REQUEST_ID" --keychain-profile "$PROFILE" "$WORK_DIR/notary-log.json" || true
    printf '%s\n' "Apple status: $STATUS. See $WORK_DIR/notary-log.json; no dist files were changed." >&2
    exit 1 ;;
esac
xcrun notarytool log "$REQUEST_ID" --keychain-profile "$PROFILE" "$WORK_DIR/notary-log.json"
[ "$(json_value "$WORK_DIR/notary-log.json" jobId)" = "$REQUEST_ID" ] || { printf '%s\n' 'Notarization log does not match this submission.' >&2; exit 1; }
[ "$(json_value "$WORK_DIR/notary-log.json" status)" = Accepted ] || { printf '%s\n' 'Notarization log does not confirm acceptance.' >&2; exit 1; }
ARCHIVE_SHA=$(/usr/bin/shasum -a 256 "$WORK_DIR/$ARCHIVE_RELATIVE" | /usr/bin/awk '{ print $1 }')
[ "$(json_value "$WORK_DIR/notary-log.json" sha256)" = "$ARCHIVE_SHA" ] || { printf '%s\n' 'Apple accepted a different archive. Check the submission ID; no dist files were changed.' >&2; exit 1; }

# Stapling adds the ticket to the retained app. Never rebuild or re-sign it.
if ! xcrun stapler validate "$APP_DIR" > "$WORK_DIR/stapler-validation.txt" 2>&1; then
  xcrun stapler staple "$APP_DIR"
fi
xcrun stapler validate "$APP_DIR"
verify_signed_app
(
  cd "$WORK_DIR"
  /usr/bin/shasum -a 256 -c signed-executable.sha256
)
/bin/sh "$PROJECT_DIR/package-release.sh" --app "$APP_DIR" --require-notarized
: > "$WORK_DIR/completed"
printf '%s\n' "Notarized release verified. Apple log: $WORK_DIR/notary-log.json"
