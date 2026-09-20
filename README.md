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
- Default mappings for navigation, editing and app switching; Siri is customizable.
  Play/Pause and Mute can each switch between Touch and Audio & Buttons instead of their
  original action. Changes save immediately. **Reset** restores all three assignments.
- Automatic per-generation button profiles. The 1st-gen remote has no Mute and
  no Power key, so the mute button's two roles move to buttons that do exist:
  holding TV arms the modifier chords (TV+Menu clears the input, TV+Play/Pause
  sends Esc) while a TV tap still sends Shift+Enter, and holding Play/Pause
  types "/" while a tap still toggles the agent client. On both generations,
  **Siri Button Mapping** applies only to the physical Siri button; the touch
  surface / clickpad center sends Enter. The remote microphone transmits only
  while the physical Siri button is held.
- Press-and-hold mappings for Space, Right Command, and Right Option.
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

## Experimental audio delivery and touch mode

Select **Mode → Audio & Buttons / Touch (Experimental)** from the menu bar, or use
Settings' hand icon. Audio mode retains fixed button mappings and held-Siri capture.
Touch mode releases all app-owned remote HID/GATT handles and disables voice decoding,
then attaches to remote-sized MultitouchSupport
surfaces: slide moves the pointer, tap clicks, two fingers scroll. The modes are
mutually exclusive and remembered across launches. Hardware behavior must be checked
with each remote generation; an attached surface alone does not prove touch delivery.

With PacketLogger selected, passive capture remains running in Touch. For aluminum
remotes, assigned Play/Pause and Mute keys are matched against fresh captured button
reports before suppressing the corresponding system media events. Unmatched media
events are forwarded after a bounded 160 ms wait. This remains experimental: simultaneous
media-key presses from other devices can be ambiguous, and the old remote capture
format is not supported for switching back. The toolbar mode selector remains available.

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
