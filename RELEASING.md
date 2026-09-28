# Releasing Codex Usage

Public releases use a Developer ID Application certificate, hardened runtime,
a secure timestamp, and Apple notarization. Keep signing keys and Apple
credentials in the local Keychain; do not commit or bundle them.

## Prepare

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
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

## Publish and verify

1. Launch the signed app and verify live allowance refresh, local token rates,
   and menu/popover behavior. Confirm the intended launch-at-login setting.
2. Update the README's download version and signing status only after successful
   notarization. Do not describe an ad hoc or merely submitted build as notarized.
3. Commit, run CI, and tag the exact source revision. Create a new GitHub release
   with `dist/Codex-Usage-VERSION-macos-universal.zip` and `dist/SHA256SUMS.txt`.
   Do not silently replace an older version's ZIP with different bytes.
4. Download the published assets again, verify their checksum, extract the app,
   and repeat signature, `stapler validate`, and Gatekeeper checks. Confirm the
   download is accessible without signing into GitHub.

Apple references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[custom notarization workflows](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
