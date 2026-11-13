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

The repository has two top-level folders:

- `app/` — the macOS product: SwiftPM package, scripts, resources, tests, design/research
  material, release tooling and the product `README.md`. **Every path in this file is
  relative to `app/` unless it says otherwise**, and every build/test command runs from
  `app/` (the scripts resolve paths from their own location, so `app/build.sh` also works).
- `website/` — the static official site (`index.html`, `styles.css`, `assets/`). No build
  step, no JavaScript framework. Its paint texture and icons are derived from
  `app/Resources/OnboardingSky.png` and `app/VibeRemoteAppIcon.png`; regenerate them with
  `sips` (see `website/README.md`) instead of committing the multi-megabyte originals twice.

Only `.github/`, `.gitattributes`, `.gitignore`, `AGENTS.md`, `LICENSE` and the overview
`README.md` stay at the repository root. CI sets `working-directory: app`.

| Path (under `app/`) | Role |
|------|------|
| `main.swift` | App entry point (`NSApplicationMain`-style bootstrap). |
| `SiriRemoteApp.swift` | `AppDelegate`: wires managers, permissions, lifecycle. |
| `MenuBarManager.swift` | Status-item menu, mapping ownership and settings-window state updates. |
| `SettingsWindowController.swift` | Retained native settings window, SwiftUI remote diagram, read-only button callouts, Siri action pop-up, live status snapshot. |
| `RemoteDetector.swift` | IOKit HID discovery of the remote; also defines `vibeRemoteLogPath` and `rmDebug`. |
| `RemoteGeneration.swift` | Tells the 1st-gen remote from the 2nd/3rd-gen one and holds every behavioral difference between them. |
| `ButtonProfiles.swift` | Per-app button profiles: `ButtonProfileSet` (General + app profiles, resolution, editing, seeds), `ButtonProfileStore`, `ButtonProfileLatch`, `InstalledApp` scan for Add App. |
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
| `build.sh` | SwiftPM build → arm64-only `VibeRemote`, `VibeRemoteVoiceBridge`, `VibeRemoteHelper` binaries. |
| `install.sh` | Developer-ID-signed build deployed over `/Applications/VibeRemote.app`; the stable signature is what preserves the TCC grants. |
| `build_audio_driver.sh` | Builds the branded `VibeRemoteAudio.driver` from upstream BlackHole source. |
| `create_app_bundle.sh` | Runs `build.sh`, assembles `.app` (incl. driver + daemon plist), signs, optionally notarizes. |
| `Dictation.swift`, `DictationEngines.swift`, `DictationPane.swift` | VibeRemote Dictation: recorder, typer, controller; Apple/WhisperKit/OpenAI/Seed ASR engines; Settings pane. |
| `DictationStreaming.swift` | Streaming dictation: Volcengine SAUC frame codec and WebSocket session, the `bigmodel_nostream` refinement session, the typewriter that types and corrects partials, the per-hold live state, and the `--verify-seed-stream` check. |
| `DictationDictionary.swift` | The dictation dictionary: entries (one word each), storage, Seed hotword budget/context, OpenAI prompt, and the local replacement pass. |
| `DictationFillers.swift` | Local filler-word cleanup of Seed's final text (hesitations, clause fillers, stutters), applied when Remove Filler Words is on. |
| `DictationHotkey.swift` | The alternative dictation hotkey: modifier choices, `DictationHotkeyGate` (hold/chord logic), and the global+local event monitor driving `DictationController` with the Mac's microphone. |
| `AutoComputerUse.swift` | Auto Computer Use: its switch, the focused-text-field probe at Siri down, and `ComputerUseHandoff` (how a dictation hold fills and sends the Computer Use bar). |
| `VibeRemote.entitlements` | `com.apple.security.device.bluetooth` and `com.apple.security.device.audio-input` (Dictation records the virtual device under the hardened runtime). |

## Build, run, test

Always build through SwiftPM / the scripts — never hand-invoke `swiftc`.

Target Apple Silicon (arm64) only, including the audio driver. Do not build Intel or
universal binaries; the scripts reject non-arm64 ARCHS overrides. Default builds use
an owned temporary scratch directory and remove it on success, failure or handled
interruption. Only set KEEP_BUILD_CACHE=1 for an active incremental session; it uses
one .build/swiftpm directory. Run ./scripts/clean-build.sh after tests or that session.
Do not leave per-task /tmp scratch builds or parallel native/Xcode architecture caches.
Cleanup must run after all builds/tests stop and must preserve Git, source, uncommitted
work, installed apps and completed app/driver outputs. The driver removes its temporary
source and DerivedData unless WORK_DIR was explicitly supplied; retain corresponding
source deliberately when preparing a driver distribution under GPL-3.0.


