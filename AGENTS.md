# AGENTS.md

Guidance for AI coding agents working in the VibeRemote repository. Read this
before making changes — several subsystems depend on hard-won, non-obvious
platform behavior that is easy to break.

## What this project is

VibeRemote is an experimental macOS **menu-bar app** (`LSUIElement`, no dock
icon) that:

- Maps Apple Siri Remote buttons to keyboard actions, aimed at driving AI agent apps
  (arrows, Enter, Shift+Enter, Backspace, bullet-list control, app switching).
- Shows the paired remote's connection and battery state.
- **Bridges the Siri Remote microphone** into its own virtual audio device
  ("VibeRemote") so the remote can be used as a system mic.

It is a three-executable SwiftPM package (app, voice bridge, privileged helper) plus a
shared library target and shell scripts that build the audio driver and assemble/sign the
`.app` bundle. There is no Xcode project file.

## Repository layout

| Path | Role |
|------|------|
| `main.swift` | App entry point (`NSApplicationMain`-style bootstrap). |
| `SiriRemoteApp.swift` | `AppDelegate`: wires managers, permissions, lifecycle. |
| `MenuBarManager.swift` | Status-item menu, all user-facing UI. |
| `RemoteDetector.swift` | IOKit HID discovery of the remote; also defines `vibeRemoteLogPath` and `rmDebug`. |
| `RemoteInputHandler.swift` | Opens HID interfaces, maps buttons, sends synthetic key events, performs the `0xAF` input-enable Feature write. |
| `RemoteHIDChannel.swift` | Direct HID-over-GATT (CoreBluetooth) path — see caveats below. |
| `RemoteBatteryReader.swift` | Battery level via IOBluetooth/CoreBluetooth. |
| `BluetoothAccessManager.swift` | Bluetooth TCC authorization state. |
| `MediaKeyInterceptor.swift` | Intercepts system media keys the remote emits. |
| `SystemVolume.swift` | CoreAudio volume read/set + revert guard. |
| `MicrophoneBridgeManager.swift` | Orchestrates the mic bridge (both engines). The largest and most delicate file. |
| `VoiceBridgeHelper/main.swift` | **Separate executable** (`VibeRemoteVoiceBridge`): parses HCI/HID records, Opus-decodes, plays into the virtual audio device. |
| `PrivilegedHelper/main.swift` | **Separate executable** (`VibeRemoteHelper`): root LaunchDaemon registered via `SMAppService`; performs privileged work over XPC. |
| `HelperProtocol/HelperProtocol.swift` | Library target shared by the app and daemon: the XPC contract and shared identifiers. |
| `PrivilegedHelperClient.swift` | App-side registration/status/XPC calls for the daemon. |
| `Vendor/SiriRemoteVoiceControl/` | Prebuilt legacy helper binaries (compatibility fallbacks). |
| `Tests/VibeRemoteTests/ModelTests.swift` | Unit tests (pure model/enum logic; no hardware). |
| `build.sh` | SwiftPM build → universal `VibeRemote`, `VibeRemoteVoiceBridge`, `VibeRemoteHelper` binaries. |
| `build_audio_driver.sh` | Builds the branded `VibeRemoteAudio.driver` from upstream BlackHole source. |
| `create_app_bundle.sh` | Runs `build.sh`, assembles `.app` (incl. driver + daemon plist), signs, optionally notarizes. |
| `VibeRemote.entitlements` | Only `com.apple.security.device.bluetooth`. |

## Build, run, test

Always build through SwiftPM / the scripts — never hand-invoke `swiftc`.

```bash
# Fast host-only build while iterating
ARCHS="$(uname -m)" ./build.sh

# Audio driver (only needed when it changes; output is gitignored)
./build_audio_driver.sh

# Full universal signed bundle (what actually gets installed)
./create_app_bundle.sh                 # ad-hoc signed (local "-")
open VibeRemote.app

# Unit tests + strict concurrency (CI runs both)
swift test
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete
```

`AudioDriver/` and the built binaries are gitignored, so a fresh clone bundles no driver and
no helper until those scripts run; the app degrades gracefully (falls back to an existing
BlackHole/Soundflower device and to admin prompts).

