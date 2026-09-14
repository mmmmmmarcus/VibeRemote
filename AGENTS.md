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
| `RemoteGeneration.swift` | Tells the 1st-gen remote from the 2nd/3rd-gen one and holds every behavioral difference between them. |
| `RemoteInputHandler.swift` | Opens HID interfaces, maps buttons, sends synthetic key events, performs the `0xAF` input-enable Feature write. |
| `RemoteHIDChannel.swift` | Direct HID-over-GATT (CoreBluetooth) path — see caveats below. |
| `RemoteBatteryReader.swift` | Battery level via IOBluetooth/CoreBluetooth. |
| `BluetoothAccessManager.swift` | Bluetooth TCC authorization state. |
| `MediaKeyInterceptor.swift` | Intercepts system media keys the remote emits. |
| `SystemVolume.swift` | CoreAudio volume read/set + revert guard. |
| `MicrophoneBridgeManager.swift` | Orchestrates the mic bridge (both engines). The largest and most delicate file. |
| `RemoteAudioProtocol/SiriRemotePacketParser.swift` | Shared, testable HID/ACL/L2CAP audio parser for both remote families. |
| `VoiceBridgeHelper/main.swift` | **Separate executable** (`VibeRemoteVoiceBridge`): parses HCI/HID records, Opus-decodes, plays into the virtual audio device. |
| `PrivilegedHelper/main.swift` | **Separate executable** (`VibeRemoteHelper`): root LaunchDaemon registered via `SMAppService`; performs privileged work over XPC. |
| `HelperProtocol/HelperProtocol.swift` | Library target shared by the app and daemon: the XPC contract and shared identifiers. |
| `PrivilegedHelperClient.swift` | App-side registration/status/XPC calls for the daemon. |
| `Vendor/SiriRemoteVoiceControl/` | Prebuilt legacy helper binaries (compatibility fallbacks). |
| `Tests/VibeRemoteTests/ModelTests.swift` | Unit tests (pure model/enum logic; no hardware). |
| `build.sh` | SwiftPM build → universal `VibeRemote`, `VibeRemoteVoiceBridge`, `VibeRemoteHelper` binaries. |
| `install.sh` | Developer-ID-signed build deployed over `/Applications/VibeRemote.app`; the stable signature is what preserves the TCC grants. |
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

**Use `./install.sh` when installing for real testing.** It wraps the Developer ID
signing command and the deploy-and-relaunch dance below, because ad-hoc signatures change
every build, which revokes the app's Accessibility / Input Monitoring / Bluetooth TCC
grants and forces re-approval each time. A stable identity preserves them:

```bash
./install.sh                          # picks the first Developer ID identity
ARCHS="$(uname -m)" ./install.sh      # host-only, ~2x faster while iterating
```

Equivalent by hand:

```bash
SIGNING_MODE=developer \
CODESIGN_IDENTITY="Developer ID Application: <your identity>" \
./create_app_bundle.sh
osascript -e 'tell application "VibeRemote" to quit'
rm -rf /Applications/VibeRemote.app
ditto VibeRemote.app /Applications/VibeRemote.app
open /Applications/VibeRemote.app
```

CI (`.github/workflows/ci.yml`, `macos-15`) runs: `swift build`, `swift test`,
the strict-concurrency build, `bash -n` on both scripts, and `plutil -lint` on
the entitlements. Keep all of these green.

## Remote generations

Do not classify solely by HID report size: the user's physically confirmed black-glass
remote advertises 209-byte input/feature reports too. Product `0x026D` plus
`kBTHardwareRevisionKey = 0A00` is the observed old-hardware combination and takes priority
in `RemoteGeneration.classify`. Report size is only a fallback for unrecognized hardware;
it is not proof of generation. Classification uses the whole physical interface set.

- Classification is **per physical remote** (`deviceKey` = Bluetooth address, or the Apple
  serial over Lightning), not global. Both remotes can be paired at once, so button
  mappings and audio registrations key off the interface that produced the event;
  `RemoteGeneration.primary` only decides what the menu displays.
- A remote plugged in over Lightning enumerates as a single vendor-page interface with a
  1-byte report and no buttons. It classifies as `.unknown` and must never become the
  active remote — otherwise charging the old remote hijacks the profile of the paired one.
