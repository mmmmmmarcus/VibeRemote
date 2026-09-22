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
- Settings has a read-only remote diagram with button callouts on the left, and controls
  for Siri Button and auto disconnect on the right, with a text-cursor usage guide.
  There is one working configuration: microphone and fixed buttons stay available.
  Touch no longer moves the mouse, clicks, scrolls, or deletes text.
  The menu bar retains status, Advanced Menu, Settings and Quit. Settings' ellipsis
  includes Audio Output and Diagnostics. Only Siri's action is customizable.
  Aluminum Play/Pause is reserved; Mute opens Advanced Menu.
- Automatic per-generation button profiles. The 1st-gen remote has no Mute and
  no Power key, so the mute button's two roles move to buttons that do exist:
  holding TV arms the modifier chords (TV+Menu clears the input, TV+Play/Pause
  sends Esc) while a TV tap still sends Shift+Enter, and holding Play/Pause
  previously provided Skill/client actions; Play/Pause now opens Advanced Menu. On both generations,
  **Siri Button Mapping** applies only to the physical Siri button; the touch
  surface / clickpad center enters and confirms text-cursor positioning. The remote microphone transmits only
  while the physical Siri button is held.
- Press-and-hold mappings for Space, Right Command, and Right Option.
- Back/Menu deletes a word immediately; holding repeats word deletion. Double-click
  within 300 ms to clear the current editable input on the second release. Both
  clicks must stay in the same editor; a hold or another remote button cancels the pair.
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
`CODESIGN_IDENTITY=...` to choose a different one, and `ARCHS="$(uname -m)"` for a faster
host-only build.

Or create an optimized universal local build without installing it:

```bash
./create_app_bundle.sh
open VibeRemote.app
```

`build.sh` uses SwiftPM as the source of truth and builds both arm64 and
x86_64 by default. Override the architectures when a faster host-only build is
useful:

```bash
ARCHS="$(uname -m)" ./build.sh
```

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

On either remote, quickly move one finger out and back once without lifting to reveal
a thin surrogate caret with a four-way-arrow bubble growing from its top. Keep the same
finger down and slide freely in two dimensions; lifting snaps to the nearest visible
character boundary, commits the real caret and hides the overlay. The black-glass remote's
mechanical surface click remains Enter because it has no separate Power/submit button. The
aluminum center no longer enters caret mode. The real selection stays unchanged until lift.
Siri, Power/Return, typing, clicking, a focus or
content change cancels positioning. Siri and Return used to exit are consumed; the
cancelled voice hold and its tail remain muted. The next ordinary Siri hold resumes voice.
Before the return gesture is recognized, touch has no editing, overlay or pointer
action. No active accessible editor means no overlay.
Secure fields, active compositions and unsupported caret geometry fail closed.
The current AX calibration requires existing text; an empty editor does not show a surrogate caret.
The caret stays inside the editor; its decorative bubble can extend above it.
The overlay does not activate a window and respects Reduce Motion.

Both generations' touch frames come from the existing passive PacketLogger stream, without
releasing audio HID/GATT handles. The low-level NativeTouch adapter is retained as a
capability; there is no mouse mapping or Touch/Audio mode switch. Old saved mode and
pointer-speed settings are ignored. First-generation decoding accepts only 13/20-byte
`0x32` touch reports on ATT `0x0023`, so voice packets on the same handle are excluded.
Physical movement direction, shake thresholds and target-editor compatibility
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
the focused editor. Back clears the input, TV opens the focused app's Skill picker,
Play/Pause switches Touch / Audio on aluminum remotes, and Volume Up / Down select
the previous / next Codex or Claude session. A quick menu-button tap leaves the menu
open; hold it for 250 ms or longer to peek, then release to close. While holding it,
another action button executes immediately on press. In the latched menu, actions
execute once on release. Either action closes the menu and consumes the remaining
releases. Click outside, press Escape, or tap the menu button again to cancel.
The clickpad, Siri and Power keep their normal behavior. The old remote has four
menu actions because its Play/Pause is the opener and Siri remains unchanged.

The aluminum remote's auxiliary buttons use captured reports in both modes, sharing
one action owner with media suppression. Normal audio-mode actions retain the HID
connection quarantine and idle tracking. Settings always labels the physical opener
Advanced Menu, overriding a previous mode-switch assignment on that button.
