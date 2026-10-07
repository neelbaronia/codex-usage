# Releasing Codex Usage

Public releases use a Developer ID Application certificate, hardened runtime,
a secure timestamp, and Apple notarization. Keep signing keys and Apple
credentials in the local Keychain; do not commit or bundle them.

## Prepare

1. For a new app version, update `CFBundleShortVersionString` and
   `CFBundleVersion` in `Info.plist`.
2. Run `/bin/sh test.sh`.
3. Confirm the intended **Developer ID Application** identity is available with
   `security find-identity -v -p codesigning`. An Apple Development certificate
   is not sufficient for this release workflow.
4. Confirm the current changes contain only source, resources, tests, and docs.
   `build/` and `dist/` are ignored; they may contain private submission logs.

The normal `build.sh` and `package-release.sh` commands remain offline and
ad hoc signed by default, including in CI. CI artifacts are not notarized public
releases. Setting `CODE_SIGN_IDENTITY` explicitly enables Developer ID signing,
hardened runtime, and secure timestamping, which requires network access.

## Notarize using a Keychain profile

Create a notarization profile once in your own Terminal using Apple's secure
interactive prompts:

```sh
xcrun notarytool store-credentials codex-usage-notary
```

This requires credentials accepted by Apple's notary service, such as an
Apple Account app-specific password or an App Store Connect API key. Do not put
the credential in a script, command history, or repository. Xcode's account
sign-in does not automatically create a `notarytool` Keychain profile.

Then run:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE=codex-usage-notary \
/bin/sh notarize-release.sh
```

An exact certificate name or its SHA-1 fingerprint is accepted. The script
builds once, retains the signed app and upload ZIP under `build/notarization/`,
and submits that ZIP. It waits for up to 60 seconds by default. If Apple is
still processing, it exits with status 75 and prints a resume command:

```sh
/bin/sh notarize-release.sh --resume '/absolute/path/printed/by/the/script'
```

Resume preserves the exact app and submission. It does not rebuild, re-sign,
or submit a second request. If an upload response is uncertain, the script
stops: inspect `notarytool history` with the saved Keychain profile and reconcile
the submission before using `--submission-id UUID`. The accepted log's ID and
ZIP hash must match the saved submission.

After acceptance, the script saves Apple's log, staples the ticket to the
retained app, and packages it without rebuilding. It verifies the extracted
ZIP's signature, Developer ID, hardened runtime, timestamp, stapled ticket,
Gatekeeper acceptance, architecture, minimum OS, and checksum before replacing
the final files in `dist/`. Review the saved Apple log for warnings before
publishing. A timeout or rejection does not update the final artifacts.

## Using an existing Xcode account

Xcode's **Developer ID → Upload** distribution workflow can use the account
already signed into Xcode instead of a separate `notarytool` profile. With a
prepared `.xcarchive`, the equivalent commands are `xcodebuild -exportArchive`
with export method `developer-id` and destination `upload`, then
`xcodebuild -exportNotarizedApp` after processing completes. Use the intended
team and Developer ID Application identity explicitly.

Package the app exported by Xcode without rebuilding or re-signing:

```sh
/bin/sh package-release.sh \
  --app '/absolute/path/to/exported/Codex Usage.app' \
  --require-notarized
```

The same extracted-ZIP checks apply. Preserve the archive and submission
records until the release is verified. An upload success alone does not mean
Apple has accepted the submission.

## Package and notarize a DMG

Public releases provide a notarized DMG and a ZIP containing the same app.
Start with the exact notarized, stapled app retained by the release workflow or
extracted from the published ZIP. Do not rebuild, re-sign, or otherwise change
the app to add a DMG to an existing release.

Set up the build-only Finder layout dependencies in an isolated environment:

```sh
python3 -m venv build/dmg-layout-venv
build/dmg-layout-venv/bin/python -m pip install ds-store==1.3.3 mac-alias==2.2.3
export DMG_LAYOUT_PYTHON="$PWD/build/dmg-layout-venv/bin/python"
```

The packager defaults to `python3` when `DMG_LAYOUT_PYTHON` is unset and checks
both dependency versions before packaging. These dependencies are not bundled
with the app and are not needed by people installing it.

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
/bin/sh package-dmg.sh --app '/absolute/path/to/Codex Usage.app'
```

The script creates `dist/Codex-Usage-VERSION-macos-universal.dmg`, containing the
unchanged app, an Applications shortcut, installation instructions, and a hidden
`.background.tiff` at the volume root, copied from `Resources/dmg-background.tiff`. It uses
`Resources/dmg-layout.dsstore` when present for the Finder view settings;
`--ds-store` can select another template. It creates a writable HFS+ image and
generates the background alias on that mounted image using its real file IDs
and creation dates, while preserving the template's other view settings. This
keeps the background associated with its own image when an older Codex Usage
disk is also mounted. It then detaches and converts the image to read-only UDZO
before signing. It verifies the mounted app, generated layout, and background
bytes, and refuses to overwrite an existing DMG. Open the image in Finder and
check that the arrow points from the app to Applications and that the
drag-to-install flow works. The DMG's Developer ID signature is separate from
Apple notarization: the outer image still needs its own submission and stapled
ticket.