```bash
# Apple Silicon build; temporary compiler caches are removed on exit
./build.sh

# Audio driver (only needed when it changes; output is gitignored)
./build_audio_driver.sh

# Apple Silicon signed bundle (what actually gets installed)
./create_app_bundle.sh                 # ad-hoc signed (local "-")
open VibeRemote.app

# Unit tests + strict concurrency (CI runs both)
swift test
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete
./scripts/clean-build.sh
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
KEEP_BUILD_CACHE=1 ./install.sh      # optional incremental development only
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

CI (`.github/workflows/ci.yml`, `xcode-27`, arm64 / macOS 27, inside `app/`) runs: `swift build`, `swift test`,
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
- The 1st-gen remote has **no Mute and no Power key**. Its TV used to take over the mute
  button's modifier hold and Play/Pause its "/" hold; both were removed on 2026-11-13 (user's
  request: **no button but Siri responds to a hold**). Its TV is a plain Shift+Enter and its
  Play/Pause opens Advanced Menu; `RemoteGeneration.buttonActionOverrides` is now empty for
  every family. Do not add hold-to-do-something-else actions back: auto-repeat (Back, arrows)
  repeats the same action and stays.
- Both generations use the physical Siri button for **Siri Button Mapping** and
  firmware-gated microphone capture. The old touch surface and new clickpad center
  confirm active caret positioning; outside it, old surface press is Enter and aluminum center is reserved. Do not remap the old surface to Siri again.
- **Siri takes only dictation actions.** Siri only takes the held
  dictation keys (Space, Right Command, Right Option; user's choice 2026-11-08) plus
  `vibeDictation` (`isAssignableToSiriButton` = `requiresHold || vibeDictation`), and `loadSiriButtonAction` re-checks it on read, so an
  older saved Siri choice outside that set falls back to Space.
- **Per-button remapping (2026-11-08, user's request).** Settings' pills edit Back/Menu, TV,
  Play/Pause (aluminum), Volume Up/Down and Power. `RemoteButtonMapping.choices` is the one
  list of what each may take (its default first; TV only `isInstant` actions because its tap
  waits for release so a hold opens Computer Use); nil means a fixed role: the Advanced Menu
  opener, the touch surface / clickpad center, the clickpad ring and directions. Choices are
  stored per generation under `buttonActionOverrides` and validated on read and on dispatch,
  keyed by `overrideKey` (HID "menu" → "back"). New actions: Command+Enter, Undo, Redo.
  Remapping changes only what a button sends: Advanced Menu ownership, chords, the volume
  revert guard and passive-capture ownership still key off the physical button.
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

`remoteButtonDescriptors` in `MenuBarManager.swift` defines the default mappings. Settings'
pills customize Siri and the ordinary buttons per profile (`ButtonProfileSet`; see Per-app
button profiles). `RemoteButtonMapping` is the
shared source of truth for runtime and Settings callouts. Aluminum Play/Pause opens Computer Use outside Advanced Menu (`.computerUse`,
2026-11-13, user's request; it was Esc from 2026-11-11, when per-app profiles made the app-detecting `.skillPicker`
default unnecessary; Esc and Skill remain choices).
Its native media event remains consumed. Within the menu it stops the current task.
The aluminum menu TV slot is now inactive and consumes both edges without a newline;
old-remote TV retains Skill because its Play/Pause is the menu opener. Power sends
Cmd+Enter in the menu and ordinary Enter outside it. Power remains HID-owned: never
add it to the passive-capture auxiliaryButtons set. Menu ownership consumes repeats
and releases, including when the menu closes before the opener is released.
Mute always opens Advanced Menu; old-remote Play/Pause is its opener. Legacy
`modeSwitchButtons` defaults are ignored. Mode switching remains available in Settings,
and the aluminum Advanced Menu. Never restore per-button mode assignment.

Every physical remote gets a two-second input quarantine when its HID interfaces open.
`RemoteConnectionInputGate` keys it by `deviceKey`, so connecting one generation does not
disable an already-stable remote of the other generation; later interfaces for the same
remote extend its deadline. Suppressed HID transitions update `buttonState` but perform no
mapping or microphone action. The same opening event arms `VolumeRevertGuard` so AVRCP/media
volume changes that bypass HID mappings are consumed and reverted to the warm baseline.
Do not implement this only as a delay in button dispatch: that leaves system volume exposed.

Settings uses the user's two STEP assemblies as the geometry source of truth:
`Design/RemoteModels/Apple_TV_4K_Remote.step` is the first-generation black-glass model;
`Design/RemoteModels/Siri Remote 2021.step` is shared by second and third generations.
Do not replace their shapes with procedural approximations. `scripts/convert_remote_models.py`
uses FreeCAD offline to tessellate every solid/face and preserve CAD colors into the
bundled `Resources/RemoteModels/*.dae`; accompanying JSON records source SHA-256,
coordinate transform, uniform display scale, solid counts and control coordinates.
Keep the original STEP bytes and regenerated assets together. FreeCAD is a conversion
tool only, never an app/build prerequisite. Both meshes must load from the installed
SwiftPM resource bundle; verify the final app, not just development paths.

`RemoteModelView.swift` uses a transparent on-demand SceneKit view. Preserve separate
black-glass and aluminum layouts, including side Siri, Mute and Power only on aluminum.
First-generation CAD has no printed legends: small ink planes use imported button-face
bounds, without replacing the CAD buttons. The aluminum symbols are CAD geometry.
`RemoteSettingsLayout` callouts follow the converted control coordinates in a 398-point
reference frame, projected into a 320-point preview (tall enough for one pill per row; 460 points wide so
it fits the 720-point window)
with camera padding; keep pills aligned when changing display scale. Drag has continuous pitch/yaw with logarithmic resistance and no hard angle limits and release restores the guide pose; Reduce
Motion skips that animation. No remote actions, extra HID/Bluetooth managers, idle spin
or frame timers. Keep `rendersContinuously` and `isPlaying` off; rebuild only on generation
changes. Check both generations in light/dark appearance and in the same retained window.
Original PNGs remain bundled references. Every control shows its function at once in a
one-line Liquid Glass pill beside the remote (left-column controls on the left, right-column
on the right) with an arrow toward its button; `RemotePillLayout` pushes a pill off its row
only as far as needed to clear its neighbour, and the arrow still aims at the button.
Hovering a pill highlights its CAD button blue (`RemoteModelView.highlighted`), together with the unnamed CAD solids lying on its face (`highlightParts`: each belongs to the smallest named control containing it; dark pieces turn blue, light symbol strokes white — the aluminum symbols are separate solids and stayed unlit until 2026-11-13) and hovering
the button highlights the pill; pills fade out while the remote is dragged. Clicking an
editable pill pops up a native `NSMenu` of `RemoteSettingsGuide.pillOptions` (current one
checked, default marked); fixed-role pills show no chevron and do nothing on click.
Preserve and restore original materials without tinting shared materials on other parts.
Split the volume rocker into upper/lower regions. Do not display the remote generation as a
visible heading; keep connection state and battery.

Opening Settings switches the app's activation policy to `.regular` so its Dock icon
appears. Closing the window restores `.accessory`; minimizing keeps the Dock icon so
the user can restore the window. Keep `LSUIElement` for menu-bar-only launch.

Settings follows Spotter's Settings layout (System Settings style, rebuilt 2026-11-04 at the
user's request): a fixed 720 x 550 window, transparent title bar with hidden title and no
toolbar, a 190-point sidebar (`.sidebar` material, 1 pt separator, icon-tile rows, grouped
headers Remote / Features / VibeRemote) and grouped-`Form` panes with a bold title whose
first section header is stripped (`SettingsPane`, `SettingsRow` in `SettingsPanes.swift`).
Keep metrics in `SettingsMetrics` aligned with Spotter's `Theme` rather than inventing new ones.

The first menu row is the complete device summary. While connected, it shows `Connected`
and the remote's own Bluetooth name on the left, plus a green circular battery gauge with the
numeric percentage centered on the right. The name comes from `RemoteGeneration.primaryName`,
which reads the HID product string of the same physical remote `primary` picks — that string
is the Bluetooth name, including a user rename, and needs no IOBluetooth call. A charging-only
remote, a remote whose interfaces disagree, and a blank product string all leave it nil, which
falls back to the hardware family. While the remote is connected and its always-on bridge is
still coming up, replace `Connected` with `Starting`; the menu-bar remote glyph uses a refresh
badge during the same interval. While disconnected, the row shows only `Disconnected`. There
is no separate stopped-bridge banner and no pause badge. Do not repeat Bluetooth, generation,
or battery as separate rows below this summary.

The menu bar's **Settings…** entry opens one retained window, even with the remote
disconnected (frame autosave `VibeRemote.Settings.Compact`). Panes (split and renamed 2026-11-11 at the user's request; the `.remote` raw value is kept for
saved state): **Controls** (`SettingsTab.remote`: everything about what the buttons and touch
surface do — the profile switcher as a Liquid Glass capsule in the window's top-right corner beside
the Fix pill, with app icons and none for General — macOS 27 does not draw `NSMenuItem.image` in this pop-up menu, so each item's icon is a text attachment in its `attributedTitle` (`ProfilePicker.menuTitle`), with an invisible 16 pt spacer for General so names share one edge, verified by screenshot 2026-11-11; the CAD remote with a clickable glass pill per
button; Restore Defaults for the edited profile's button choices only, inside the remote's card at its
bottom-right (no explanation text under the card, 2026-11-11); then the text-cursor guide,
formerly its own Text Cursor pane: the onboarding `CursorDemo` loop and start/move/confirm/cancel
steps that name the family's own parts — touch surface versus clickpad, and no Power key on the
1st-gen remote), **Device** (the physical remote: an untitled status group in the user's left/right layout
(2026-11-11; no "Status" header and Auto Disconnect moved below it as its own untitled group with its
footer, 2026-11-12): Bluetooth → the remote's name (or
Disconnected) with a green/gray light on the right, Battery → plain percentage (connected only, no ring),
Vibe Remote Daemon → Running/Stopped (the voice bridge), and a Restart Daemon / Start Daemon button pinned
to the pane's bottom-right corner (an overlay, not the section footer); Helper and Audio Driver rows appear only while
`SettingsDiagnostics.setupIssues` names them, using the same rules as the status-menu
banners and onboarding — helper not approved, or no supported output device at all. The status
group has no Output Device row; last comes **Diagnostics**, moved from About on 2026-11-13 at the
user's request: fields from the async `MicrophoneBridgeDiagnostics` (Output Device among them), Helper,
the app log, Refresh and Copy Diagnostics, then Blocking Issues when there are any. Its Needs Attention
section was dropped there because the Vibe Remote Daemon row already shows that text as its subtitle;
the pane's Form has extra bottom scroll margin so the last buttons clear the pinned Restart Daemon), **Computer Use**
(an `AgentDemo` illustration in System Settings' shape — abstract input on the left, what
it produces on the right: the Computer Use button (aluminum Play/Pause; none drawn on glass) on the blueprint remote, then the instruction typing
into the Computer Use callout and the pointer pressing a control in the front window — then backend,
per-backend model, OpenRouter key; same defaults/Keychain as the callout,
which reloads them on open) and **About**
(version, Check for Updates, Getting Started, links; it held Diagnostics from 2026-11-11 until they
moved to Device on 2026-11-13). About is pinned alone to the bottom of the sidebar (user confirmed
the layout on 2026-11-11). Software Update lives in
About; the sidebar's About row shows a dot only while Sparkle has a valid update session.
Automatic checks are always enabled at updater startup, including for previously opted-out
installs; do not expose an opt-out checkbox. No mode selector or pointer/scroll sliders.
`SiriActionPopUp` (an `NSPopUpButton`, per-item tooltips, rebuilt only when the choice
changes) remains for onboarding's Siri page only. Window state comes from
`MenuBarManager` and must not create a second HID/Bluetooth manager. The exact Figma artwork is a SwiftPM
resource; `build.sh` stages its bundle and `create_app_bundle.sh` embeds it in
`Contents/Resources`, which `SettingsAssets` resolves before the CLI `Bundle.module` fallback.

Current intent: clickpad arrows → arrow keys, old touch-surface click → Enter, aluminum center → confirm active caret (otherwise reserved), Back/Menu →
word-wise Backspace (Option+Delete — macOS `deleteWordBackward:`, whose tokenizer also
segments Chinese words; repeat runs at a slower word cadence than character repeat),
TV → Shift+Enter (newline, the convention agent apps use), Play/Pause → toggle
the Codex/Claude desktop client to the front, Power → Enter, volume keys → bullet-list
control, Siri → held Space, Mute → tap types the focused app's skill-picker trigger
(`$` in `com.openai.codex`, also locally named ChatGPT.app; `/` in Claude and other apps).
Resolve focus on release, and preserve the legacy `slashOrModifier` raw value for saved
Siri assignments. Held, it is a modifier: Mute+Back clears all input (Cmd+A, Backspace) and
Mute+Play/Pause sends Esc (stop the current task).

**The remote reports one press and one release with no repeats in between.** Key repeat is
therefore synthesized in `RemoteInputHandler`:

- `beginRepeating` drives auto-repeat (Backspace, arrows) with a safety tick cap in case a
  release event is ever dropped.
- Back/Menu always deletes one word immediately per press; holds repeat. Do not
  recognize a double-click: rapid repeated presses must never clear the input.
  Advanced Menu retains its explicit clear-input action.
- Volume keys share one smart-list path across both remote generations. On button-down,
  they schedule one action after a short delay; do not dispatch Cmd+Shift+8 synchronously
  from the volume release callback because Codex drops it. `ListEditingController` reads
  the focused editor's value, selection, caret hierarchy and attributed list markers.
  Volume-up creates a list from a paragraph or indents a list item; volume-down outdents a
  list item (the editor removes the list at its outer edge). It invokes the editor's native
  Cmd+Shift+8 / Tab / Shift+Tab commands so text, formatting, selection and undo remain
  editor-owned. It never rewrites the AX value or keeps remembered list state. This is not
  Codex-only: the structure comes from generic AX roles and list attributes, and the single
  remaining gate is `acceptsListCommands`, which requires a focused AXTextArea/AXTextField/
  AXComboBox because Tab moves focus rather than indenting anywhere else. The Codex bundle-id
  gate was removed on 2026-11-06 — do not reintroduce an app allowlist. Composing
  text, multi-paragraph selections, code blocks, unsupported editors, timeouts and ambiguous
  AX results use a bounded per-focused-editor fallback because many editors (Codex's
  ProseMirror, Electron apps generally) flatten that structure: the first volume-up creates a list, subsequent volume-up taps
  indent it, and volume-down walks out/removes it. This fallback exists to keep short press
  functional. A tap and a hold both fire exactly once; long press must never be required
  for normal list use.
- Tap-or-long-press actions (`beginTapOrLongPress`) and the TV hold that opened Computer Use
  were removed on 2026-11-13: only Siri responds to a hold.
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

- The verified capture paths depend on a physical Siri-button hold. No software-only
  microphone start/stop command has been demonstrated for the first-generation remote.
  Do not build features that assume one exists. This is an operational constraint,
  not proof that the firmware has no undocumented command. Research and cross-machine
  handoff are indexed in `Design/Research/README.md`; the evidence report is
  `Design/Research/FirstGenerationMicrophoneControl.md`. On 2026-10-13, Feature E1
  read LOCK=1 on the tested 026D/0A00/v0118 unit; do not assume another unit shares
  this value or that another firmware shares these offsets. Internal unlock and
  relock paths exist statically, but host access and reliable recovery are unproven.
  Current research scope excludes actual unlocking, persistent writes, firmware
  flashing and mapping changes. The diagnostic script defaults to read-only;
  its optional zero-duration write was a bounded prior experiment, not permission
  to repeat it on a different remote. Keep physical Siri capture intact on both
  generations.
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
- The black-glass remote's voice lag is a link limit, measured 2026-10-31: it records
  50 frames/s, but each 104-byte frame needs four 27-byte LE packets and the Mac controller
  gives it one frame per 22.5 ms connection event (44.4 frames/s). It queues ~1 s, then
  drops one frame in ~9, and keeps recording ~1 s after release, so ~2 s flushed after
  release. CoreBluetooth's private `setDesiredConnectionLatency:forPeripheral:` reaches
  bluetoothd, but level 0 asks 10–30 ms (controller keeps 22.5 ms) and level 1 moves the
  remote to 112.5 ms; `IOBluetoothHostController` HCI calls return 0 without sending
  anything. Do not retry these as a fix. The first frame sent after release carries state
  byte 0x00 instead of 0x10, and sequence numbers count recorded 20 ms frames, so the parser
  ends the session at the frame recorded at release + 0.3 s and drops the rest. The mapped
  dictation key stays held through that end and output drain.
  `voice-ended` reports protocol end; `voice-drained` reports output completion, tagged
  with the hold's start time. A 4-second old / 3-second new remote safety deadline prevents
  stuck keys. Stale completions must not release a later Siri hold.
- Audio format: Opus CELT-only, 48 kHz mono, 960 samples/frame, 99-byte HID
  payload, enable byte `0xAF`, report ID `0xFA`. Cross-checked against
  https://github.com/azais-corentin/siri-remote.

### Single input configuration

The bridge stays available alongside fixed buttons. There is no Touch/Audio switch,
mouse mapping or scroll mapping. RemoteCaretController consumes source-filtered touch
coordinates from passive PacketLogger while the existing HID/GATT ownership is preserved.
Media source correlation remains necessary: the remote's NX events lack source metadata.
Capture-file notifications feed a serial background reader/parser; idle capture uses a
one-second fallback instead of a 50 Hz main-thread poll. Missing or denied files retry
at 100 ms. Preserve ordered reset/button/touch delivery through the bounded mailbox.
The NX 160 ms resolution calls `pollNow()` as an explicit serial flush before matching;
ordinary delivery must not block the main thread on file I/O. Keep inode/truncation,
partial-line, replay and stop/restart behavior covered by the capture tests.
Do not restore the failed private HID monitor. Preserve the 180 ms correlation window,
160 ms NX wait, original CGEvent timestamps, bounded replay rejection and reader reopen
retry. Aluminum mute/play/volume edges have one passive owner. Unmatched keyboard media
keys must still pass through. Black-glass ATT 0023 is shared by touch and voice: decode
only 13/20-byte reports whose marker byte is 0x32 as touch. Voice data is never a button
or touch mask.

The glass remote's Play/Pause opener also emits a native NX media key. Record both
HID edges, with IOHIDValue's original timestamp, before menu/AX/bridge callbacks and
connection quarantine. Its NX events use the same 160 ms deferred source matching as
aluminum (180 ms correlation bound); a post-action `lastProcessedButton` marker alone
can be set too late and let opening Advanced Menu start music. Keep aluminum passive
ownership unchanged, deduplicate HID mirrors, and forward unmatched keyboard keys once.
Black-glass hardware verification on 2026-10-09: repeated menu opens/closes produced
`consumed=true` on both NX edges, with 0.1–0.2 ms HID/NX timestamp deltas; the user
confirmed music no longer starts. This run did not physically retest aluminum remotes.

PacketLogger's capture clock can lead app wall time: this Mac was measured at 80–93 ms
ahead even on newly appended records. Touch parsing therefore allows up to 180 ms of
future clock skew as well as the existing 180 ms stale cutoff. Do not restore the former
30 ms future bound; it drops valid touch reports before either gesture recognizer runs.
Preserve original capture times so multiple frames delivered together retain their gesture
intervals. This tolerance does not change NX media-key correlation or audio parsing.

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

Capture-only restarts preserve the current system input and its saved original device.
Do not restore the previous microphone between stop/start: it may be a Bluetooth headset
and cause a temporary voice-profile switch. Restore on explicit stop/quit or failed restart.
Skip CoreAudio default-input writes when that device is already selected.

Reject non-ATT ACL records from their bounded eight-byte header before decoding the full
payload. Continuations are eligible only for a pending ATT handle; a new packet on that
handle clears old reassembly, including non-ATT packets. Read the voice-suppression file
fresh for actual voice events, not for unrelated Bluetooth records. Keep session cancellation
sticky through the tail. Button/touch readers reject impossible sizes before date conversion.
These reduce background work; they do not establish that Bluetooth headphone stutter is fixed.

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
  This is why caret positioning uses passive PacketLogger instead. Previously verified: stopping the app yields 447 touch
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
and use the same-cycle cache for multiple input clients. The shared-memory HAL is the only
route; the Settings Output picker and its `audioOutputBackend` default were removed on
2026-11-06 and nothing reads that key. An old driver/helper or a missing mapping still
retains the previous AVAudioEngine route automatically, because those installs cannot
carry the shared ring — keep that capability check and its fallback.
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

### Advanced Menu

The physical bottom-left button now opens a nonactivating glass panel beside the text caret:
Mute for aluminum, Play/Pause for glass remotes. This explicit product change overrides
that button's prior Skill/modifier or optional mode-switch assignment. Back = clear input,
Old-remote TV = Skill; aluminum TV is inactive in this menu after Skill moved to
ordinary Play/Pause. Aluminum menu Play/Pause = Stop current task, Power = Cmd+Enter.
Both generations share volume up = Redo (Cmd+Shift+Z), volume down = Undo (Cmd+Z)
while Advanced Menu owns the input; ordinary volume-key list editing must not run then.
Use arrow.uturn.forward and arrow.uturn.backward for Redo and Undo.
Both layouts share the middle-left Stop current task slot (`stop.fill`): Siri on glass,
Play/Pause on aluminum. Both execute one Esc immediately on press and consume the release.
Both generations' Siri key sends one unmodified Esc on down while Advanced Menu owns
the input; consume repeats and release even after dismissal. Outside the menu it retains
the saved Siri mapping. Directions/center remain excluded. Preserve focused-app identity, consume
paired releases on cancellation, and perform only one action per presentation.

Block voice output before opening Advanced Menu and retain suppression through a consumed
Siri hold and its release tail; only the next ordinary Siri down restores voice. Combine
menu and caret suppression with OR so cancelling one cannot unmute the other. Firmware may
still transmit microphone packets; the voice helper's existing session gate discards them.
Aluminum capture-owned opener edges and HID Siri edges must share the same physical device
key. Resolve only an unambiguous Bluetooth label among that generation's open interfaces;
never attribute one remote's Siri press to another remote's menu.

PacketLogger now parses the six aluminum auxiliary bits (TV 0, volume 1/2, Back 6, Mute 7,
Play 8). Raw capture owns dispatch; NX correlation only suppresses matched media events,
never executes the action a second time. HID mirrors of these six keys are ignored only
while the passive path is active. Normal actions share RemoteInputHandler's existing
connection gate and repeat logic. Capture loss cancels auxiliary repeats. Do not intercept
all system media keys without a matching fresh capture. The old/direct-HID path uses the
same advanced-menu model via its physical-button callback.

Advanced Menu editing actions synthesize Command+Shift+Z (Redo), Command+Z (Undo),
Escape (Stop current task), and Command+Return (Power) in the preserved foreground app. Never inspect clipboard content
or rewrite AXValue for these actions. Skill
directly types the focused client's trigger without an AX role gate. Only clear-input
requires an editable AX role. Read the current focused editor's AX selected range and
AXBoundsForRange, with text-marker bounds for web editors; prefer text caret geometry. AX reads run off the event-tap thread with bounded timeouts and stale
presentation/focus checks. Convert global AX top-left coordinates using the primary
display's top edge, including for secondary displays. Prefer above the caret with the
visible lower-left corner beside it, fall below near the screen top, and clamp on the caret's display. If caret bounds are unavailable,
fall back to the mouse location captured when opening was requested. NSEvent mouse
coordinates are already AppKit screen coordinates; do not flip them as AX coordinates.
Use the selected anchor for placement, entry and exit, including on secondary displays. The menu enters from 20% scale with a lightly underdamped (ratio 0.8)
scale/position group anchored at the actual screen-space caret, plus opacity. Its total
entrance runs 1.1x faster than the original mass 1 / stiffness 500 / damping 45 spring;
normalize group speed to include the small rebound in that time budget.
Convert screen -> window -> view -> layer -> superlayer. Animate position in the parent
coordinate system separately from local scale: a local translation in a transform has
the wrong Y direction when the layer and its parent differ in flipping. The caret stays
fixed even after screen-edge placement flips/clamps. Hide the window until animations
are installed to avoid a full-size first frame. The animated content must be a child of
a stationary layer-backed host: AppKit's window root layer has no superlayer.
Dismissal reverses toward the opening's saved caret position over 200 ms while fading.
Read the presentation layer before interrupting entry so early release cannot jump to
full size. Clear input ownership and disable window hit testing immediately; action
dispatch never waits for the exit. Cleanup owns only the departing window, and reopening
cancels/removes that window so an old completion cannot hide the new menu. Reduce Motion
uses only a 120 ms fade.
Reduce Motion uses opacity only. Flipped label/shadow
views use positive Y offsets for downward shadows, with window padding for the blur.
The Advanced Menu is icon-only (including no hover tooltips), retaining accessibility
labels. The lower-left close glyph is `xmark` at 55% opacity. Use full-opacity native
Regular interactive glass for background blur, with accessible buttons and glyphs in
its contentView. Lowering the glass group's alpha mixes sharp background detail back
through the blur. AppKit owns Reduce Transparency / Increase Contrast material variants.
Use one composite silhouette shadow for all
buttons. Its compact window and caret placement share contentPadding/menuSize so removing
labels never leaves an invisible label-sized positioning margin.
Buttons have an 8 pt gap (36 pt diameter, 44 pt center spacing). Draw the shadow in a
separate foreground sibling of the glass container, with zero alpha inside every glass
button and only one device pixel of antialiasing at its boundary. Do not feather the mask
outside the buttons: that creates a bright moat which looks like an outer glow. The
shadow should meet the lower edge and fade outward. Drawing a filled shadow underneath clear glass
tints its backdrop gray. An empty layer shadowPath inside the container did not produce
a visible shadow. Keep the shadow and glass in the same animated root.
Keep NSPanel.hasShadow false: a second WindowServer shadow can outline the custom
shadow's translucent silhouette. Draw only the blurred shadow from an offscreen caster,
without an aliased cutout or any opaque shape in the visible window. Match shadow
offset/blur to the bitmap's backing scale; verify clear interiors and downward falloff.
The opener shows the menu on down and every release latches it, however long the press
(2026-11-13, user's request; a release after 250 ms used to close it). While the opener is
still down, actions execute on down, then all remaining releases
and subsequent auxiliary clicks while that physical opener stays down are consumed.
Keep each suppressed click owned through its release, even if the opener releases first;
never let a hidden menu turn a second Redo press into baseline Indent. Other devices and
excluded keys remain independent; capture reset clears the held chord. Same-report Mute downs precede action edges and
Mute ups follow them. Settings Mute/Power (and the old remote's Advanced Menu opener)
remain visible but disabled, with no popup arrow or interactive glass response.
VolumeRevertGuard also tracks the output mute property: confirmed remote Mute holds
restore the pre-press state, including its short release tail. Never force unmute or
blanket-consume unrelated keyboard mute events. NX mismatch diagnostics include the
nearest captured edge's time delta for physical verification.

### PacketLogger button reader startup race

The root supervisor creates `packets.log` before chown/chmod. File attributes can be
read while opening the file is still denied. `PacketLoggerButtonMonitor` must retry
a missing reader on every poll, even if the observed inode and size do not change.
Do not gate reopening solely on inode/truncation: doing so leaves all passive-owned
buttons dead until another capture restart. A regression test covers the same-inode
permission handoff. Preserve source filtering and the bounded NX correlation window.

### Function guide and settings ownership

Settings callouts show function text only, never a second line repeating physical button
names. RemoteSettingsLayout selects the physical generation. Center = caret positioning;
aluminum touch = slide to position caret. There is no mouse/touch mode guide.

Sidebar: the Remote group (Controls, Device, Dictation, Computer Use) from the top, and About
(`appTabs`) pinned to the bottom; `remoteTabs + appTabs` must stay equal to `allCases`.
While any setup issue exists, every pane shows a Liquid Glass capsule in the window's top-right
corner (red `exclamationmark.triangle.fill`, "Fix Helper", "Fix Audio Driver" or "Fix Setup")
whose popover is the step-by-step guide with the same actions as the rows. Settings refreshes
diagnostics when its window becomes key, so approving the helper in System Settings clears it.

The status menu has no Mode, Audio Output, Auto Disconnect or Debug submenu. All
configuration lives in Settings; the audio driver install lives in the Device pane's
Status section (and the Fix guide) and diagnostics at the end of the Device pane.
Keep live status, Settings and Quit, plus actionable permission/setup
errors when applicable. Row order below the status summary is Settings…, Check for Updates,
Computer Use, Restart Onboarding, then a separator and Quit. Advanced Menu is opened from the remote only; do not expose
another entry in the status menu or Settings' application menu. `MenuBarManager.publishDiagnostics`
feeds both panes on every menu rebuild and diagnostics refresh, including while disconnected.


### Text caret positioning

RemoteCaretController replaces the removed swipe-delete experiment. Aluminum FC reports
(ATT 003D, marker 32, 11/18-byte payloads) supply signed 12-bit coordinates while HID stays
open. Hover bit 1 is a lift edge. Protocol reference is linked in the decoder.
Both generations enter when one contact accumulates 1000 normalized raw units of travel,
independent of direction or speed. RemoteCaretTravelGate samples path segments after
12 raw units of displacement from an anchor, so slow intentional motion accumulates
but small back-and-forth jitter does not. Lift before entry, multiple contacts, a new
source/generation, out-of-order frames, gaps over 250 ms and jumps of 700 units or more
on either axis reset pending recognition. No direction-reversal or overall time limit.
No focused writable AX text element/caret geometry means no overlay or Enter fallback.
Preview only changes a nonactivating, mouse-transparent clipped overlay; AX selection is
written once on a center click or 3-second idle confirmation. Snapshot text, selection,
focus and geometry must remain unchanged.
Siri/Power/keyboard Return cancel and consume their complete press; Return repeats must
not submit. Voice suppression is a separate private gate, not an interaction mode. The
helper suppresses a whole cancelled voice session; the next ordinary Siri hold re-enables.
Single-contact touch-down shows a symbol-free preparation bubble (65% scale, growing
to 78% with accumulated travel) and an opaque stem at the calibrated insertion point.
Only the bubble rotates around its stem junction, following bounded horizontal displacement
and velocity. Retarget springs continuously; threshold entry inherits the live motion,
grows to full size with a small overshoot and fades in the movement symbol. Never move
the stem with decorative sway. Overlap the balloon neck into the stem by 1.5 pt and
composite both before applying their shared shadow, so antialiasing and shadow never
create a seam at the junction. Reduce Motion disables sway and spring scaling.
Preparation makes one AX acquisition attempt per contact, validates focus/text/geometry
on the watchdog, and retracts on lift or stale contact. It is not active positioning:
no selection writes, voice suppression, or confirmation/Return interception. Keep
direction-independent cumulative travel and post-entry lift persistence unchanged.

Repeated tracking/watchdog AX reads run on one serial worker with one in-flight request
and only the latest pending request. Main and worker have separate mutable marker caches.
Cancellation, lift settlement and confirmation invalidate late replies; session cleanup
must clear worker caches in queue order without waiting on the main thread. Apply valid
geometry to the current aim, never the older requested point. Entry, lift and final commit
retain synchronous fresh focus/text/selection/geometry checks and selection writes remain
main-owned. Do not turn this optimization into unvalidated asynchronous commits.
The caret stays 2 pt wide at the editor's
line height; a 24 pt bubble with the four-way SF Symbol grows from its top. The exact
Figma silhouette (1345:6560) is in Resources/CaretBubble.svg; CaretBubble.png is its
top 32 pt exported at 4x, joining the variable-height native stem. The decorative
bubble may overhang the editor, but insertion targets remain inside it. Horizontal
sliding displays a continuous preview; vertical movement snaps to calibrated text rows.
Choose the row by Y before choosing its nearest character by X, so short lines cannot
jump sideways into a longer adjacent line. Change row only after crossing 65% of actual
row spacing; reverse travel must cross the opposite threshold. Keep the displayed Y on
that row, including on lift/confirm. Never clamp its calibrated Y into a line gap.
Horizontal gain remains 0.07 screen points per raw unit; vertical output is multiplied
by 0.65. Lift snaps X to a grapheme boundary. A 1.25 pt spatial
dead band accumulates intentional slow motion while rejecting finger jitter; the 100 ms
post-click release interval establishes a fresh touch baseline. Decoration never
offsets/clamps its anchor. Tracking position is immediate,
while appearance/disappearance remain animated, so commit matches the displayed target.
Dismissal reverses the growth around the same stem junction: keep opacity at one while
the bubble shrinks, then fade the stem only below 20% bubble scale. Retarget live spring
values if a new touch interrupts dismissal. Reduce Motion uses a simple fade.
Recheck target geometry before committing to reject stale scroll/reflow positions. Geometry, raw center thresholds, movement
direction and target-app AX writes still require physical verification. Do not claim
hardware haptics. No mouse movement, scrolling, deletion, clipboard use or generic Undo.

The recognized frame remains the motion baseline, so the same contact moves the preview
immediately after entry. Lift settles only the preview and resets the contact baseline;
it never writes the selection or ends the mode. Users may lift/reposition repeatedly.
A center click (both generations) commits once, then dismisses. Full positioning also
commits after 3 seconds without accepted movement, using a monotonic deadline and the
same settle/editor/geometry validation as a click. Start on entry, renew only on accepted
motion, clear on cancellation, and consume expiry once. Stationary reports, lifts and
preparation never renew/start this deadline. If the finger is still touching at expiry,
consume that source's touch frames until lift so preparation cannot immediately reappear.
CaretButtonGate consumes
its repeats and release after mode exit so an old-remote confirmation cannot submit Enter.
Outside positioning the old surface click remains Enter; aluminum center remains reserved.
After confirmation, ignore touch while the click is held and for 100 ms after release.
The black-glass lift edge keeps byte 0 at one while ellipse/pressure bytes 9...11 zero;
decodeGlass must use those three bytes, not advertised finger count.

Caret geometry must be calibrated against nonempty glyph ranges. On macOS 27 the
native NSTextView collapsed AX range reports a rectangle one line above
firstRect(forCharacterRange:), while nonempty character ranges are correct. Detect
that convention per editor; never blindly add a line to providers already returning
correct rectangles. With no usable glyph geometry (including empty text), do not
show a guessed caret. The native fixture compares multiple rows against text-input
geometry, independently of the AX zero-length range.

The overlay uses a small borderless panel positioned directly from the calibrated
AX rectangle, with an ordinary unflipped NSView drawing the stem at y=2 and the bubble
above it. Do not reintroduce nested backing-layer coordinate/anchor conversions.
Entry/commit diagnostics log geometry deltas only, never editor text. Animated
appearance never moves the stem and tracking remains immediate.

Rebuild the staged SwiftPM resource bundle from scratch, never merge flat native
and Contents/Resources Xcode layouts. NSBundle can otherwise resolve stale resources
and silently miss newly added assets. Validate CaretBubble decoding against the
actual signed app with VIBEREMOTE_VERIFY_APP, not just the SwiftPM test bundle.

Web editors may omit AXBoundsForRange even with a writable selection and nonempty
AXValue. Fall back to text-marker bounds using an editor range whose text exactly
matches that focused editor. Never treat AXTextMarkerForIndex as an editor-local
index: Chromium can interpret it against the document root. Walk opaque markers
from verified start/end/current-selection anchors, validate each UTF-16 segment
against the editor snapshot, and bound traversal. Cache only within that editor
and positioning session. Keep glyph calibration for both geometry sources.
Codex can return the entire editor rectangle for a collapsed container-anchored
marker (observed 713 x 44 instead of a 0 x 18 caret). Reject insertion rectangles
wider than 3 points. Container-marker round trips alone do not fix this: entry from
the real end selection works while reaching that same end from another offset fails.
Seed markers from AXStaticText descendants of the focused editor, using each leaf's
own AXTextMarkerRangeForUIElement. Its prefix + content + suffix must exactly equal
the editor snapshot, and each seeded anchor must have valid collapsed geometry.
Bound that traversal to 96 nodes / depth 10 / 120 ms and never search another editor.
Preserve a valid real-selection anchor when a leaf is unusable. As a fallback,
re-anchor by stepping into neighboring text and back, verifying
both traversed strings against the same UTF-16 segment; cache only after the replacement
returns valid insertion geometry. Normalize container endpoints for calibration ranges
too. Never guess end/start X from glyph width or assume LTR. Sample offsets 0 and text
length first and retry failed endpoint probes at most twice after other samples.
Entry failure diagnostics are limited to recognized travel gestures and contain only
capabilities and geometry, never editor strings or marker payloads.

Caret lift only settles the preview. Center/surface click or 3-second idle expiry commits for both generations.
Clear drag and travel-recognition state on cancellation.

Direction buttons emit ordinary arrows again, including repeat: they navigate Codex Skill
pickers and may move the real text caret. Do not restore AX popup/class-based gating.
On aluminum direction-button down, cancel caret preparation/positioning without consuming
the arrow. CaretNavigationTouchGate owns that physical contact until lift, including the
button-held interval and delayed touch reports after release. Ordinary cancel/keyboard
callbacks must not clear this contact ownership; source reset/disconnect does. Other
remote generations and distinct known touch senders keep their gesture behavior. A new
contact after lift restores the existing preparation and cumulative-travel entry.

After main synchronization, preserve the 1000-unit cumulative-travel gesture, animated
preparation, center-click / idle confirmation and verified text-leaf caret endpoints.
The upstream glass-only quick one-way swipe sends one arrow on lift only outside
full caret mode. Entering full mode resets the swipe recognizer; its lift must never
also send an arrow. Mechanical surface clicks block touch while held and for 160 ms
after release, without replacing active center-click confirmation with Enter.

### Command assistant removal (2026-10-29)

The command assistant and computer-use integration have been removed at the user's
request: no command panel, backend settings, MCP proxy, Jev worker, preview or Siri
tap gate. (A new agent-desktop based agent replaced it on 2026-11-01; see below.) Ordinary Siri presses directly use their configured mapping; keep the
existing Advanced Menu/caret ownership and microphone tail/drain handling.
Historical benchmark reports are evidence only, not supported runtime features.

### Per-app button profiles (2026-11-10)

At the user's request (modeled on Logitech's app-specific profiles) Settings › Controls edits one
**profile** at a time, chosen from the glass profile switcher in the window's top-right corner. General is the fallback: an app
without a profile, and every button an app profile leaves alone, does what General says. An app
profile stores only the buttons the user changed for it (pill menu "Same as General (X)" goes back),
so later General edits still reach the rest. Siri is per profile too (nil follows General), which
makes Dictation per app; the Dictation pane lists the profiles whose Siri resolves to Dictation.
- Defaults: General, Claude (`com.anthropic.claudefordesktop`) and ChatGPT (`com.openai.codex`, the
  Codex app installed as ChatGPT.app). Seeds are empty since 2026-11-11: Play/Pause defaulted to Esc (Computer Use since 2026-11-13),
  so the old Claude/ChatGPT seeds that pinned `.slashSkill` "/" / `.dollarSkill` "$" on aluminum
  Play/Pause were retired, and `ButtonProfileStore.load` removes exactly those untouched seed values from
  saved profiles once (`buttonProfilesPlayPauseEscMigrated`), so a later deliberate Skill choice is kept.
  `.skillPicker`, `.slashSkill` and `.dollarSkill` remain pill choices; Advanced Menu's Skill is not
  profile-driven.
- Storage: General keeps `siriButtonAction` / `buttonActionOverrides` (no migration). App profiles
  live in `buttonProfiles`; its absence means never seeded, so removed seeds stay removed. Nothing is
  written until the first edit. Choices are validated on read as before.
- Dispatch: `MenuBarManager.getMapping(for:generation:pressed:)` resolves the frontmost app's
  bundle ID at the press and `ButtonProfileLatch` reuses that profile for the release, keyed by
  generation + button. Both callers (`processButton` and the passive-capture `.none` check) pass the
  edge. Never resolve the release fresh: Toggle Codex / Claude changes the frontmost app itself, and a
  held key released under another mapping would stick. Remapping still changes only what a button
  sends (Advanced Menu ownership, chords, guards and passive-capture ownership are untouched).
- Add App lists `.app` bundles in /Applications (and one vendor folder level), /Applications/Utilities,
  /System/Applications(/Utilities) and ~/Applications, deduplicated by bundle ID (~44 ms here).
  Restore Defaults restores the edited profile's button choices (an app profile returns to its seed);
  Auto Disconnect is on the Device pane and is not part of it. The user confirmed the Profile row, Add App and per-app buttons work
  on 2026-11-10.

### Computer-use agent (2026-11-01)

Rebuilt from scratch at the user's request on top of
[agent-desktop](https://github.com/vercel-labs/agent-desktop) (vendored v1.0.2 in
`Vendor/AgentDesktop/`, bundled to `Contents/Helpers/AgentDesktop/` and re-signed); none of
the removed command-assistant code was reused. `ComputerUseAgent.swift` holds settings,
prompts, stream parsers and `AgentRun`; `AgentPanel.swift` holds the callout controller,
its view and the `ComputerUseAgent` model; `AgentDock.swift` holds the Dock pieces.
- Name: the feature is **Computer Use** everywhere visible (Settings pane, TV callout,
  menu item, callout header). The `SettingsTab.agent` raw value stays for saved state.
- Dock callout (2026-11-08, first version): opening holds a regular activation policy so
  the menu-bar app gets a Dock icon (`DockPresence.computerUseHoldsDock` keeps
  `restoreAccessoryPolicy` from removing it). `AgentDockTile` recolors the icon through
  `NSDockTile` (macOS's live-tile API): blue while composing, green while a command runs, then
  the normal icon with a ✓/! badge. Recolor = screen a gradient squircle, masked by the icon's
  own alpha, over the icon. `DockIconLocator` reads VibeRemote's AXDockItem frame from the
  Dock's accessibility tree (no public API; matched by bundle URL) and waits for two equal
  reads 50 ms apart because a new icon slides in. `DockCalloutPlacement` (tested) points a
  glass `DockCalloutShape` arrow at the icon on bottom/left/right Docks; without a located
  icon it floats arrowless above the screen bottom. The callout is a borderless key-capable
  panel at `.popUpMenu` level whose field takes focus on open. The callout is **only the input
  bar** (user's request, 2026-11-08): field plus a circular Send button — no header, hint,
  step list, result card or pickers. Send (or Return/Select) runs the command and returns
  focus to the target app, but the callout **stays up** unfocused: the field becomes one
  status line (`ComputerUseAgent.status`, whichever came last of the agent's step or message)
  with a spinner and Stop in place of Send. On finish the same line shows the outcome with a
  ✓/! icon and the tile gets a ✓/! badge; 8 s later both go away unless the callout is key.
  While Computer Use holds the Dock icon, clicking it focuses the bar (a fresh field after a
  finish); otherwise reopen still shows Settings. Esc closes. A button set to Computer Use stops a running
  command, closes an open callout, or opens a fresh one. Backend and model live only in the
  Settings pane.
- Trigger: any button mapped to `.computerUse` (aluminum Play/Pause by default since 2026-11-13), which runs
  `onAgentRequested` on press. The TV hold (`AgentButtonGate`, ≥ 0.5 s) was removed the same day: only Siri responds to a
  hold. The glass remote has no default Computer Use button (its Play/Pause opens Advanced Menu); a pill can assign one.
  The menu-bar item does the same without a remote.
- Input: the user's own dictation app types into the focused callout (user's choice over
  built-in speech). Remote Select is consumed by the callout only while it is key.
  The callout must use `NSApp.activate(ignoringOtherApps: true)`: a remote press is no user
  event in this app, so cooperative `activate()` was refused and Typeless pasted into the
  previous app while typing after a click worked (2026-11-01). The log line
  "Computer Use callout shown key= icon= active=" records activation and the located icon.
- Backends (user's choice): Claude Code CLI (`--tools Bash --allowedTools
  Bash(agent-desktop:*)`, stream-json), Codex CLI (`exec --json`, must be
  `danger-full-access`: its seatbelt returns EPERM for agent-desktop), OpenRouter
  (in-process loop, one `agent_desktop` tool taking an argv array, skills embedded in the
  system prompt, key in Keychain). CLIs are found via the login shell PATH plus common
  folders, because a Finder launch has launchd's PATH.
- Speed: `AgentBriefing` puts the desktop and macOS guides plus a fresh
  `snapshot --app <front app> --skeleton -i --compact` (dropped above 24k chars, ~0.7 s)
  into every backend's prompt, so no turn is spent on `skills get` or the first snapshot;
  the rules also ask for `batch` when steps need no observation in between.
  Every CLI run passes low reasoning effort (`--effort low`, `-c model_reasoning_effort="low"`;
  the user's Codex config was "high"). OpenRouter gets no reasoning parameter, because
  asking for effort turns thinking on for models that default to off.
- Models: the panel's Model row is per backend (`agentClaudeModel`, `agentCodexModel`,
  `agentOpenRouterModel`; empty = the CLI's own default). Claude Code offers the aliases
  fable/opus/sonnet/haiku; Codex lists `visibility: "list"` models from
  `~/.codex/models_cache.json` (re-read when the panel opens); OpenRouter is free text with
  a suggestions menu. Codex's "Fast" service tier was left off because it costs more usage.
- Children inherit VibeRemote's TCC responsibility, so agent-desktop uses its
  Accessibility grant. Claude Code on this Mac reported "not logged in" from the sandboxed
  dev shell (2026-11-01); the panel surfaces that error. The user ran it end to end from the
  remote with Codex on 2026-11-01.

### VibeRemote Dictation (2026-11-08)

At the user's request VibeRemote can transcribe itself instead of holding a key for a third-party
dictation app. Siri's `vibeDictation` action (pill title "Dictation"; the Siri pill is the only switch —
Settings › Dictation has no on/off toggle since 2026-11-09, user's request, and only says
whether Siri uses it) begins `DictationController` on Siri down and ends it at the
exact moment a mapped dictation key would be released: `holdsDictation` routes it through the
same voice-tail/`voice-drained` wait and safety timeout, the first-generation tail continues the
same recording, and an aluminum re-press ends (and transcribes) the previous hold first. No key is
held. It is Siri-only; no other button's `choices` may include it.
- Capture: an in-app `AVAudioEngine` pinned (AUHAL current device) to the bridge's own virtual
  input, found by `supportedOutputDeviceNames`, running only from Siri down to drain + 150 ms.
  The voice helper and the shared-memory HAL are unchanged. Needs Microphone TCC,
  `NSMicrophoneUsageDescription` and the audio-input entitlement. Clips under 0.3 s are dropped;
  digital silence reports "No audio arrived" (bridge stopped).
- Engines take one finished 16 kHz mono clip (`DictationAudio`), no streaming: Apple
  `DictationTranscriber` (`.shortDictation`, asset downloaded on first use; Automatic uses the
  Mac's locale), WhisperKit 1.1.1 (only its `WhisperKit` product; models downloaded on demand to
  Application Support/VibeRemote/WhisperKit, folder remembered in defaults), OpenAI
  `/v1/audio/transcriptions` multipart WAV, and Seed ASR via Volcengine's synchronous flash
  endpoint (`volc.bigasr.auc_turbo`; `X-Api-Key`, or App ID + Access Token for old-console keys;
  outcome in the `X-Api-Status-Code` header, 20000003 = silence). Keys are bring-your-own,
  one Keychain item per service, never in defaults or logs.
- Output: one line (newlines collapsed so a composer cannot submit), typed as Unicode keyboard
  events in ≤20-UTF-16 chunks split on character boundaries — never the clipboard. Transcripts
  are never logged; the log records provider, durations and character count only.
- Indicator (2026-11-09, user's request): a hold is silent and types nothing until it ends, so
  `DictationIndicator` shows the caret cursor at the insertion point in orange for as long as
  the hold is recording or being transcribed. It is the same `CaretOverlay` silhouette as caret
  positioning in a second `CaretBubbleStyle` (`.dictation`: `systemOrange`, `mic.fill`), never a
  second kind of cursor; a Siri press cancels positioning, so the two are never both on screen.
  The style tints the bubble artwork and the canvas-drawn stem, and keys the artwork cache
  alongside the appearance. Geometry comes from one `CaretInsertionPoint` per indicator (it caches calibration and web
  text markers, which cost up to 120 ms to rebuild). Glyph-calibrated geometry wins. Unlike caret
  positioning, which must never guess because it moves text, the indicator only points: an
  empty editor (no glyphs to calibrate — the usual place to dictate, and the reason it first
  failed to appear on 2026-11-09) uses its collapsed-range rect if caret-shaped and inside the
  editor, else its leading edge (3 pt in). "Empty" means only line breaks with the caret at 0:
  Claude's ProseMirror composer reports an empty document as "\n", and Chromium answers every
  caret-rect query there with a zero rect at (0, y), so it always takes the leading-edge path.
  ChatGPT (com.openai.codex, Chromium-based) showed no cursor on 2026-11-10: the system-wide `AXFocusedApplication` query fails at once there (-25204, any timeout), so `CaretAXQuery.observe` falls back to `AXUIElementCreateApplication(frontmost pid)`. Its composer reports its placeholder as the value ("Work with Codex\n"), which once calibrated as glyphs at the field start; once it stopped calibrating, the bubble waited ~3 s for the first streamed words while Claude's showed at once, so since 2026-11-13 a caret at 0 in a value equal to `AXPlaceholderValue` is read as an empty editor (emptyEditor/editorStart) before any glyph measuring, and it drops an occasional query (40–120 ms or no value), so the indicator retries its first read up to four times 100 ms apart. The user confirmed the cursor in ChatGPT's input bar the same day. `VibeRemote --probe-caret` runs one read of the focused editor and logs `Caret entry:` steps (geometry only). The user confirmed the bubble in TextEdit (glyph) and Claude's empty composer (editorStart)
  on 2026-11-09; whether it follows streamed text in Claude has not been observed. Streamed words then move it to measured geometry. Web text markers are walked against a text snapshot, so `CaretAXQuery.caret` re-seeds them whenever the editor's text differs (dictation reads while it types; caret positioning never sees text change) — without that every read after the first streamed word failed and the bubble stayed put until release. `CaretInsertionPoint` reads on its own serial queue (one in flight, latest waiting) so marker walks never stall the typewriter on main, and each read starts 8 ms after the keystroke that asked for it (at most one per 16 ms). Chromium's AX tree lags the keystroke, so a reading whose caret offset (`Reading.offset`) differs from `DictationTypewriter.expectedCaret` (anchor + typed UTF-16) is behind: it is still drawn (offset and rectangle come from the same tree, so it is an older position, not a wrong one) and the next read follows 30 ms later, up to 10 times after the last keystroke. An empty read retries the same way: right after a keystroke Chromium's value and text markers can disagree, which fails calibration, and before empty reads retried, the last keystroke's failed read was final and the bubble never followed in Claude or ChatGPT (2026-11-10). Do not hold such readings back: the first version did, every keystroke restarted its wait, and the bubble froze while words streamed ("off after the first word", 2026-11-10). The per-hold log counts readings behind the typewriter and empty reads with the query's last step (`CaretAXQuery.lastStep`), and the first-read failure line names that step too. A text change first re-anchors through the already-verified provider (`refreshedMarkerGeometry`: same exact-text check, no ancestor walk or leaf seeding) and falls back to full seeding when that yields no insertion geometry or no calibration. The calibration fallback matters in Claude: markers cached while the composer was empty carry no leaf anchors, so after the first streamed word every read failed with `calibration unavailable` (32 of 37 reads, 2026-11-10) until calibration also re-seeded fully. Empty-read reasons now separate `caret unavailable` from `caret outside editor (dx dy)`. The indicator logs read count, mean and slowest read per hold. Chromium computes per-character text geometry only in full accessibility mode; without it every text range and leaf marker measures 0×0 (or the whole editor), so calibration never succeeds once text is typed. On 2026-11-10 ChatGPT calibrated until it restarted at 08:43 UTC and never after; nothing in VibeRemote had enabled the mode. `CaretInsertionPoint.requestFullAccessibility` sets `AXManualAccessibility` once per process where the app exposes it (Electron, i.e. Claude). ChatGPT's shell refuses both that and `AXEnhancedUserInterface` (-25208), so the indicator (only, never caret positioning) falls back to `.textEnd`: with the caret after the last visible character, the right edge of the last AXStaticText frame (frames stay correct), if that frame is one line tall (8–30 pt). Wrapped text gives no position and the bubble keeps its last one. In Claude the collapsed range at the end of the text also stops measuring once the text wraps onto a second line (2026-11-12, per-hold trace: the bubble stuck at the end of line 1), while nonempty glyph ranges still measure; so before `textEnd` the indicator (only) tries `afterGlyph`: the right edge of the character before the caret, on its own line, or the first glyph's left edge one line height lower per trailing line break. Caret positioning still never estimates X from a glyph. A read where the editor's text and its text markers disagree (Chromium, right after a keystroke) keeps the verified marker context and answers nothing; dropping it fell through to AXBoundsForRange, which Chromium does not answer, and an already calibrated editor never re-seeded, so one such read lost the bubble for the rest of a Claude hold and for good once the text wrapped (2026-11-13: 45 failed reads after a 98-character first line). Each hold's `Dictation indicator fallbacks:` line counts empty reads and `textEnd` readings by the reason the measured steps failed. Each hold logs `Dictation indicator reads:` — every change of line or accuracy with offset, length and line-break counts and the position relative to the editor, never text. `VibeRemote --probe-caret --all` prints the measured caret at every offset of the focused editor. Probed in ChatGPT: textEnd (523, 805) for its placeholder. A non-empty
  editor without usable geometry still gets no indicator. The log records which accuracy was used. It hides before the transcript is typed, because the caret
  moves as the words land. Seen on screen from a real aluminum-remote hold on 2026-11-09.
  Live states (same day, user's request): while recording, the bubble's glyph is a `mic` outline
  that `mic.fill` fills from the bottom with the recorder's per-tap RMS (`DictationLevelMeter`:
  -60...-6 dBFS, recalibrated from real holds that peaked at -7 dBFS, where -14 pinned ordinary
  speech at full; the floor moved from -45 on 2026-11-13 because whispered holds, peaking at -33 dBFS, barely filled it; fast attack / slow release; the fill is proportional from empty — filling the
  stand on any sound read as a jump and was dropped on 2026-11-10; the log's `floor` is each
  clip's quietest 50 ms, for placing the meter floor just above the bridge's noise), so a stopped bridge reads visibly empty. While the clip is transcribed a spinner (an arc fading from an opaque head to a clear tail, 2026-11-13)
  replaces the mic. `CaretGlyph` is drawn live by the canvas rather than baked into the cached
  artwork; nil keeps caret positioning's baked symbol. A 60 Hz glyph timer runs only while a
  glyph is shown and stops on hide. Only the current hold moves the indicator, so an aluminum
  re-press during transcription keeps its new listening mic. The completion log adds the clip's
  loudest 50 ms window in dBFS for calibrating that range.
- Seed ASR verified on hardware 2026-11-09: an aluminum-remote hold typed its transcript
  (3.0 s audio -> 29 characters in 1.57 s) against Volcengine's `volc.bigasr.auc_turbo`
  flash endpoint, so the request fields and the old-console `X-Api-App-Key` +
  `X-Api-Access-Key` pair are confirmed. That account's 极速版 resource must be activated
  separately from 豆包录音文件识别模型2.0, which is a different service.
- Hardware/network verification still outstanding: first-generation holds, the Apple,
  WhisperKit and OpenAI engines, Apple asset download and WhisperKit download/load time.

### Streaming dictation — flow output (2026-11-09, user's request)

Reference: Doubao IME 1.0.3 (`/Library/Input Methods/DoubaoIme.app`), read statically from its
binary's type names, method signatures and log formats; its `alog` logs are encrypted and were
not read. It streams Opus over a persistent WebSocket/QUIC link to a SAUC-family recognizer,
runs two-pass recognition (fast partials, then a re-recognized sentence), shows partials as IMK
**marked text**, and paces them with `ASRTypeWriter` / `TypewriterSpring`: keep the common
prefix, replace only the changed tail (`replaceLength`, `commonPrefixCount`), interval shrinking
with backlog, one skipped tick after a replace "in web env". Final text is IMK `insertText` or
synthetic Cmd+V with a clipboard snapshot/restore. VibeRemote is not an input method and cannot
set marked text in another app, so the user chose (2026-11-09) real keystrokes in the editor.

- Seed ASR only, Settings › Dictation › "Type While Speaking" (`dictationSeedStreaming`, default
  on). Other providers keep the one-shot path.
- Wire: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` (the optimized bidirectional
  mode, which only answers when the result changes). Headers are the flash API's old-console pair
  (`X-Api-App-Key` + `X-Api-Access-Key`) or new-console `X-Api-Key`, plus `X-Api-Resource-Id`
  `volc.bigasr.sauc.duration` (流式语音识别大模型 1.0 小时版, enabled on the user's `default` app
  7967928849 with the same Access Token; 2.0 would be `volc.seedasr.sauc.duration`) and
  `X-Api-Connect-Id`. Frames: 4-byte header, big-endian sizes, server responses carry a sequence;
  flags 0b0010 mark the last (negative) packet. `enable_nonstream` is **false** (2026-11-10, user's
  request): Doubao's second pass re-recognized every pause-ended sentence while the user was still speaking, so a
  long hold was rewritten several times before release. Refinement now happens once, after release, from the flash
  API with the recorded clip; `result_type: full`, 16 kHz s16le PCM in 200 ms packets,
  no compression (the server answers in the client's; gzip is still decoded defensively).
- `DictationTypewriter` is the only writer: partials, the final result and the flash fallback all
  set its target, and it reconciles the screen by common prefix. While Siri is held the target only grows
  (`DictationTypewriterPlan.growth`, 2026-11-10, user's request: deleting and retyping partials looked unstable,
  and the refined result replaces them after release anyway): it shows what two consecutive partials agree on,
  and after a revision of shown text it continues from where the shown text's end falls in the agreed text
  (`continuation`), matching only letters, digits and CJK characters, case-insensitively: its last six within 12 of
  their expected place (last such occurrence), else its last 12 where they occur exactly once (revisions add up: a fixed
  window stalled a 15 s hold at 114 of 276 characters on 2026-11-13, and the bubble stopped with it, since reads follow
  keystrokes); if the last word itself was revised, its earlier letters stand in (never skipping into an earlier word).
  Exact matching was the user's "stops after about six words": the recognizer adds commas to words already shown
  ("quickly and" → "quickly, and"), and the shown end was never found again; punctuation the screen already ends with
  is not typed twice. `--verify-seed-stream <file> --growth` replays a clip's partials through this rule (synthetic
  clips only: it prints the text). The user confirmed the fix on a real 17.7 s hold the same day. Only when nothing aligns does it pause until release. Every correction happens in `finish`, toward the refined text. The user confirmed on 2026-11-11
  that streaming now reads smooth and stable, with replacement only after release. Pace: one character per tick
  spread over ~0.18 s while nearly caught up (12–45 ms), more per tick as text backs up, ≤20
  UTF-16 units per key event; deletes up to 40 per tick then one settling tick. After release (2026-11-12, user's request: "deleting like a real human", settled 1.6–2.1 s after release for ~100 corrected characters) the correction is one step: after the same caret check, `AXSelectedTextRange` is set to exactly the tail being replaced (`replacementRange`: common-prefix end to the end of this hold's text, never before the anchor), confirmed by reading it back (Chromium applies it asynchronously; up to 8 checks 15 ms apart), then the refined text is typed over it in back-to-back ≤20-unit key events (an empty replacement is one Backspace). Unconfirmed selection restores the caret to the hold's end and Backspace takes over for the rest of the hold. The hold's log line says `by selection` or `by Backspace`. Only the selection is written, never AXValue. A later hold's
  typewriter waits for the previous one, so keystrokes never interleave.
- Corrections delete real characters, so they are guarded: focus (pid, then the AX focused
  element) is fixed at the hold's first edit and re-checked before every delete and at least every
  100 ms while typing; before deleting, the AX caret must sit exactly at anchor + typed UTF-16
  length (a lagging editor gets six 30 ms retries). After two retries the caret may be re-anchored
  (`DictationTypewriterPlan.reanchor`) if this hold's own text verifiably sits right before it: the value up
  to the caret ends with it, or the caret is at the end of the value (counting earlier line breaks or not)
  and the value ends with it. ChatGPT reported its caret 1–2 ahead of the count from the first keystroke
  (2026-11-13, text already in the box), so the post-release correction stopped with "the cursor moved"
  and the refined text never went in; the log line `Dictation re-anchored` records the offset only.
  Any failure stops typing for that hold and
  leaves what is on screen; nothing is ever deleted beyond what the hold typed. Unreadable
  selection or focus proceeds on the remaining checks.
- After release: drain grace, last packet, wait ≤4 s for the stream's final, then send the recorded clip once to
  the flash API and let the typewriter reconcile toward that refined answer (route `stream + refined`; a failed or
  empty refinement keeps the streamed text). If the stream itself failed or timed out, the same flash call is the
  fallback. The
  orange bubble follows the caret (stale-checked reads, see the indicator notes) while text streams, spins after
  release, and hides once the typewriter has settled. The log line records route, update count,
  time to first text, characters, corrected characters and settle time — never text.
- `VibeRemote --verify-seed-stream <audio file>` streams a file through the same session in real
  time using the installed app's own Keychain key (run the signed `/Applications` binary). On
  2026-11-09: synthetic English 6.4 s → 18 updates, first text 0.84 s after connect, final 0.61 s
  after the last packet; Mandarin 7.0 s → 17 updates, 0.67 s, 0.59 s, word-perfect. The one-shot
  flash path had taken 1.57 s for a 3 s hold.
- Hardware, 2026-11-09: the user confirmed text flows into the editor from a real aluminum hold
  (logged: 7.1 s audio, 4 updates, first text 6.46 s into the hold, 0 corrected, settled 0.51 s
  after release). Still unverified: first-generation holds, a long continuous utterance (that
  hold's first text came late, which may only mean speech started late), correction flicker,
  and the caret guard in web editors.

### Dictation dictionary (2026-11-11, user's request)

Settings › Dictation › Dictionary holds words dictation should get right, one word per row. Stored as
JSON in `dictationDictionary`, carried in `DictationSettings.dictionary`. An "often heard as" column
(misspellings rewritten to the word) was removed on 2026-11-12 at the user's request: it was hard to
know what to enter there. Old saved JSON with its `heardAs` key still decodes; do not bring the column
back without asking.
- **Case correction, every engine:** `DictationDictionary.apply` case-corrects each word,
  case-insensitively, longest first. Words starting or ending with a Latin letter/digit match as whole
  words with Latin-only boundaries (so "Codex" matches in "用Codex写" but not inside "Codexes"); CJK
  words match anywhere. Applied to every streamed partial (before the typewriter), the final/refined
  text and the one-shot path.
- **Seed hints:** hotwords go as `request.corpus.context`, a JSON *string* `{"hotwords":[{"word":…}]}`
  (Volcengine streaming ASR docs, 6561/1354869), punctuation stripped, budgeted to ~90 estimated tokens
  (docs: ~100 tokens for two-way streaming). Measured 2026-11-11 with a synthetic clip via
  `--verify-seed-stream <file> --hotwords a,b`: the flash refinement (`auc_turbo`, where the field is
  undocumented) consistently did better with hotwords: three runs each, without them it garbled all four
  rare names ("GestoDEX", "pros mirror", "Typeplus", "Viber mode"), with them it got ProseMirror exact and
  "Gestalt X"/"TypeLess" close (one earlier run was exact on all four; it did not repeat); the two-way
  stream with hotwords consistently drifted into Chinese ("open户型", "。") and got worse, three runs out
  of three. So hotwords go **only to the refinement after release**, never to the live stream
  (`--stream-hotwords` re-measures that).
- **OpenAI:** the words as the transcription `prompt` ("Vocabulary: …"). Apple and WhisperKit take no
  hints here; case correction still applies.
- The Language setting is not sent to Seed at all (it auto-detects Chinese/English/mixed speech).

### Filler removal and editor context (2026-11-12, user's request)

Prompted by Doubao IME's accuracy and filler handling. Two Seed rows in the Service group, both
default on: **Remove Filler Words** (`dictationSeedRemoveFillers`) and **Use Text Before the Cursor**
(`dictationSeedEditorContext`). Measured the same day with synthetic `say` clips through
`--verify-seed-stream` (`--no-ddc`, `--context "…"`, `--nostream` compare variants):
- **`enable_ddc` (语义顺滑)** goes on the stream and on the refinement. On the two-way stream it removes
  嗯/那个/um/uh and stutters ("我想我想", "and then and then") well; on the accurate model behind the
  refinement (flash `auc_turbo` and `bigmodel_nostream` gave identical text) it only drops 呃/uh. The
  refinement replaces the streamed text, so `DictationFillers.clean` runs on the final Seed text
  (`DictationController.finalText`: cleanup → dictionary → one line). It is deliberately narrow: 嗯/呃
  anywhere, 那个/就是/额 only as their own clause, Latin hesitations as whole words, and repeats only
  when they are stutters — 2+ Latin words, Latin function words (not "that that"/"is is"), CJK phrases
  starting with a pronoun/connective. Chinese reduplication (研究研究, 谢谢, 看看) must stay; tests pin
  the measured outputs and these keepers. Partials are not cleaned (the stream's own ddc already is).
- **Editor context:** at Siri down (or hotkey down) `DictationEditorContext.read` takes the frontmost
  app's focused text element off the main thread — never a secure field, only AXTextArea/TextField/
  ComboBox, not a value equal to its placeholder (ChatGPT) — and keeps the last 500 characters before
  the selection. It goes only to the refinement, as `corpus.context` with `context_type` "dialog_ctx"
  and one `context_data` text, combined in the same JSON string with the hotwords (accepted together).
  Docs allow 800 tokens / 20 entries, newest first. Result: "Type less" → "TypeLess", "Just Oled X …
  Cross Mirror" → "Gestalt X … ProseMirror", consistently. That text leaves the Mac with the audio,
  which is why it is a switch; the log records only its length and the filler switch.
- **Refinement via `bigmodel_nostream`** (same day, user's request): every Seed hold (streaming or not)
  opens a second WebSocket, `DictationRefinementStream`, to the streaming-input endpoint and feeds it the
  same samples during the hold. Its first request carries hotwords + editor context + ddc, so it starts
  once `DictationEditorContext.read(then:)` has answered; `SeedStreamingSession` holds earlier audio in
  `pending` until `start` (and a session cancelled before `start` never connects). On release its final
  is the refinement (`DictationController.accurateText`, route `stream + refined via nostream`); a failed,
  empty or 4 s-late answer falls back to flash with the same hints. Measured with synthetic clips: up to
  16 s nostream matched flash word for word and answered 0.5–1.4 s after the last packet, while flash
  took 1.2–19 s in the same runs. It serves every hold length: holds with 3–5 s thinking pauses
  (user's report: "a period appears even if I stop for a few seconds") showed flash ending a sentence
  at every pause over ~3 s ("I want is. A way to…", "我通常是 一边想"), on 15–27 s clips in both
  languages, while nostream punctuated by meaning ("我觉得我们应该把光标跟随的方式改一下，因为它在打字…").
  `vad_segment_duration` (documented 3000 ms sentence-split silence) changed nothing on stream, nostream
  or flash at 8/10/30 s, so it is not sent (verifier `--vad <ms>` re-measures). Known nostream limits
  past its 15 s window: one stray break per long clip (". Rather than", "加。而不是") and a misread final
  word on 21/22 s clips ("arrive. here", "改动。用，") where flash was right; judged far smaller than
  flash's pause breaks. The live two-way stream still shows "。" at pauses in Chinese while Siri is
  held (no parameter changed it); the refinement replaces it on release. With the live stream on,
  the stream's own final is awaited only when the refinement failed. `--nostream` in the verifier runs
  the session in parallel and starts it two packets late to exercise the buffering.
- Seed-ASR 2.0 (`volc.seedasr.sauc.duration`) returned 403 on the user's account (not enabled in the console).

### Dictation pane layout and alternative hotkey (2026-11-11, user's request)

Settings › Dictation: an optional top hint (only when Siri is not set to Dictation, or only some profiles
use it), one **Service** group holding the service, its language and that service's own rows (Seed: key,
Type While Speaking, Remove Filler Words, Use Text Before the Cursor, App ID; no Seed footer), the Dictionary, and **Alternative Dictation Hotkey**. The
"Last Dictation" status section and the usage/console sentences were removed at the user's request.
- The hotkey (`dictationHotkey`: none, Left/Right Option, Command, Control) dictates like a Siri hold:
  `DictationHotkeyMonitor` (NSEvent global + local monitors for flagsChanged/keyDown, started at launch)
  feeds `DictationHotkeyGate`; press alone → `DictationController.begin(source: .macMicrophone)`,
  release → `end()`. The remote's microphone only streams while Siri is physically held, so the hotkey
  records the Mac's own microphone (`DictationAudioDevice.macMicrophoneID`: the system input if it is a
  real microphone, else the built-in one, else any non-virtual input) and never changes the system
  input (input switching was rejected on 2026-10-31). No drain grace for that source.
- A modifier is half of every shortcut: another modifier already down at the press, or any key or
  modifier while held, cancels the hold (`DictationController.cancel`, nothing typed). Sides are told
  apart by the device-dependent flag bits (NX_DEVICE…KEYMASK). Events whose source pid is VibeRemote's
  own are ignored, so a Siri mapping that holds Right Option cannot trigger it, and the hotkey only ends
  or cancels holds it started (`recordingSource == .macMicrophone`).
- Not yet tried on hardware/with a real microphone at the time of writing.

### Advanced Menu customization (2026-11-11, user's request)

The Controls card's **Normal | Advanced** segmented control (top of the remote card) switches the pills
between what each button does and what it does while the Advanced Menu is open; Restore Defaults resets
the mode on screen. (A separate Advanced Menu section briefly existed the same day and was folded into
this switch.) In Advanced mode the opener's pill always reads Advanced Menu and the clickpad keeps its
fixed text. Advanced mode sets any `AdvancedMenuAction` or
None, per remote family, global (not per profile). `AdvancedMenuMapping` holds the built-in layout
(`defaultAction`), the offered buttons (glass: Siri, Menu, TV, Volume ±; aluminum adds Power and
Play/Pause), and `advancedMenuOverrides` = {generation: {button: raw | "none"}}, validated on read;
choosing a default removes the entry. The opener (Mute / glass Play/Pause) stays fixed. The controller
re-reads overrides on every press into `AdvancedMenuInputState.overrides`, and the panel draws each slot
from the button that owns it (Back top-left, glass TV top-right, Siri/aluminum Play/Pause middle-left,
Volume ± in the history capsule; a None slot is an empty glass), so icons always match behaviour.
Power and aluminum TV have no slot but still act.

### Auto Computer Use (2026-11-13, user's request)

Settings › Computer Use › **Auto Computer Use** (`autoComputerUse`, default off). With it on, a Siri
hold whose action is VibeRemote Dictation decides by what has the focus:
- `DictationController.begin` gives each hold a `HoldTarget`. If the Computer Use bar is already up,
  key and composing, the hold goes there at once and adds to what the bar holds. Otherwise it is
  `.pending` and `AutoComputerUse.probeFocusedTextInput` asks the frontmost app's focused element off
  the main thread (0.1 s AX timeouts, app element rather than system-wide, as for ChatGPT). A
  text area / text field / combo box with a readable selection keeps the hold an ordinary dictation;
  anything else (or nothing focused) calls `ComputerUseHandoff.open` (the same `show(fresh: true)` as
  a Computer Use button, after cancelling caret positioning and the Advanced Menu).
- Recording starts at Siri down regardless; only the destination waits. `DictationLiveHold.Routing`
  keeps partials while `.pending` and then delivers the latest one to the typewriter or the bar.
  Routed to the bar, partials set `ComputerUseAgent.command` directly (no keystrokes, no AX), the
  orange cursor is hidden, and nothing is typed into any app.
- On release the polished transcript — the refinement (nostream/flash) after filler cleanup and the
  dictionary, i.e. `finalText`, the same text dictation would type — replaces the bar's words and is
  submitted as the command. An empty result leaves the bar open. A probe still unanswered at finish
  falls back to ordinary dictation. A running command (`isBusy`) makes the hold an ordinary dictation.
- It applies only to remote Siri holds set to Dictation (not the keyboard hotkey, not held-key Siri
  mappings, whose third-party dictation app VibeRemote cannot steer). The glass remote reaches it
  the same way. The user confirmed it works from a real aluminum hold on 2026-11-13 (log: two holds with
  no text field in focus, `→ Computer Use`, 21 and 37 characters sent, nothing typed); the glass remote
  and the in-text-field branch under the switch were not separately checked that day.

### Dictation trigger (2026-10-31)

Both generations stream microphone audio only while Siri is physically held; no host
command is known to start it (see Design/Research). A workaround that switched dictation
to the Mac's own microphone (for tap-to-toggle and other dictation buttons) was built and
rolled back at the user's request: switching the input source back and forth is not wanted.

### Onboarding and updates

The first-run guide is a compact 280×350 window (hidden title, close button only) with
centered text, Liquid Glass Back/Continue buttons and technical-drawing illustrations drawn
in SwiftUI (`RemoteBlueprint`), never the 3D CAD model. Pages, in order: welcome + feature
summary, connection + permissions + helper/audio install, Siri dictation mapping, delete word,
new line, arrow keys, Advanced Menu, cursor demo. Button names and callouts follow the drawn
remote family (glass: Menu, Play/Pause; aluminum: Back, Mute). Close/Back must never overwrite the saved mapping. Finish saves only an
assignable action and marks completion. Existing installs with a saved Siri mapping
or microphone engine migrate quietly; Getting Started in Settings reopens the guide.
Restart Onboarding in the menu-bar menu (shown even while disconnected) reopens it
at page 1 with the saved Siri choice; like Close, it never saves or clears completion.
Use the existing manager snapshots and permission callbacks; no duplicate HID/Bluetooth
managers. Keep the Dock icon while either Settings or onboarding is open/minimized.

Sparkle 2.10.1 is pinned in SwiftPM and embedded under Contents/Frameworks. Stage only
arm64, preserve nested entitlements, and sign nested code before the framework/app.
The public feed/key live in Release/update-config.json; the private Ed25519 key is
Keychain-owned (account com.viberemote.sparkle), never a source/defaults/env argument.
Build numbers must increase for every published update. Release/README.md describes
notarization, signed appcast preparation and publication. Preparation never publishes.
A working build/signature check is not evidence of a public feed or an actual installed
update. Verify download/install/relaunch from an older signed build before acceptance.
