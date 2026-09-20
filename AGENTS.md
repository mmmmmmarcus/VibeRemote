# AGENTS.md

Guidance for AI coding agents working in the VibeRemote repository. Read this
before making changes — several subsystems depend on hard-won, non-obvious
platform behavior that is easy to break.

## What this project is

VibeRemote is an experimental macOS **menu-bar app** (`LSUIElement`, Dock icon
shown while Settings is open) that:

- Maps Apple Siri Remote buttons to keyboard actions, aimed at driving AI agent apps
  (arrows, Enter, Shift+Enter, Backspace, bullet-list control, app switching).
- Shows the paired remote's connection and battery state.
- **Bridges the Siri Remote microphone** into its own virtual audio device
  ("VibeRemote") so the remote can be used as a system mic.

It is a three-executable SwiftPM package (app, voice bridge, privileged helper) plus a
shared library target and shell scripts that build the audio driver and assemble/sign the
`.app` bundle. There is no Xcode project file.

This is a personal-use build targeting macOS 27.0. Keep the SwiftPM platform, build-script
deployment target, and generated app bundle minimum system version aligned at 27.0.

## Repository layout

| Path | Role |
|------|------|
| `main.swift` | App entry point (`NSApplicationMain`-style bootstrap). |
| `SiriRemoteApp.swift` | `AppDelegate`: wires managers, permissions, lifecycle. |
| `MenuBarManager.swift` | Status-item menu, mapping ownership and settings-window state updates. |
| `SettingsWindowController.swift` | Retained native settings window, SwiftUI remote diagram, native mapping pop-ups, live status snapshot. |
| `RemoteDetector.swift` | IOKit HID discovery of the remote; also defines `vibeRemoteLogPath` and `rmDebug`. |
| `RemoteGeneration.swift` | Tells the 1st-gen remote from the 2nd/3rd-gen one and holds every behavioral difference between them. |
| `RemoteInputHandler.swift` | Opens HID interfaces, maps buttons, sends synthetic key events, performs the `0xAF` input-enable Feature write. |
| `ListEditingController.swift` | Reads the focused editor through AX and plans native list/indent commands without rewriting its text. |
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

`remoteButtonDescriptors` in `MenuBarManager.swift` defines the default mappings. The Siri
button is customizable (`siriButtonAction`). Play/Pause and Mute each offer their original
generation-specific action or Touch / Audio mode switching (`modeSwitchButtons`). Other
buttons remain fixed. Switching executes once on release, never on repeats or orphan releases.

Every physical remote gets a two-second input quarantine when its HID interfaces open.
`RemoteConnectionInputGate` keys it by `deviceKey`, so connecting one generation does not
disable an already-stable remote of the other generation; later interfaces for the same
remote extend its deadline. Suppressed HID transitions update `buttonState` but perform no
mapping or microphone action. The same opening event arms `VolumeRevertGuard` so AVRCP/media
volume changes that bypass HID mappings are consumed and reverted to the warm baseline.
Do not implement this only as a delay in button dispatch: that leaves system volume exposed.

The settings artwork and callout placement must support **two distinct physical
layouts**. First generation uses the user's supplied `Resources/SiriRemoteFirstGeneration.png`:
Menu / TV on the upper button row, microphone / volume-up on the middle row,
Play/Pause / volume-down below, and touch-surface press = Enter. Second/third
generation retains `Resources/SiriRemote.png` with its own Power, side-Siri and Mute
positions. `RemoteSettingsLayout` selects both artwork and callout coordinates from
the snapshot generation. Never reuse the aluminum photo with hidden controls as the
first-generation layout. Both resources must be bundled; verify light/dark rendering
and switching generations in the same settings window. Siri and Play/Pause are editable in
both layouts; Mute is editable only where it physically exists. Preserve first-generation
composite defaults unless Play/Pause is explicitly assigned to mode switching.

Opening Settings switches the app's activation policy to `.regular` so its Dock icon
appears. Closing the window restores `.accessory`; minimizing keeps the Dock icon so
the user can restore the window. Keep `LSUIElement` for menu-bar-only launch.