**Prefer the Developer ID signing command when installing for real testing.**
Ad-hoc signatures change every build, which revokes the app's Accessibility /
Input Monitoring / Bluetooth TCC grants and forces re-approval each time. A
stable identity preserves them:

```bash
SIGNING_MODE=developer \
CODESIGN_IDENTITY="Developer ID Application: <your identity>" \
./create_app_bundle.sh
```

Deploy the built bundle over the installed one and relaunch:

```bash
osascript -e 'tell application "VibeRemote" to quit'
rm -rf /Applications/VibeRemote.app
ditto VibeRemote.app /Applications/VibeRemote.app
open /Applications/VibeRemote.app
```

CI (`.github/workflows/ci.yml`, `macos-15`) runs: `swift build`, `swift test`,
the strict-concurrency build, `bash -n` on both scripts, and `plutil -lint` on
the entitlements. Keep all of these green.

## Button mappings and hold behavior

Mappings are **fixed by design** — `remoteButtonDescriptors` in `MenuBarManager.swift` is the
single source of truth. Only the **Siri button** is user-customizable (persisted under the
`siriButtonAction` default); everything else is hardcoded and has no menu UI.

Current intent: clickpad arrows → arrow keys, clickpad center → Enter, Back/Menu →
Backspace, TV → Shift+Enter (newline, the convention agent apps use), Play/Pause → toggle
the Codex/Claude desktop client to the front, Power → Enter, volume keys → bullet-list
control, Siri → held Space. The mute button is currently unmapped and free.

**The remote reports one press and one release with no repeats in between.** Key repeat and
tap/long-press are therefore synthesized in `RemoteInputHandler`:

- `beginRepeating` drives auto-repeat (Backspace, arrows) with a safety tick cap in case a
  release event is ever dropped.
- `beginTapOrLongPress` distinguishes a tap from a hold (volume-up: tap indents, long-press
  starts a bullet). Timers are torn down on release and on disconnect.
- An earlier attempt tracked bullet-list "context" to decide between `- ` and Tab. It was
  unreliable (any manual typing or focus change desynced it) and was replaced by this
  deterministic tap/hold model. Don't reintroduce blind state tracking of editor content.

## Microphone bridge — critical architecture notes

This is where almost all the subtlety lives. The bridge runs as a pipeline:

```
Siri Remote (Opus audio, HID report 0xFA / ATT "1B 35" voice frames, emitted ONLY while the Siri button is held)
  → capture layer  → stdin of VibeRemoteVoiceBridge (user session)
  → SiriRemotePacketParser → OpusDecoder → AVAudioEngine → "VibeRemote" virtual device
  → that device's loopback appears as a system audio *input*
```

There are **two capture engines**, selected at runtime:

```bash
# Route startLocked() to the PacketLogger engine (the one that actually works):
defaults write com.viberemote.app microphoneBridgeEngine packetlogger
```

- **Direct HID engine (code default).** `RemoteInputHandler` opens the remote's
  audio HID interface and `RemoteHIDChannel` attaches over GATT. On current
  macOS this path **never delivers audio**: macOS hides GATT HID service
  `0x1812` from third-party apps (CoreBluetooth sees only `180A`/`180F`), and the
  IOHID proxy does not forward the `0xFA` audio input reports to user space. The
  `0xAF` input-enable Feature write itself *does* succeed — delivery is what the
  OS blocks. Keep this path compiling, but do not assume it produces sound.
- **PacketLogger engine (what works).** `startPacketLoggerBridgeLocked()` runs
  Apple's signed `PacketLogger.app` CLI as root to capture live HCI, tees the
  stream to the user-session helper, and decodes the `1B 35` voice frames.
  Requires an admin password prompt on each start.

### Landmines in the PacketLogger supervisor (`privilegedPacketLoggerCommand`)

The root supervisor is a shell script embedded in `MicrophoneBridgeManager.swift`.
Two bugs here previously made the whole path look impossible; do not regress
them:

1. **stdin must never reach EOF.** `packetlogger convert -s` treats stdin EOF as
   Ctrl-D and immediately prints `Disconnected from OS X Device`. It reads a
   read-write keepalive FIFO (`0<> "$stdin_keepalive"`), never `/dev/null`.
2. **PPID probe needs `exec`.** `supervisor_pid=$(exec /bin/sh -c 'echo $PPID')`.
   Without `exec`, sh forks one level deeper and reports the wrong parent, so
   every `is_direct_child` check fails and the supervisor kills the capture in
   the first second.
3. `defaults write com.apple.PacketLogger 'Last UsedPacket Priority Set' -int 3`
   is required or the CLI dumps the device inventory and disconnects.

### Bluetooth debug prerequisites

The supervisor writes `com.apple.MobileBluetooth.debug` prefs and the
`SkipBluetoothPacketLogAuthorization` nvram var. **These only take effect after
`bluetoothd` restarts.** If capture starts empty right after first enabling
them, restart bluetoothd (`sudo pkill bluetoothd`; the remote reconnects in a
few seconds).

### Helper (`VoiceBridgeHelper/main.swift`) invariants

- The remote gates the mic in firmware. There is **no** always-on capability;
  every audio session requires a physical Siri-button hold. Do not add features
  that assume otherwise.
- `player.stop()` must never be called synchronously from an
  `AVAudioPlayerNode` scheduleBuffer completion callback — it deadlocks. Stops
  go through `stopPlayerSafely()` on a dedicated control queue. This is why
  "works once then silent after re-press" happened before.
- On start the helper skips PacketLogger's buffered replay (records older than
  launch) so a stale prior session is not re-decoded into the output device.
- Audio format: Opus CELT-only, 48 kHz mono, 960 samples/frame, 99-byte HID
  payload, enable byte `0xAF`, report ID `0xFA`. Cross-checked against
  https://github.com/azais-corentin/siri-remote.

### No mode toggles

There is no microphone mode and no input mode. With the app open the bridge is always
meant to be running, and the output stream stays warm for the bridge's lifetime (one
`Start`/`Restart` action, no `Stop`). Earlier builds had `MicrophoneMode` and
`MicrophoneInputMode` enums; both were removed because the firmware gates the mic to
physical Siri-button holds, so a "continuous" mode could not do what its name implied.

## The virtual audio device

The bridge plays into a virtual CoreAudio device. We ship our own: `AudioDriver/
VibeRemoteAudio.driver`, built by `build_audio_driver.sh` from upstream BlackHole with
VibeRemote branding (device, driver, and manufacturer all report "VibeRemote"). Users
never see the word BlackHole.

- The driver is **GPL-3.0** (a BlackHole derivative). Keep `THIRD_PARTY_NOTICES.md`
  accurate; anyone distributing a build with it owes the corresponding source.
- Device detection order is `VibeRemote` → `BlackHole 2ch` → `Soundflower (2ch)`, kept in
  sync between `MicrophoneBridgeManager.supportedOutputDeviceNames` and the hardcoded list
  in `VoiceBridgeHelper/main.swift`.
- **A freshly installed virtual device can come up attenuated** (observed at 0.47), which
  buries speech under the noise floor and looks exactly like "the bridge runs but there is
  no input level". `raiseInputVolumeIfNeeded` forces unity on every bridge start — do not
  remove it.
- `installAudioDriver()` installs it into `/Library/Audio/Plug-Ins/HAL` and restarts
  coreaudiod, preferring the privileged helper and falling back to one admin prompt.

## Privileged helper (`SMAppService`)

`VibeRemoteHelper` is a root LaunchDaemon that exists so the user authorizes once instead
of typing a password on every bridge start. The app registers it with
`SMAppService.daemon(plistName:)`; the user approves it in System Settings › Login Items &
Extensions; afterwards the app drives it over XPC.

Bundle layout is dictated by `SMAppService` and easy to get wrong:

- executable at `Contents/MacOS/VibeRemoteHelper`
- plist at `Contents/Library/LaunchDaemons/com.viberemote.helper.plist`, whose `Label`
  matches the filename, with `BundleProgram` relative to the app bundle and `MachServices`
  naming the same Mach service the daemon listens on