- The 1st-gen remote has **no Mute and no Power key**. The mute button's two jobs move
  to the only buttons whose baseline action is a single instantaneous press: TV gains
  the modifier hold, Play/Pause gains the "/" hold. That table lives in
  `RemoteGeneration.buttonActionOverrides`.
- Both generations use the physical Siri button for **Siri Button Mapping** and
  firmware-gated microphone capture. The old touch surface and new clickpad center
  keep the baseline Enter action; do not remap the old surface to Siri again.
- **Composite actions are profile-assigned, never user-chosen.** The Siri submenu iterates
  `ButtonAction.allCases`, so profile composites return `false` from
  `isAssignableToSiriButton`. `loadSiriButtonAction` re-checks it on read.
- Older remotes without a dedicated Consumer/0x04 audio collection have their voice
  frames sniffed off every interface whose reports could hold a 20 ms Opus frame
  (`RemoteInputHandler.shouldSniffAudio`). The confirmed 0A00 black-glass remote does
  expose a dedicated collection; prefer it and suppress other-interface sniffing for that
  physical remote. Sniffing is only safe because the voice helper
  confirms the framing per report — length prefix plus a CELT-only, single-frame Opus TOC
  byte — instead of assuming it; button reports on the same interface fail that check.
  **Never widen sniffing to the 2nd/3rd-gen remote**: it publishes audio on one dedicated
  collection, and the extra interfaces would pipe button reports into the decoder.
- Sniffed interfaces keep handling buttons. `handleInputValue` only diverts a value to the
  audio parser when the interface is a dedicated audio collection or the value is wider
  than `maximumButtonValueLength`.

Both generations encode CELT-only, single-frame Opus and the decoder outputs 48 kHz
regardless of the encoded bandwidth, so one decoder configuration serves both. The
vendored legacy helper decoded at 16 kHz purely because that was its output rate — that is
**not** evidence of a second codec configuration, and re-deriving one wastes time.

## Button mappings and hold behavior

Mappings are **fixed by design** — `remoteButtonDescriptors` in `MenuBarManager.swift` is the
single source of truth. Only the **Siri button** is user-customizable (persisted under the
`siriButtonAction` default); everything else is hardcoded and has no menu UI.

Current intent: clickpad arrows → arrow keys, clickpad center → Enter, Back/Menu →
word-wise Backspace (Option+Delete — macOS `deleteWordBackward:`, whose tokenizer also
segments Chinese words; repeat runs at a slower word cadence than character repeat),
TV → Shift+Enter (newline, the convention agent apps use), Play/Pause → toggle
the Codex/Claude desktop client to the front, Power → Enter, volume keys → bullet-list
control, Siri → held Space, Mute → tap types "/" (the skill/command-picker trigger in
agent apps); held, it is a modifier: Mute+Back clears all input (Cmd+A, Backspace) and
Mute+Play/Pause sends Esc (stop the current task).

**The remote reports one press and one release with no repeats in between.** Key repeat and
tap/long-press are therefore synthesized in `RemoteInputHandler`:

- `beginRepeating` drives auto-repeat (Backspace, arrows) with a safety tick cap in case a
  release event is ever dropped.
- `beginTapOrLongPress` distinguishes a tap from a hold (volume-up: tap indents, long-press
  starts a bullet). Timers are torn down on release and on disconnect.
- `beginModifierHold` / `resolveModifierRelease` make the mute button a tap-or-modifier
  key: a quick release types "/", a hold arms the chords in `modifierChord(for:)` (chorded
  buttons skip their normal action entirely, including auto-repeat). Concurrent presses are
  safe: the firmware reports buttons as independent HID events, verified with overlapping
  press intervals in real logs (mute held + playPause both delivered).
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
  Root access comes from the approved privileged helper daemon over XPC (no
  prompt); when the daemon is unavailable or stale it degrades to a one-off
  `osascript … with administrator privileges` password prompt.

### Landmines in the PacketLogger supervisor (`PacketLoggerBridge.supervisorCommand`)

The root supervisor is a shell script built in `HelperProtocol/HelperProtocol.swift`,
shared so the helper daemon and the osascript fallback run byte-identical scripts
(`ModelTests` pins the landmines below). Two bugs here previously made the whole
path look impossible; do not regress them:

