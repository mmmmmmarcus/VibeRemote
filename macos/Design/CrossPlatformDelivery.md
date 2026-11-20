# Cross-platform feature and device delivery workflow

Use this checklist for shared vvhisper features on macOS, iOS, and Android. This
file lives under `macos/Design` to preserve the repository's root layout, but
applies to all three platforms. Run commands below from the repository root
unless a subshell changes directory.

Latest mobile delivery: [editing pills, media mixing and iPad layout](../../ios/Design/MobileParity.md)
tracks the 2026-11-20 source, test, device and platform limitations separately.

## 1. Define the shared behavior

- Read root `AGENTS.md` and the target platform's guidance, including `ios/AGENTS.md`.
- Record defaults, settings persistence, request/response contracts, failure and
  cancellation behavior, and platform-specific limitations before implementation.
- For dictation, cover streaming draft → final ASR → optional polishing → sentence
  punctuation → final insertion. Keep the draft pending until polishing finishes.
- Share fixtures where behavior must match. Native UI and host-editor capabilities
  may differ; mobile composing text does not guarantee an underline in every app.
- Track each platform separately. A Mac implementation does not imply mobile delivery.

## 2. Build and check affected platforms

Use focused tests for the changed behavior and the required platform checks.
Coordinate with other active work before starting builds or removing caches.

```sh
# macOS: unit tests, strict concurrency, then remove compiler caches.
(cd macos && swift test && swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete)
(cd macos && ./scripts/clean-build.sh)

# iOS: tests and a fresh signed device build; build.sh cleans its scratch directory.
./ios/test.sh
./ios/build.sh

# Android: build/lint; device tests when affected behavior needs them.
(cd android && ./gradlew assembleDebug lintDebug)
```

Keep completed app/APK outputs. Do not clean another session's active build or
discard uncommitted work. A build success is not installation or physical QA.

## 3. Install on explicitly selected devices

### Mac

Run `./macos/install.sh`. It builds, signs, verifies, and installs the stable
`/Applications/vvhisper.app` with the personal signing identity. Do not replace
this with an ad-hoc build or delete-and-copy operation.

### iPhone Duo

1. Use the iPhone-use skill. Call `phone_instances`, then `phone_status` for the
   selected instance. Confirm the physical Duo, not a simulator or another iPhone.
   `xcrun devicectl list devices` can confirm the connected target.
2. Respect ownership and private holds. Do not interrupt another session. The
   user handles phone passcode, trust and authentication prompts on the phone.
3. Build the latest source with `./ios/build.sh`.
4. Call `phone_install_app` with the selected instance, the absolute path to
   `ios/build/vvhisper.app`, and **`fresh:false`**. Preserve app data and settings.
5. Launch `com.vvhisper.ios`. Confirm existing settings and the saved ASR key.
6. Configure only missing/explicitly requested credentials using the secure app
   fields. Verify **Saved**, the intended model, and the enabled state. Never put
   keys in this workflow, flow inputs, launch arguments, fixtures, logs or IPC.
7. Return to the app's main Settings screen and run the verification flow below.
8. Open **Try Keyboard** and verify the extension loads. For a changed dictation
   path, separately test an actual spoken hold through recognition, polishing,
   and insertion, plus cancellation/failure cases relevant to the change.
9. Release the phone with `phone_release_owner` when finished.

The saved navigation flow is
[`ios/flows/verify-polishing-setup.json`](../../ios/flows/verify-polishing-setup.json).
It checks **Saved**, **Seed 2.0 Mini**, and **Polish Dictation = on**, then returns
to Settings. It requires the main Settings screen as its starting point and
contains no credential input. A failed assertion should stop the run; do not
blindly replay state-changing steps.

```sh
"$HOME/Applications/iPhoneUse.app/Contents/MacOS/iphone-use-mcp" flow validate ios/flows/verify-polishing-setup.json
```

Run through MCP `phone_flow_run`, passing the selected instance and the absolute
file path as `id`. Do not publish to the public flow registry without separate
authorization. Installation and credential setup are deliberately outside the
navigation flow: the recorded secure-field write and switch operation are not
supported by its current replay format.

### Android

Choose the authorized device by name/serial using `adb devices -l`; never rely
on the first connected device. Replace `DEVICE_SERIAL` below with that selection.

```sh
adb -s DEVICE_SERIAL install -r android/app/build/outputs/apk/debug/app-debug.apk
```

Preserve data. If signing differs, stop and explain the migration/data-loss
implications before uninstalling anything. Confirm the keyboard is enabled and
selected, the intended microphone permission is available, and required keys
are saved in the app's encrypted store. Use native setup UI and the platform's
device test instructions in `android/README.md`.

## 4. Credentials and live verification

See [VolcengineCredentials.md](VolcengineCredentials.md) for console URLs,
permissions, and observed authentication results. Currently ASR and polishing
use **two separately stored keys**. Preserve working ASR credentials; the new
IAM key's Ark success does not establish ASR compatibility.

Use synthetic text/audio for service checks. Do not record personal transcripts
or credentials. A saved key proves persistence, not successful inference; a
direct HTTP check proves service access, not the complete device dictation path.

## 5. Record delivery evidence

For each shared feature, copy this table into its change notes and replace every
pending entry with specific evidence or a blocker. Update the credential record
when provisioning changes. Do not mark unavailable devices as passed.

| Platform | Source/build | Tests | Installed target | Settings/credentials | Live feature check | Remaining blocker |
| --- | --- | --- | --- | --- | --- | --- |
| macOS | Pending | Pending | Pending | Pending | Pending | Pending |
| iOS / Duo | Pending | Pending | Pending | Pending | Pending | Pending |
| Android | Pending | Pending | Pending | Pending | Pending | Pending |

## Saved flow validation status

2026-11-19: JSON schema validation passed (6 navigation/assertion steps). A live
replay is pending because another session owned the Duo when the flow was saved.
The preceding manual installation/setup verified the key's Saved state, enabled
polishing, the model label, and keyboard launch; it is not a replay pass.