- the helper must be signed **before** the enclosing app (nested code first)

**Security invariants — this process is root:**

- `listener(_:shouldAcceptNewConnection:)` validates every peer against a code requirement
  (our bundle id + Team ID). Never accept a connection without that check.
- Privileged file operations validate their source too (`bundleIsTrusted`), so root can only
  copy code we signed into system directories.
- The audit token is read via KVC because `NSXPCConnection` exposes it privately; the pid
  fallback is less precise, so keep the token path.

When adding a capability: extend `HelperProtocol`, bump `HelperConstants.version`, and
remember an already-approved daemon keeps running the **old** binary until re-registered.

## Dead ends — do not re-litigate

Each of these was investigated to a firm conclusion. Re-attempting them wastes a lot of
time, so read this first.

- **Trackpad as a mouse: not possible while we read buttons.** Touch coordinates are only
  available through the private MultitouchSupport framework, and that framework returns
  **zero touch frames whenever any process holds the remote's HID interfaces open** — which
  we must do to read buttons. Verified exhaustively: stopping the app yields 447 touch
  events, running it yields 0; leaving the digitizer unseized, and not opening it at all,
  both still yield 0. Touch does **not** arrive over any HID input report either (a report
  callback on every interface captured only 3-byte `0xFB` button masks). Same wall applies
  to the projects this was modeled on (couchvox / goatremote / sirimote), which use the same
  framework.
- **Gyroscope/motion: hardware does not have it.** 2nd/3rd-gen Siri Remotes dropped the
  accelerometer and gyroscope. The two Sensor-page (`0x20`) HID interfaces handshake but
  never emit data. Only the 1st-gen remote had an IMU.
- **Replacing PacketLogger: no public API.** Live HCI capture on macOS is only available
  through Apple's PacketLogger and its private, undocumented mechanism. Bundling Apple's
  binary is not redistributable; reverse-engineering the private path is fragile. The
  dependency stays.

## Diagnostics & logs

- App log: `~/Library/Logs/VibeRemote/viberemote.log` (via `rmDebug`,
  size-bounded). Emoji-prefixed lines: `📡` GATT, `🔒` HID seize/listen,
  `🎮` button events, `🎙` audio listener, `🔊` volume guard.
- Privileged helper log: `/var/log/viberemote-helper.log` (daemon stdout/stderr).
- Bridge runtime dir (0700, private):
  `~/Library/Application Support/VibeRemote/MicrophoneBridge/`
  — `voice-helper.log` (decode progress), `packetlogger.log`, `packets.log`
  (raw HCI capture; may contain audio — keep local), `direct-hid-audio.log`.
- `MicrophoneBridgeDiagnostics.copyText` assembles a full status snapshot for
  the menu's "Copy diagnostics" action.

When verifying the bridge end-to-end, drive the real flow (Start → hold Siri →
speak) and check for `1B 35` frames in `packets.log` and `Decoded audio packets`
in `voice-helper.log`, not just that the process launched.

## Conventions

- Swift 5.9, `-strict-concurrency=complete` must stay clean. Managers are
  `@unchecked Sendable` with explicit `NSLock` / serial `DispatchQueue`
  discipline — follow the existing locking patterns; don't introduce data races
  to silence a warning.
- `@MainActor` for anything touching AppKit / CoreBluetooth delegates.
- Match surrounding comment density: these files explain *why* non-obvious
  platform workarounds exist. Preserve those rationale comments when editing.
- Never weaken the supervisor's root-side signature/ownership validation of
  PacketLogger and its helper — it guards a privileged install.
- Do not commit or push unless explicitly asked. When you do touch behavior,
  add/adjust `ModelTests.swift` where the logic is model-level and testable
  without hardware.

## Things that require real hardware

Button mapping, GATT/HID delivery, and audio decoding cannot be validated in CI.
Any change to `RemoteInputHandler`, `RemoteHIDChannel`, the supervisor script, or
the helper needs a manual test on a paired Siri Remote before it can be trusted.