1. **stdin must never reach EOF.** `packetlogger convert -s` treats stdin EOF as
   Ctrl-D and immediately prints `Disconnected from OS X Device`. It reads a
   read-write keepalive FIFO (`0<> "$stdin_keepalive"`), never `/dev/null`.
2. **PPID probe needs `exec`.** `supervisor_pid=$(exec /bin/sh -c 'echo $PPID')`.
   Without `exec`, sh forks one level deeper and reports the wrong parent, so
   every `is_direct_child` check fails and the supervisor kills the capture in
   the first second.
3. `defaults write com.apple.PacketLogger 'Last UsedPacket Priority Set' -int 3`
   is required or the CLI dumps the device inventory and disconnects.

The helper is now version 3: first-run PacketLoggerHelper plist creation seeds a valid XML
dictionary before PlistBuddy writes entries. Never pre-create a zero-length plist; current
macOS rejects it with "Cannot parse a NULL or zero-length data". The model test executes
this exact generated fragment without privileges and checks the resulting launchd keys.

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
- **`AVAudioEngine` stops itself on any audio-hardware reconfiguration and never
  restarts.** Connecting or disconnecting a Bluetooth headset is exactly that (it
  adds/removes CoreAudio devices), which is why the bridge went silent whenever
  earbuds came or went. The failure is invisible from every angle that was being
  checked: `scheduleBuffer` keeps accepting buffers, `player.isPlaying` keeps
  reporting true, and the helper's "Decoded audio packets" counter keeps climbing
  — that counter only proves the Opus decoder ran, never that anything rendered.
  `VirtualAudioOutput` observes `.AVAudioEngineConfigurationChange` and rebuilds a
  fresh engine pinned to the re-resolved device. Two things this must keep doing:
  starting an engine is *itself* a configuration change, so a quiet window plus an
  `isRunning` check is what stops the handler feeding itself (an unguarded version
  rebuilt 21 times in 4 seconds); and the rebuild stops only the outgoing *engine*,
  never the outgoing player node, because stopping a player is the deadlock below.
- On start the helper skips PacketLogger's buffered replay (records older than
  launch) so a stale prior session is not re-decoded into the output device.
- Audio format: Opus CELT-only, 48 kHz mono, 960 samples/frame, 99-byte HID
  payload, enable byte `0xAF`, report ID `0xFA`. Cross-checked against
  https://github.com/azais-corentin/siri-remote.

### No mode toggles

There is no microphone mode and no input mode. With the app open the bridge is always
meant to be running, and the output stream stays warm for the bridge's lifetime (no
`Stop` action). Earlier builds had `MicrophoneMode` and `MicrophoneInputMode` enums;
both were removed because the firmware gates the mic to physical Siri-button holds, so
a "continuous" mode could not do what its name implied.

The bridge auto-starts at launch via `startAtLaunchIfPromptFree()`, but only when the
start is guaranteed silent (Direct HID engine, or PacketLogger engine with the approved
helper daemon current). Anything that would raise an administrator prompt stays behind
the explicit `Start`/`Restart` menu action — app launch must never surprise the user
with a password dialog.

### Automatic recovery and bounded keepalive experiment

The 3-second bridge health check restarts stopped voice helpers or supervisors with
3/6/12/24/48/60-second retry delays. Reset the failure history only after 60 seconds
of healthy operation. `wantsBridgeRunning` is queue-confined and cleared on shutdown;
all automatic start paths pass `allowAdministratorPrompt: false` through to the
supervisor boundary, even if helper approval changes during startup. Reconnect
recovery must also cover an already-stopped bridge. Mac wake requests recovery.
The independent HID registry watchdog remains at 15 seconds.

`remoteKeepAliveExperimentUntil` is an optional Unix timestamp, not a permanent
mode. Until it expires, RemoteHIDChannel may read the current peripheral's battery
characteristic every 20 seconds. It stops on disconnect, expiry, or three errors.
Successful reads prove communication only, not prevention of firmware sleep. Keep
this disabled by default; do not claim both-generation keepalive from one remote.
The 2026-09-14 black-glass test failed: reads succeeded through 08:59:56, but
the remote disconnected at 09:00:04, about two minutes after startup. The local
experiment was disabled. Do not re-enable battery polling as a proven keepalive.

### Bluetooth topology changes

