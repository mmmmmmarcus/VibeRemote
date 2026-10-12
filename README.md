# VibeRemote

VibeRemote is an experimental macOS menu-bar app that maps Apple Siri Remote
buttons to keyboard actions. It can also display the connected remote's
battery level and optionally bridge Siri Remote microphone audio through a
virtual audio device.

Both Siri Remote hardware families are supported:

| | 1st gen (A1513 / A1844) | 2nd & 3rd gen (A2540 / A2859) |
|---|---|---|
| Look | thin, black glass touch surface | thicker, aluminum clickpad ring |
| Buttons | Menu, TV, Play/Pause, Siri, Volume ± | adds Power and Mute |
| Microphone | HID report sniffing (see below) | dedicated `0xFA` audio collection |

The app detects which one is attached and switches profile automatically; both can be
paired at the same time and each keeps its own mapping.

## Features

- A native settings window with a visual Siri Remote button guide, opened from
  the menu bar's **Settings…** item (also available while the remote is disconnected).
  Both physical layouts use the supplied STEP CAD assemblies (second/third generation share one model); drag to turn, release to restore the guide.
- Settings has a 3D remote with read-only button callouts on the left, and controls
  for Siri Button and auto disconnect on the right, with a text-cursor usage guide.
  There is one working configuration: microphone and fixed buttons stay available.
  Touch no longer moves the mouse, clicks, scrolls, or deletes text.
  The menu bar retains status, Settings and Quit; Advanced Menu opens from the remote. Settings' ellipsis
  includes Audio Output and Diagnostics. Only Siri's action is customizable.
  Aluminum Play/Pause opens Skill ($ in Codex, / in other apps); Mute opens Advanced Menu.
- Automatic per-generation button profiles. The 1st-gen remote has no Mute and
  no Power key, so the mute button's two roles move to buttons that do exist:
  holding TV arms the modifier chords (TV+Menu clears the input, TV+Play/Pause
  sends Esc) while a TV tap still sends Shift+Enter, and holding Play/Pause
  previously provided Skill/client actions; Play/Pause now opens Advanced Menu. On both generations,
  **Siri Button Mapping** applies only to the physical Siri button; the touch
  surface / clickpad center confirms text-cursor positioning after a slide enters it. The remote microphone transmits only
  while the physical Siri button is held.
- Press-and-hold mappings for Space, Right Command, and Right Option.
- Back/Menu deletes a word immediately on every press, including rapid repeated
  presses; holding repeats word deletion. Use Advanced Menu to clear the full input.
- Tap the Skill / Modifier button to type `$` in the focused ChatGPT / Codex desktop
  client or `/` in Claude and other apps. Focus is checked on release; holding the
  button still enables modifier chords. This also applies when Siri is assigned this action.
- Siri Remote connection and battery status in the menu bar.
- Suppression of duplicate HID/media-key delivery without globally unloading
  macOS's remote-control daemon.
- Optional microphone bridge with diagnostics.

## Requirements

- macOS 11 or newer.
- Xcode Command Line Tools.
- A paired Siri Remote.
- Accessibility, Input Monitoring, and Bluetooth permission for the built app.

The optional microphone bridge additionally requires:

- BlackHole 2ch or Soundflower (2ch).

## Build

Build, sign, and install over `/Applications/VibeRemote.app`:

```bash
./install.sh
```

`install.sh` signs with the first Developer ID identity in the keychain. That matters
for day-to-day use: macOS keys the Accessibility / Input Monitoring / Bluetooth grants to
the code signature, so an ad-hoc signature — which changes on every build — revokes them
on every rebuild, while a stable identity keeps them for the life of the app. Pass
`CODESIGN_IDENTITY=...` to choose a different one. Builds target Apple Silicon (arm64) only;
Intel Macs and universal binaries are no longer supported.

Or create an optimized arm64 local build without installing it:

```bash
./create_app_bundle.sh
open VibeRemote.app
```

`build.sh` uses SwiftPM in a fresh temporary directory and removes its compiler cache
on success, failure, or a handled interruption. It retains the three output binaries
and a small resource bundle needed for packaging. `build_audio_driver.sh` also builds
arm64 only and cleans its temporary source/DerivedData by default; an explicit
`WORK_DIR` keeps those files for driver debugging or corresponding-source export.

For a short incremental development session only:

```bash
KEEP_BUILD_CACHE=1 ./build.sh   # reuse the single .build/swiftpm cache
./scripts/clean-build.sh       # remove all repository build/test caches afterwards
```

