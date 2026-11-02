---
name: viberemote-release
description: Prepare, publish and independently audit a stable VibeRemote release (notarized build, Sparkle appcast, GitHub Release). Use when asked to ship, release or publish a VibeRemote version, or to verify a published one.
argument-hint: "<version> [build]"
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

# VibeRemote release

Release VibeRemote `$ARGUMENTS` from this repository. The macOS app lives in `app/`;
every `app/...` path below is relative to the repository root, and build commands run
inside `app/`. `app/Release/README.md` is the source of truth for the update process;
read it first and follow it where it differs from this skill.

Adapted from the Codex `spotter-release-audit` skill: same discipline (prepare is not
publish, verify the public result yourself), VibeRemote's own scripts and assets.

## Authority

- Preparing, building, notarizing and auditing need no extra permission.
- **Stop and ask** before each outward step: `git push`, `gh release create`, and any
  edit or deletion of a published release or tag. Approval of one is not approval of the
  next. Show exactly what will be pushed or published when asking.
- Never reuse or lower a build number, never replace a published archive, never move a
  published tag. A bad release is fixed by a new version.
- Never print, export or pass the Sparkle private key or notary credentials. They stay
  in Keychain (Sparkle account `com.viberemote.sparkle`, notary profile `NM_NOTARY`).

## 1. Inputs and preflight

1. Version: the first word of `$ARGUMENTS`. If it is missing, propose one from the
   changes since the last tag (new feature → minor, fixes only → patch) and ask.
2. Read the last release, its notes and its build number:
   ```bash
   gh release list --limit 5
   gh release download "$(gh release view --json tagName -q .tagName)" -p appcast.xml -O - | grep -o 'sparkle:version>[0-9][0-9]*'
   ```
   The new build is the second word of `$ARGUMENTS`, or the highest published build + 1.
   Confirm `v<version>` does not already exist as a tag or release.
3. `git status`, branch `main`, and `git fetch && git status -sb` up to date with
   origin. Uncommitted work that belongs in the release must be committed first; ask the
   user what it should contain if that is unclear. Never ship unreviewed changes silently.
4. Tooling: `gh auth status`;
   `security find-identity -v -p codesigning | grep "Developer ID Application"`
   (team `SM96W8VVK9`); `xcrun notarytool history --keychain-profile NM_NOTARY` succeeds.
5. GPL audio driver: `git diff --stat -M v0.3.0 HEAD -- app/AudioDriver app/build_audio_driver.sh`.
   No content change → reuse `VibeRemoteAudio-0.3.0-source.tar.gz` from the previous
   release. A change → stop; a new corresponding-source archive must be produced
   (see `app/THIRD_PARTY_NOTICES.md`) before publishing.

## 2. Version and notes

1. Bump the defaults in `app/create_app_bundle.sh` (`APP_VERSION`, `BUILD_NUMBER`) and the
   example version, build, archive name and tag in `app/Release/README.md`.
2. Write `app/Release/notes/<version>.md` in the style of the previous notes: a short
   `##` headline, user-facing bullets (what changed for the person holding the remote, no
   internal names), then the closing lines about platform (Apple Silicon, macOS 27),
   preserved settings, the included GPL driver source and that PacketLogger is not
   redistributed. Draft it from `git log v<previous>..HEAD` and the AGENTS.md entries,
   and show it to the user before building.

## 3. Checks (mirror CI)

From `app/`:
```bash
KEEP_BUILD_CACHE=1 swift test
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete
bash -n build.sh create_app_bundle.sh build_audio_driver.sh install.sh scripts/clean-build.sh scripts/prepare-update.sh
plutil -lint VibeRemote.entitlements
python3 scripts/test_updates.py
```
Any failure stops the release until it is fixed. Only warnings already present before
this release (AppUpdater.swift, VoiceBridgeHelper, older RemoteInputHandler lines) are
acceptable.

## 4. Build, notarize, prepare the update

