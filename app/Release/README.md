# VibeRemote updates

Sparkle 2.10.1 is pinned in SwiftPM. The app uses its standard download, signature
verification, installation and relaunch UI. Automatic checks are always enabled and run daily; downloads
and installation require the user's choice. Check for Updates is also available
in Settings’ More menu and the menu bar. Settings shows an Update toolbar button only while Sparkle has a valid update available; automatic checks use this gentle reminder instead of opening an unsolicited update window. Profile submission is disabled.

`update-config.json` contains only the public verification key and HTTPS feed URL.
The private signing key is held in the developer's macOS Keychain under the Sparkle
account `com.viberemote.sparkle`. Do not export it into the repository or CI logs.
Keep a secure backup using Sparkle's documented key management process.

## Prepare a release

1. Choose a new marketing version and an integer build number greater than every
   published build. Never reuse a build number, including for emergency fixes.
2. Build a Developer ID signed and notarized bundle:

   ```sh
   APP_VERSION=0.3.4 BUILD_NUMBER=11 SIGNING_MODE=release \
   CODESIGN_IDENTITY='Developer ID Application: <your identity>' \
   NOTARY_PROFILE=NM_NOTARY ./create_app_bundle.sh
   ```

3. Run `./scripts/prepare-update.sh`. It validates notarization, signatures,
   architecture, bundle configuration and the generated signed appcast. The output
   is `Release/artifacts/`. No Git changes or release publication happen here.
4. Review the archive and appcast. For builds containing the GPL audio driver,
   include its corresponding source (see THIRD_PARTY_NOTICES.md); do not publish
   Apple's PacketLogger without a separate redistribution review.
5. Publish a normal GitHub Release tagged `v0.3.4` with both generated assets:
   `VibeRemote-0.3.4-11.zip` and `appcast.xml`. The feed URL is the stable
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

## Local signing profile

This Mac uses `NM_NOTARY` for notarization, with Developer ID team `SM96W8VVK9`.
Credentials stay in Keychain. Other machines must store their own credentials.