Settings uses a system window backdrop with an edge-to-edge transparent title bar.
Mapping pop-ups remain native `NSPopUpButton`s inside interactive `NSGlassEffectView`
capsules, batched by `NSGlassEffectContainerView`. Keep the hosting content transparent;
do not restore an opaque white fill or stack an extra button bezel over the glass.
System materials own light/dark, contrast and Reduce Transparency behavior.
The trailing ellipsis uses `NSMenuToolbarItem` and a native menu for Reset. Keep
the menu available when defaults are active; disable only its Reset item.

The first menu row is the complete device summary. While connected, it shows `Connected`
and the remote generation on the left, plus a green circular battery gauge with the numeric
percentage centered on the right. While the remote is connected and its always-on bridge is
still coming up, replace `Connected` with `Starting`; the menu-bar remote glyph uses a refresh
badge during the same interval. While disconnected, the row shows only `Disconnected`. There
is no separate stopped-bridge banner and no pause badge. Do not repeat Bluetooth, generation,
or battery as separate rows below this summary.

The menu bar's **Settings…** entry opens one retained window, even with the remote
disconnected. Siri offers its action list; Play/Pause and Mute offer their default or a mode
toggle. Other pop-ups show one explanation, without a redundant Fixed mapping row. Reset
restores Siri and the two optional mode switches. Window state comes from `MenuBarManager`
and must not create a second HID/Bluetooth manager. The exact Figma artwork is a SwiftPM
resource; `build.sh` stages its bundle and `create_app_bundle.sh` embeds it in
`Contents/Resources`, which `SettingsAssets` resolves before the CLI `Bundle.module` fallback.

Current intent: clickpad arrows → arrow keys, clickpad center → Enter, Back/Menu →
word-wise Backspace (Option+Delete — macOS `deleteWordBackward:`, whose tokenizer also
segments Chinese words; repeat runs at a slower word cadence than character repeat),
TV → Shift+Enter (newline, the convention agent apps use), Play/Pause → toggle
the Codex/Claude desktop client to the front, Power → Enter, volume keys → bullet-list
control, Siri → held Space, Mute → tap types the focused app's skill-picker trigger
(`$` in `com.openai.codex`, also locally named ChatGPT.app; `/` in Claude and other apps).
Resolve focus on release, and preserve the legacy `slashOrModifier` raw value for saved
Siri assignments. Held, it is a modifier: Mute+Back clears all input (Cmd+A, Backspace) and
Mute+Play/Pause sends Esc (stop the current task).

**The remote reports one press and one release with no repeats in between.** Key repeat and
tap/long-press are therefore synthesized in `RemoteInputHandler`:

- `beginRepeating` drives auto-repeat (Backspace, arrows) with a safety tick cap in case a
  release event is ever dropped.
- Volume keys share one smart-list path across both remote generations. On button-down,
  they schedule one action after a short delay; do not dispatch Cmd+Shift+8 synchronously
  from the volume release callback because Codex drops it. `ListEditingController` reads
  the focused Codex editor's value, selection, caret hierarchy and attributed list markers.
  Volume-up creates a list from a paragraph or indents a list item; volume-down outdents a
  list item (the editor removes the list at its outer edge). It invokes Codex's native
  Cmd+Shift+8 / Tab / Shift+Tab commands so text, formatting, selection and undo remain
  editor-owned. It never rewrites the AX value or keeps remembered list state. Composing
  text, multi-paragraph selections, code blocks, unsupported apps, timeouts and ambiguous
  AX results use a bounded per-focused-editor fallback because current Codex builds flatten
  ProseMirror structure: the first volume-up creates a list, subsequent volume-up taps
  indent it, and volume-down walks out/removes it. This fallback exists to keep short press
  functional. A tap and a hold both fire exactly once; long press must never be required
  for normal list use.
- `beginTapOrLongPress` distinguishes a tap from a hold for the remaining composite
  actions. Timers are torn down on release and on disconnect.
- `beginModifierHold` / `resolveModifierRelease` make the mute button a tap-or-modifier
  key: a quick release types "/", a hold arms the chords in `modifierChord(for:)` (chorded
  buttons skip their normal action entirely, including auto-repeat). Concurrent presses are
  safe: the firmware reports buttons as independent HID events, verified with overlapping
  press intervals in real logs (mute held + playPause both delivered).