Do not run cleanup concurrently with builds/tests. Cleanup preserves source, uncommitted
changes, `.git`, the packaged app, the built driver, and the installed application.
Do not create separate architecture or per-task scratch directories for routine builds.
Direct `swift build` / `swift test` commands still create caches: clean them when finished.
The tradeoff is that default builds recompile instead of accumulating gigabytes of cache.

Local bundles are ad-hoc signed. For a Developer ID build, explicitly provide
the identity:

```bash
SIGNING_MODE=developer \
CODESIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
./create_app_bundle.sh
```

Distribution builds also require a `notarytool` keychain profile; release mode
signs with secure timestamps, submits the archive, and staples the result:

```bash
SIGNING_MODE=release \
CODESIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
NOTARY_PROFILE="viberemote-notary" \
./create_app_bundle.sh
```

The microphone helper is built from the local Swift source in
`VoiceBridgeHelper/` and is included in local bundles by default.

## Permissions

After each new local ad-hoc build, macOS may require the rebuilt app to be
approved again in System Settings:

1. Privacy & Security > Accessibility
2. Privacy & Security > Input Monitoring
3. Privacy & Security > Bluetooth

## Microphone bridge safety

With the app open, the bridge automatically starts when its dependencies and the
approved, current privileged helper are available. A stopped capture pipeline is
retried with bounded backoff; reconnect and Mac wake also request recovery.
Automatic recovery never falls back to an administrator password prompt. Complete
missing setup through the menu. Quitting VibeRemote stops recovery and capture.

The working microphone engine is PacketLogger (select with
`defaults write com.viberemote.app microphoneBridgeEngine packetlogger`). It uses
Apple's separately installed PacketLogger, enables Bluetooth debug capture, and
runs only the capture supervisor as root. The voice decoder remains in the user
session. The Direct HID engine is retained but does not deliver audio on the tested
macOS configuration. Audio is emitted only while the physical Siri button is held.

Some black-glass remotes also expose a dedicated audio collection (observed with
product 0x026D / hardware revision 0A00), which VibeRemote prefers. Only older remotes
without that collection use report sniffing on interfaces large enough to hold a
20 ms Opus frame; the voice helper validates framing per report.
Both generations encode CELT-only, single-frame Opus (`0xB8` — wideband, 20 ms), which is
what makes sniffing safe on an interface that also reports buttons: a report only becomes
audio if its length prefix and Opus TOC byte both check out.

For framing diagnostics, each bridge start keeps at most 128 raw audio HID
reports in the app's private Application Support directory. These reports can
contain microphone audio. Keep captures local, stop the bridge when it is not
needed, and inspect diagnostics before sharing them.

The bridge keeps its BlackHole output stream warm for the lifetime of a bridge
session so each voice burst plays without per-press start-up latency. Siri Remote
firmware still decides when its physical microphone produces packets; current
remotes emit real audio only while the Siri button is held, so the bridge cannot
capture audio hands-free regardless of app settings.

## Tests

```bash
swift test
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete
./scripts/clean-build.sh
```

CI runs both commands on macOS for every push and pull request.

## Project status

This remains an experimental utility built around HID and media-event behavior
that can change between macOS releases. Hardware validation is required for
each supported Siri Remote generation.

## License

The VibeRemote source is available under the MIT License. Third-party
components retain their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Text-cursor positioning

Direction buttons send normal arrow keys for both menu navigation (including Codex's
Skill picker) and text-caret movement. Pressing an aluminum direction button cancels
caret preparation/positioning and suppresses that touch contact until the finger lifts,
so clicking directions cannot immediately reopen the surrogate caret. Touch again to
resume the normal preview and slide gesture.