For a packaging-only update to an existing app release, add `--revision N`, where
`N` is a positive integer without leading zeros. For example:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
/bin/sh package-dmg.sh --app '/absolute/path/to/Codex Usage.app' --revision 3
```

For version 1.6.2 this creates `Codex-Usage-1.6.2-macos-universal-r3.dmg`.
Keep the existing DMG, ZIP, app version, and tag unchanged. Notarize and staple
the revised image separately, then publish it and its own `.dmg.sha256` file.
Use that revised filename in all commands below and update download links only
after the public artifact passes verification.

The checked-in background and Finder layout share a 600 × 340 point canvas,
with the app at (160, 100) and Applications at (440, 100). Keep their dimensions
and positions aligned when changing the installer artwork. Regenerate the
background with:

```sh
swift scripts/generate-dmg-background.swift
```

This writes `Resources/dmg-background.tiff` and an ignored preview at
`build/dmg-background-preview.png`. To change the Finder layout, edit
`scripts/generate-dmg-layout.py` and regenerate the view-settings template with
`"$DMG_LAYOUT_PYTHON" scripts/generate-dmg-layout.py`. The packager generates
the image-specific background alias separately using `--volume-root` and
`--output`. The resulting alias must not contain a developer's private staging
path. The layout follows dmgbuild's root-level background and icon-view fields;
it preserves the native target alias metadata and uses a public canonical mount
hint. Regular packaging consumes the checked-in artwork and does not require
Swift, but it uses the Python environment above to prepare each image's layout.

Using the Keychain profile created above, submit the image once and retain the
response, diagnostics, and submitted hash under `build/`:

```sh
DMG_NAME=Codex-Usage-1.6.2-macos-universal-r3.dmg
DMG_PATH="$PWD/dist/$DMG_NAME"
mkdir -p build
DMG_RECORD_DIR=$(mktemp -d "$PWD/build/notarization-dmg.XXXXXX")
shasum -a 256 "$DMG_PATH" > "$DMG_RECORD_DIR/submitted-dmg.sha256"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile codex-usage-notary --output-format json \
  --wait --timeout 60s \
  > "$DMG_RECORD_DIR/submit.json" 2> "$DMG_RECORD_DIR/submit.stderr"
```

A timeout does not cancel Apple's processing. If the response is uncertain or
missing its submission ID, do not submit again: inspect history, reconcile the
upload, and retain its ID. Use that same ID to check status and, once processing
completes, retrieve Apple's log. Review any warnings and confirm the log's
submitted hash matches the saved hash before proceeding.

```sh
xcrun notarytool history --keychain-profile codex-usage-notary \
  --output-format json > "$DMG_RECORD_DIR/history.json"
DMG_SUBMISSION_ID='UUID from submit.json or the reconciled history entry'
xcrun notarytool info "$DMG_SUBMISSION_ID" \
  --keychain-profile codex-usage-notary --output-format json \
  > "$DMG_RECORD_DIR/info.json"
xcrun notarytool log "$DMG_SUBMISSION_ID" \
  --keychain-profile codex-usage-notary "$DMG_RECORD_DIR/log.json"
```

Only after Apple reports **Accepted** for this image, staple and validate the
DMG, then calculate its final checksum. Stapling changes the image's bytes.

```sh
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"
spctl --assess --type open --context context:primary-signature \
  --verbose=2 "$DMG_PATH"
(cd dist && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
```

Keep the per-image `$DMG_NAME.sha256` separate from `dist/SHA256SUMS.txt`, which
belongs to the ZIP release. Preserve the submission records locally.

## Publish and verify

1. Launch the signed app and verify live allowance refresh, local token rates,
   and menu/popover behavior. Confirm the intended launch-at-login setting.
2. Update the README's download version and signing status only after successful
   notarization. Do not describe an ad hoc or merely submitted build as notarized.
3. For a new app version, commit, run CI, and tag the exact source revision.
   Publish both the ZIP and notarized DMG, along with `dist/SHA256SUMS.txt` for
   the ZIP and the DMG's own `.dmg.sha256` file. CI only checks the DMG script's
   shell syntax; it does not require signing or notarization credentials.
4. When adding or revising a DMG for an existing release, upload only the DMG and its
   `.dmg.sha256` file after completing the checks above. Keep the identical app,
   existing ZIP bytes, `SHA256SUMS.txt`, and tag. Adding a distribution format
   or revising the installer layout requires no app version bump. Use
   `--revision N` for a new installer filename; do not replace existing assets.
5. Download the published assets again and verify their respective checksums.
   Extract the ZIP and mount the DMG; repeat the app signature, `stapler validate`,
   and Gatekeeper checks, as well as the DMG checks above. Confirm downloads are
   accessible without signing into GitHub.

Apple references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[custom notarization workflows](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