- An earlier attempt remembered bullet-list "context" after a press. It was unreliable
  because manual typing, cursor moves and focus changes desynchronized it. Always observe
  the current editor at the instant of the action; do not reintroduce cached editor state.

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

The helper is now version 4 (shared-memory preparation); v3 added: first-run PacketLoggerHelper plist creation seeds a valid XML
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
- The black-glass remote flushes about 2.1 seconds of audio after physical Siri-button
  release. Its mapped dictation key must stay held through protocol end and output drain.
  `voice-ended` reports protocol end; `voice-drained` reports output completion, tagged
  with the hold's start time. A 4-second old / 3-second new remote safety deadline prevents
  stuck keys. Stale completions must not release a later Siri hold.
- Audio format: Opus CELT-only, 48 kHz mono, 960 samples/frame, 99-byte HID
  payload, enable byte `0xAF`, report ID `0xFA`. Cross-checked against
  https://github.com/azais-corentin/siri-remote.

### Audio and touch modes

`RemoteInteractionMode` selects Audio & Buttons or experimental Touch. In audio mode
with the app open the bridge is always meant to run. Touch mode explicitly releases HID
and GATT handles and uses NativeTouch. Passive PacketLogger capture stays alive across
mode changes; a private interaction-mode file disables voice decoding in Touch, and the
app restores the previous default microphone. Recovery may restart passive capture in
Touch, but must never reclaim HID/GATT interfaces. The output remains warm and silent.
The remote's NX media events have no sender metadata on this Mac. The private HID event
monitor also delivered no callbacks (requires Apple's private entitlement); do not restore
that failed experiment. PacketLoggerButtons reads fresh, source-filtered ATT 0039 button
masks from the private capture log. On the aluminum remote's report FB descriptor, mute
is bit 7 and play/pause bit 8. Old-remote 0023 voice records are not button masks.
Aluminum mode-switch keys have one passive-capture owner in both modes, including the
2-second HID opening quarantine. Do not also toggle them from HID or stop correlation
in Audio. Keep in-flight press pairs and markers across mode changes. HID reopening can
stall the main loop: retain capture records for 3 seconds but compare against the original
CGEvent timestamp (not callback arrival), retaining the narrow 180 ms match window.
The NX tap holds only configured switch keys for 160 ms and consumes a matching captured
edge within a bounded timestamp window. Unmatched events are forwarded once. This is
experimental temporal correlation, not sender identity proof: simultaneous keyboard and
remote presses can remain ambiguous. Keep the toolbar as the escape hatch. Preserve
cross-mode release consumption and bounded repeat handling. Hardware testing must verify
both directions, touch motion, and unrelated keyboard media keys after any change.
Switching back restores audio and fixed mappings. Earlier builds had `MicrophoneMode` and `MicrophoneInputMode` enums;
both were removed because the firmware gates the mic to physical Siri-button holds, so
a "continuous" mode could not do what its name implied.

The bridge auto-starts at launch via `startAtLaunchIfPromptFree()`, but only when the
start is guaranteed silent (Direct HID engine, or PacketLogger engine with the approved
helper daemon current). Anything that would raise an administrator prompt stays behind
the explicit `Start`/`Restart` menu action — app launch must never surprise the user
with a password dialog.

For the PacketLogger engine, launch the user-session `VibeRemoteVoiceBridge` reader before
starting the privileged PacketLogger supervisor. A reconnecting remote can emit its voice-start
marker during supervisor startup; if the helper launches second, its replay filter discards that
marker and the rest of the Siri hold is undecodable. Menu readiness is a separate state from
process liveness: keep `Starting` and the refresh badge until both processes pass the final
startup checks. Clear readiness as soon as a Bluetooth topology edge schedules recovery, before
the debounce expires. Never mark the bridge connected merely because the voice-helper process
exists.

### Automatic recovery and bounded keepalive experiment

The 3-second bridge health check restarts stopped voice helpers or supervisors with
3/6/12/24/48/60-second retry delays. Reset the failure history only after 60 seconds
of healthy operation. `wantsBridgeRunning` is queue-confined and cleared on shutdown;
all automatic start paths pass `allowAdministratorPrompt: false` through to the
supervisor boundary, even if helper approval changes during startup. Reconnect
recovery must also cover an already-stopped bridge. Mac wake requests recovery.
The independent HID registry watchdog remains at 15 seconds.

Idle disconnect can close every app-owned HID handle while IOHIDManager retains the same
services. A Bluetooth reconnect then emits no HID remove/add callback. Reconcile connected
Bluetooth remotes against `RemoteInputHandler.openedInterfaceIDs` both on connect and on the
15-second watchdog, including when no handles remain. Only replay missing interfaces for
currently connected addresses; exclude the pending GATT/idle-close interval, sleeping remotes
and wired charging interfaces. Do not equate detector inventory with open input handles.

`remoteKeepAliveExperimentUntil` is an optional Unix timestamp, not a permanent
mode. Until it expires, RemoteHIDChannel may read the current peripheral's battery
characteristic every 20 seconds. It stops on disconnect, expiry, or three errors.
Successful reads prove communication only, not prevention of firmware sleep. Keep
this disabled by default; do not claim both-generation keepalive from one remote.
The 2026-09-14 black-glass test failed: reads succeeded through 08:59:56, but
the remote disconnected at 09:00:04, about two minutes after startup. The local
experiment was disabled. Do not re-enable battery polling as a proven keepalive.

Both known remote families re-send only the already-successful Feature report `FF AF`
every 45 seconds on their writable interfaces. The black-glass physical test confirmed an
immediate button response after more than twice its former 3–4-minute sleep interval;
aluminum-remote wakefulness, button input and voice after sustained idle still need hardware
verification. Do not infer that from successful Feature writes. The shared Auto Disconnect
setting controls an idle deadline (5/15/30 minutes or Never); the default is 5 minutes and the
legacy `firstGenerationIdleTimeoutSeconds` key preserves saved choices. Every real button press
resets only that physical remote's deadline. At expiry, stop keepalive and release its HID
interfaces before asking `IOBluetoothDevice` to close the link. Unknown/charging-only devices
never enter this path; battery polling remains disabled.

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
(`startPacketLoggerCapture`, introduced in v2; capture minimum v3; direct shared-memory HAL minimum v4): with the daemon approved, starting the
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
  **zero touch frames whenever any process holds the remote's HID interfaces open**.
  Touch mode now releases those handles before loading NativeTouch; do not reopen them
  from permission polling, watchdogs or Bluetooth callbacks while touch mode is selected. Verified exhaustively: stopping the app yields 447 touch
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
  binary now has an optional personal-build packaging path; preserve Apple's original
  signature and complete bundle. Public release packaging requires a separate
  redistribution review. The capture dependency stays.

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

## Direct shared-memory HAL experiment

`SharedAudio/` is the common C wire implementation for the decoder and HAL. The helper
v4 creates only the authenticated XPC peer's fixed UID path (root directories, 0660
user:_coreaudiod file, no symlinks). `scripts/patch_audio_driver.py` applies the HAL
changes to pinned BlackHole source. Rebuild the driver after changing C source; bundle
and install it separately from Swift. `scripts/test_shared_audio.c` exercises the
production ring across forked processes without root. Keep render allocation/file
operations/locks out of the IO callback, preserve generation-tagged acknowledgements,
and use the same-cycle cache for multiple input clients. An old driver/helper, missing
mapping or explicit Compatibility selection retains the previous AVAudioEngine route.
No source or binary from CouchVox is bundled.

### Siri release regression (2026-09-20)

A new remote's `1B 39` end marker can precede its final `1B 35` packet by one BLE
interval (observed 16 ms, sequence 57 → end → 58 → zero-length sentinel). Match that
consecutive sequence to the ending session per ACL handle, rather than emitting a
new start and resetting the shared ring. `SettlingAudioOutput` serializes all output
calls and waits for a 250 ms quiet interval after protocol end before snapshotting
the drain target. A reset sequence or an expired tail window starts a real new hold.
On aluminum remotes, a fresh Siri press during pending drain must release the previous
mapped key and emit a fresh key-down; only the old remote retains its firmware-tail
hold reuse. See `testNewRemoteTrailingPacketDoesNotStartAnotherVoiceSession`.