On either remote, slide one finger far enough in any direction to reveal a thin
surrogate caret with a four-way-arrow bubble. Entry counts cumulative travel (1000
normalized raw units), not direction reversals or speed; small sensor jitter is ignored.
After entry, horizontal motion stays free while vertical motion is slower and snaps
between text rows, with a small threshold to prevent accidental row changes. Lift and
slide again as often as needed. Lifting snaps only the preview
to the nearest visible character boundary and keeps positioning active. Press the
center (or the old remote's touch surface) to commit and dismiss, consuming the entire
click so it cannot also submit Enter. Outside positioning, the old surface click stays
Enter and the aluminum center stays reserved. After 3 seconds without accepted movement,
positioning automatically snaps to the nearest character boundary, commits and dismisses.
Stationary touch reports and lifts do not restart the timer; moving does. A finger still
resting on the pad at expiry must lift before starting another preview. Real selection
stays unchanged until a center click or this idle confirmation; both validate the editor first.
Siri, Power/Return, typing, clicking, a focus or
content change cancels positioning. Siri and Return used to exit are consumed; the
cancelled voice hold and its tail remain muted. The next ordinary Siri hold resumes voice.
Touch-down shows an opaque thin caret and a smaller, symbol-free preparation bubble.
The bubble bends with horizontal finger displacement and speed while the stem stays
anchored to the real insertion point. Cumulative travel gently expands it; crossing
the threshold springs into the full bubble and fades in the movement symbol.
Lifting before entry retracts the preview. Preparation never edits text, moves the
real caret, blocks voice or remaps buttons. No active accessible editor means no overlay.
Secure fields, active compositions and unsupported caret geometry fail closed.
The current AX calibration requires existing text; an empty editor does not show a surrogate caret.
The caret stays inside the editor; its decorative bubble can extend above it.
The overlay does not activate a window and respects Reduce Motion.

Both generations' touch frames come from the existing passive PacketLogger stream, without
releasing audio HID/GATT handles. The low-level NativeTouch adapter is retained as a
capability; there is no mouse mapping or Touch/Audio mode switch. Old saved mode and
pointer-speed settings are ignored. First-generation decoding accepts only 13/20-byte
`0x32` touch reports on ATT `0x0023`, so voice packets on the same handle are excluded.
Physical movement direction, travel thresholds and target-editor compatibility
must be tested on each hardware/app combination.

**Audio Output → Direct HAL (Experimental)** sends decoded 48 kHz mono Float32 samples
through a two-second mmap ring directly into the VibeRemote HAL input callback.
The file is created by helper v4 for the authenticated user's UID under
`/Library/Application Support/VibeRemote/Audio/`, mode 0660 for that user and
`_coreaudiod`, inside root-owned directories. No public `/tmp` file is used. The
render callback performs no allocation, filesystem access or blocking lock. Hardware
format is fixed to 48 kHz; CoreAudio converts client formats. Buffer overrun invalidates
successful drain reporting, underrun produces silence, and a stale writer heartbeat
returns the driver to ordinary loopback. **Compatibility** uses AVAudioEngine.
Old driver/helper versions automatically retain compatibility output.

Physical Siri release, protocol voice-end, and rendered/read completion are separate
log events. A 250 ms quiet interval collects packets arriving just after protocol end;
these packets continue the ending session instead of starting another one. Only completed output releases a pending held dictation key; a 4-second
old-remote / 3-second new-remote deadline prevents stuck keys when markers or consumers
are absent. A timed-out or interrupted output is never logged as successfully drained.
HAL read completion does not prove that the receiving app transcribed the audio.

After changing the shared driver, run `./build_audio_driver.sh`, build/install the signed
app, restart/re-register an old privileged daemon, and select **Audio Output → Install /
Update Audio Driver…**. This restarts CoreAudio. Check `voice-helper.log` for
`Audio output: shared-memory HAL` and `Voice buffer drained` during an actual recording.
To revert, select **Compatibility**; to regain keys/microphone, select **Audio & Buttons**.

Personal app builds embed the existing Apple-signed PacketLogger by default when found
at `/Applications/Additional Tools for Xcode/Hardware/PacketLogger.app`.
`PACKETLOGGER_APP_SOURCE` supplies another installed copy, `INCLUDE_PACKETLOGGER=0`
omits it. Release signing requires explicit `INCLUDE_PACKETLOGGER=1` to include it.
The Apple bundle is neither altered nor re-signed. Original dependency signatures are
checked during packaging and again before privileged capture starts.

Additional ring test (no root, no hardware):

```sh
xcrun clang -isysroot "$(xcrun --show-sdk-path)" -std=c11 -Wall -Wextra -Werror \
  scripts/test_shared_audio.c -o /tmp/viberemote-ring-tests
/tmp/viberemote-ring-tests
```

## App icon

`VibeRemote.icon` is the Icon Composer source for the application icon. Bundle creation
uses Xcode's `actool` to compile its layers and appearances into `Assets.car` and a
compatibility `.icns`, then merges the generated icon metadata into `Info.plist`.
Full Xcode is required for this step; `ICON_DEVELOPER_DIR` can select its
`Contents/Developer` directory independently of the Swift build toolchain.

## Advanced Menu

Tap the bottom-left remote button (Mute on aluminum remotes; Play/Pause on the
first generation) to show a glass menu beside the text insertion caret (falling back
to the mouse pointer if no text caret bounds are available). The menu preserves
the focused editor. Back clears the input; on the old remote TV opens the Skill picker.
On aluminum remotes Skill has moved to ordinary Play/Pause and the menu's TV slot is inactive.
The middle-left Stop current task button sends Esc: Siri on the first generation,
Play/Pause on the second and third generations. Volume Up redoes (⌘⇧Z), and Volume
Down undoes (⌘Z), with forward/backward curved-arrow icons. A quick menu-button tap leaves the menu
open; hold it for 250 ms or longer to peek, then release to close. While holding it,
another action button executes immediately on press. In the latched menu, actions
execute once on release, except Stop current task, which executes on press. Each action closes the menu and consumes the remaining
releases. Click outside, press Escape, or tap the menu button again to cancel.
Power sends ⌘Enter while the menu is open, closes it, and owns both press edges;
outside the menu Power remains Enter. The clickpad keeps its normal behavior.
In Advanced Menu, Siri sends Esc once on press to stop the current task. Both layouts show a stop icon in the middle-left slot. Normal dictation and the microphone
audio tail are suppressed for this hold; the next ordinary Siri hold restores the configured voice action.

The aluminum remote's auxiliary buttons use captured reports, sharing one action
owner with media suppression. Normal button actions retain the HID
connection quarantine and idle tracking. Settings always labels the physical opener
Advanced Menu, overriding a previous mode-switch assignment on that button.

On the first-generation glass remote, a quick one-way swipe and lift outside caret
mode sends one arrow key. Accumulating 1000 units of touch travel still enters caret
mode; lift then only settles its preview, and center click or idle confirms it.

### Remote Command (prototype)

Briefly tap Siri to open a focused native command box on either remote generation. Type or dictate a request,
then press Return (or the aluminum remote's Power / glass surface button) to run it.
The panel shows progress and the final response. Stop or Escape cancels a running
request; completed actions are not undone. Only one request runs at a time, with a
five-minute execution limit (time waiting for foreground consent is excluded). The input remains editable while a task runs; submit the next
request after the current one completes. `Command…` in the status menu opens the same retained panel.

Commands run in the background by default. Submitting, finishing, or requesting
consent does not activate the target app or switch Spaces. If a step needs foreground
delivery, the existing task pauses and the panel shows **继续执行**. Clicking it
authorizes that single step, which may switch Spaces or use the mouse/keyboard;
later steps return to background delivery. Each request expires after 15 minutes
without a click. Stop, closing the panel, or quitting cancels pending consent.
The panel updates in place without stealing focus; reopen Command if it is obscured.
Background actions still share the target app's content with you, and target apps
may have their own window-opening behavior.

Hold Siri for 250 ms to use its configured dictation action. Short taps never send
the mapped dictation key. Advanced Menu and active caret positioning retain priority
over this gesture. Aluminum Play still opens Skill, Mute opens Advanced Menu, and
glass Play remains the Advanced Menu opener. Settings shows Siri's tap/hold functions.

This first version integrates **locally installed** Codex CLI and Cua Driver; it
is not a self-contained driver distribution. Install Codex, run `codex login` with
your ChatGPT account, and install/authorize CuaDriver.app (Accessibility and Screen
Recording). VibeRemote locates executables in `~/.local/bin`, `/opt/homebrew/bin`,
and `/usr/local/bin`, plus the standard CuaDriver.app path. Current validated
versions: Codex CLI 0.161.0 and Cua Driver 0.28.2, Apple Silicon.

Each request uses `codex exec --ignore-user-config --ephemeral` with only the Cua
MCP server behind VibeRemote's native consent proxy and a desktop-tool allowlist. The existing Codex login is reused;
credentials and global config are never copied or edited. User commands go over
stdin, not a shell. Shell tools, other apps/connectors and subagents are disabled.
Codex routes required tool approvals through its automatic approval reviewer;
rejected actions remain blocked. Cua Driver retains its normal permission policy
and stable app identity. The model
receives the submitted request and whatever target UI Cua reads, including screenshots
when needed. Requests use the user's Codex account allowance. VibeRemote does not
write command text, screenshots or raw tool results to its diagnostic log. Temporary
per-request working directories are removed on completion; Cua/Codex may maintain
their own metadata. Requests requiring clarification stop with an explanation;
general conversational follow-up and conversation history are not in this prototype.
Foreground consent is separate from Codex's tool approval and does not override a
denied review or authorize unrelated actions.

References: [Cua Driver](https://github.com/trycua/cua/tree/main/libs/cua-driver),
[Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode).