`IOBluetoothDevice` offers a class-level `register(forConnectNotifications:)` but has **no
disconnect counterpart** — disconnects must be registered per device, one object at a time.
Missing that is why the bridge used to need a manual restart after a headset disconnected:
nothing in the app observed it. `AppDelegate` now arms a one-shot disconnect observer on
every device as it connects (plus everything already connected at startup, which never fires
the connect observer), and both edges run the same debounced `scheduleBridgeRecovery`.

### The HID watchdog (silent re-enumeration)

Starting screen mirroring (and likely other Bluetooth-stack reconfigurations) can make
macOS silently re-enumerate the remote's HID services. The app's open `IOHIDDevice`
objects then stop firing callbacks **without any removal notification**: buttons die,
the firmware's `0xAF` voice enable resets, voice frames stop — and nothing anywhere
reports an error (capture keeps flowing, the helper idles in `readLine`, battery reads
keep succeeding). `RemoteInputHandler` records each interface's IOKit registry entry ID
at open; the 15-second health timer asks `hasStaleInterfaces()` — registry IDs are never
reused, so a held ID that no longer resolves is definitive — and re-arms the whole
detection path, which re-seizes the fresh interfaces and re-writes `0xAF`. Do not
replace this polling probe with IOKit removal notifications alone; the entire reason it
exists is that the removal callback provably does not arrive in this scenario.

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

### Registration gotchas (each cost real debugging time)

- **A standalone daemon executable needs an embedded `__TEXT,__info_plist`.** Ours comes
  from `PrivilegedHelper/Info.plist` via linker flags in `Package.swift`. Without it launchd
  refuses to load the program and registration fails with "Operation not permitted".
- **`register()` throws EPERM when the daemon is already registered and pending approval.**
  That is not a failure. Check `status` after the throw and trust it over the error;
  otherwise a perfectly good setup is reported to the user as broken.
- **The app must run from `/Applications`.** From `~/Applications` the daemon plist resolves
  to `.notFound`.
- Approval state lives outside the app: `launchctl print system/com.viberemote.helper` and
  `launchctl print-disabled system | grep viberemote` are the ground truth when the UI and
  reality disagree. `job state = uninitialized` is normal — an XPC daemon launches on first
  connection.
- Registration cannot be tested from a plain command-line tool, because `SMAppService` reads
  the plist from `Bundle.main`. To iterate without a human clicking, build a minimal signed
  `.app` in a scratch directory whose executable calls `register()` and prints the full
  `NSError`, then run it from `/Applications`.

### Migration status (what still raises a password prompt)

The helper owns audio-driver installation **and** PacketLogger capture
(`startPacketLoggerCapture`, introduced in v2; current minimum v3): with the daemon approved, starting the
bridge no longer prompts. The design constraint held — the voice helper stays in the
user's CoreAudio session; only the capture supervisor runs as root, launched by the
daemon instead of osascript, with the same FIFO data channel and the same stop-signal
file. The prompt survives in exactly two cases: the daemon is not approved / not
reachable, or an approved daemon is still **running a pre-v3 binary** (a replaced app
bundle does not restart a live daemon — the app probes `helperVersion` first and falls
back rather than calling a selector the old process lacks; `sudo launchctl kickstart -k
system/com.viberemote.helper` or re-registration picks up the new binary).

Root-side trust does not come from the XPC client: the daemon takes the caller's
uid/pid from the connection (never from parameters), accepts only a canonical UUID as
the supervisor token, and the shared script re-validates directory ownership, FIFO
safety, and Apple code signatures before touching the system — same checks as the
prompt path, because it *is* the same script.

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

### Old-remote PacketLogger framing (confirmed 2026-09-13)

The black-glass remote sends ATT `1B 23 00` notifications. Start/end payloads are
`1B 23 00 00 10` / `1B 23 00 10 00`; complete audio payloads carry the Opus length
at byte 9 and packet at byte 10. Reassemble L2CAP using the actual ACL connection
handle (0x0043 observed), never hardcode 0x0040 or assume 31-byte ACL records.
The shared RemoteAudioProtocol target tests fragmentation and interleaved generations.
`VibeRemoteVoiceBridge --validate-capture < capture.log` decodes locally without opening
an audio device, reporting packet count and peak. Capture may contain speech; keep local.