From `app/` (notarization waits on Apple; allow 10+ minutes, run it in the background):
```bash
APP_VERSION=<version> BUILD_NUMBER=<build> SIGNING_MODE=release \
CODESIGN_IDENTITY="<Developer ID Application identity from step 1.4>" \
NOTARY_PROFILE=NM_NOTARY ./create_app_bundle.sh
./scripts/prepare-update.sh
```
`prepare-update.sh` verifies codesign, staple, Gatekeeper and the bundle, then writes
`app/Release/artifacts/VibeRemote-<version>-<build>.zip` and `appcast.xml`. It refuses to
replace an existing archive; never delete one to get past that.

Review before publishing:
- appcast: one item, `sparkle:version` = build, `sparkle:shortVersionString` = version,
  enclosure URL `https://github.com/mmmmmmarcus/VibeRemote/releases/download/v<version>/VibeRemote-<version>-<build>.zip`,
  an `sparkle:edSignature`, and a length equal to the zip's size.
- bundle: `CFBundleShortVersionString`/`CFBundleVersion` match; arm64 only; no
  PacketLogger; `Contents/Helpers/AgentDesktop/` binaries signed with hardened runtime
  (`codesign -dv --verbose=4`).
- Record the zip's SHA-256 (`shasum -a 256`).

## 5. Commit, push, CI

1. Commit the version bump and notes: `Release <version> with <one-line summary>`, with
   the attribution trailer from the session instructions.
2. **Ask**, then `git push origin main`.
3. Wait for the CI run on that commit: `gh run list --commit "$(git rev-parse HEAD)"`, then
   `gh run watch <id> --exit-status`. A red run stops the release.

## 6. Publish

**Ask** with the exact command and asset list, then:
```bash
gh release download v<previous> -p 'VibeRemoteAudio-*-source.tar.gz' -D app/Release/artifacts
gh release create v<version> --target main --title "VibeRemote <version>" \
  --notes-file app/Release/notes/<version>.md \
  app/Release/artifacts/VibeRemote-<version>-<build>.zip \
  app/Release/artifacts/appcast.xml \
  app/Release/artifacts/VibeRemoteAudio-0.3.0-source.tar.gz
```
It must be a normal, non-draft, non-prerelease release so it becomes `latest`; the feed is
`https://github.com/mmmmmmarcus/VibeRemote/releases/latest/download/appcast.xml` and the
website's Download buttons point at `releases/latest`, so neither needs a change.

## 7. Independent audit of what is public

Work in a fresh directory under the scratchpad; do not reuse local artifacts as evidence.
1. `gh release view v<version> --json isDraft,isPrerelease,tagName,body,assets`: not a
   draft, body identical to the notes file, all three assets present.
2. `curl -fsSL` the `latest/download/appcast.xml` URL: byte-identical to the local
   appcast and pointing at the new version and build.
3. `curl -fsSL` the zip from the enclosure URL; its SHA-256 equals the recorded one.
   Unzip with `ditto -x -k`, then `codesign --verify --deep --strict`,
   `xcrun stapler validate`, `spctl --assess --type execute -vv`, and read the version
   and build from `Info.plist`.
4. Update acceptance (install from an older signed build via Check for Updates, relaunch,
   check Siri mapping, permissions, helper, buttons and voice) is the user's manual test.
   Do not drive the UI to do it unless the user asks; report it as not yet verified.

## 8. Finish

Run `./scripts/clean-build.sh` in `app/`. Report: version, build, commit, CI run URL,
release URL, asset names with SHA-256, each audit result, and what remains unverified.
Only reinstall the release build into /Applications if the user asks.

## Pitfalls

- Local install ≠ release. A Developer-signed `./install.sh` build is not notarized and is
  no evidence that the public feed works.
- Build numbers: the appcast compares `CFBundleVersion`; a number not above every published
  build means no one is offered the update.
- `create_app_bundle.sh` drops PacketLogger in release mode; do not set
  `INCLUDE_PACKETLOGGER=1` for a public build.
- Notarization can reject new nested binaries (e.g. vendored helpers) that lack hardened
  runtime or a timestamp; read `xcrun notarytool log <id> --keychain-profile NM_NOTARY`
  and fix signing in `create_app_bundle.sh`, never by skipping notarization.
