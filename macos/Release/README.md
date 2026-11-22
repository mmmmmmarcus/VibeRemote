# vvhisper updates

Sparkle 2.10.1 is pinned in SwiftPM. The app uses its standard download, signature
verification, installation and relaunch UI. Automatic checks are always enabled and run daily; downloads
and installation require the user's choice. Check for Updates is also available
in Settings’ About pane and the menu bar. Settings' sidebar marks About only while Sparkle has a valid update available; automatic checks use this gentle reminder instead of opening an unsolicited update window. Profile submission is disabled.

`update-config.json` contains only the public verification key and HTTPS feed URL.
The private signing key is held in the developer's macOS Keychain under the Sparkle
account `com.viberemote.sparkle`. Do not export it into the repository or CI logs.
Keep a secure backup using Sparkle's documented key management process.

## Prepare a release

1. Choose a new marketing version and an integer build number greater than every
   published build. Never reuse a build number, including for emergency fixes.
2. Build a Developer ID signed and notarized bundle:

   ```sh
   APP_VERSION=0.3.7 BUILD_NUMBER=15 SIGNING_MODE=release \
   CODESIGN_IDENTITY='Developer ID Application: Haolin Fei (Q9MD524YL5)' \
   NOTARY_PROFILE=VVHISPER_NOTARY ./create_app_bundle.sh
   ```

3. Run `./scripts/prepare-update.sh`. It validates notarization, signatures,
   architecture, bundle configuration and the generated signed appcast. The output
   is `Release/artifacts/`. No Git changes or release publication happen here.
4. Review the archive and appcast. For builds containing the GPL audio driver,
   include its corresponding source (see THIRD_PARTY_NOTICES.md); do not publish
   Apple's PacketLogger without a separate redistribution review.
5. Publish a normal GitHub Release tagged `v0.3.7` with both generated assets:
   `vvhisper-0.3.7-15.zip` and `appcast.xml`. The feed URL is the stable
   `releases/latest/download/appcast.xml` redirect. Each archive uses an immutable
   version-tagged URL. Keep every published archive available.
6. On a separate older signed installation, check, download, install and relaunch.
   Verify version/build, Siri mapping, permissions, helper, buttons and voice.
   A successful build or appcast check alone is not end-to-end update acceptance.

Version 0.3.0 (build 3) is the first public Sparkle-enabled release. Earlier versions
without Sparkle must install it manually. Local preview build 2 can update to build 3
through the same public feed. Verify the published feed and a real installation
before describing a release as fully tested.

## Local verification

`swift test --scratch-path .build/swiftpm` covers onboarding completion/migration,
settings controls and existing remote behavior. `validate-update-bundle.py` checks
the packaged update configuration and app-owned Mach-O architectures. A personal
build may contain Apple's unchanged PacketLogger bundle, whose signature is checked
instead of thinning its universal code.
`validate-appcast.py` checks feed structure; Sparkle performs cryptographic archive
verification at installation time. After all builds/tests finish, run
`./scripts/clean-build.sh` to remove compiler caches and staging files.

## Personal signing and the vvhisper migration

The product name is **vvhisper**, all lowercase with two v characters. Bundle creation
and installation default to `Developer ID Application: Haolin Fei (Q9MD524YL5)`
(Apple account: `makiclin@gmail.com`). They never automatically choose the company
certificate. `SIGNING_MODE=local` explicitly requests an ad-hoc development build.
The helper's client and source trust requirement uses the same personal team.

Release mode defaults to the Keychain profile `VVHISPER_NOTARY`. Configure this profile
for the personal account/team before the first notarized release; the former company
profile `NM_NOTARY` must not be reused blindly. Use the interactive command below and
enter credentials only in Terminal/Keychain, never in source or chat:

```sh
xcrun notarytool store-credentials VVHISPER_NOTARY --apple-id makiclin@gmail.com --team-id Q9MD524YL5
```

The rename retains `com.viberemote.app`, helper/driver identifiers, SwiftPM targets,
resource names, existing support directories, saved action raw values, Keychain service
names, and the existing GitHub/Sparkle feed and Ed25519 key. These are compatibility
identifiers, not the displayed product name. New driver builds expose `vvhisper`;
previously installed `VibeRemote` audio devices remain supported.

Changing teams changes the code requirement. Expect to reapprove Accessibility,
Input Monitoring, Bluetooth and any Keychain access macOS requests. The old root daemon
trusts the company team. Use Settings → Siri Remote → Set Up / Repair Helper from
`/Applications/vvhisper.app`: it checks the live helper, unregisters a stale registration,
then registers and verifies the current helper (or opens macOS approval). If macOS refuses
to remove the old registration, the error remains visible; migration may require the old
app context. Simply copying a bundle does not replace a running daemon. Keep the old app as a rollback copy, but do not run both together.
Helper v5 identifies the personal-team build. Do not claim a seamless Sparkle transition
until a real company-signed installation has downloaded, installed and relaunched the
personally signed update, including helper reapproval and remote voice checks.

Local upgrade verification (2026-11-15): the installed and staged personal bundles had
compatible designated requirements, but an obsolete company-signed development bundle
with the same app identifier was still registered. That copy was archived and unregistered;
the installer now targets only the exact installed path, validates signing continuity,
and atomically replaces the bundle with rollback protection. The user confirmed the next
installed update worked without reauthorizing permissions. This is one successful local
update, not a verified Sparkle migration. A read-only `launchctl print system/com.viberemote.helper`
still showed the old company team's running daemon; its migration remains separate from
the successful app update and privacy-permission check.

Release signing defaults are configured in the repository; notarization credentials,
installed-app migration and publication are separate steps. Use a fresh version/build
for the first renamed release rather than reusing the example version above.
