# VibeRemote

VibeRemote is an experimental macOS menu-bar app that maps Apple Siri Remote
buttons to keyboard actions. It can also display the connected remote's
battery level and optionally bridge Siri Remote microphone audio through a
virtual audio device.

## Features

- Configurable actions for Back/Menu, TV, Siri, Play/Pause, volume, mute,
  power, previous-track, and next-track buttons.
- Press-and-hold mappings for Space, Right Command, and Right Option.
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

Create an optimized universal local build:

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

The microphone bridge is meant to run whenever the app is open, but it never
starts on its own: each start is an explicit menu action. Current builds read the
Siri Remote's dedicated audio HID interface directly and pass reports to the
user-session voice helper. Starting the bridge does not launch PacketLogger,
change Bluetooth debugging settings, or request administrator privileges.
On third-generation remotes, VibeRemote also performs the required HID-over-GATT
input-enable handshake (`0xAF`) before waiting for the 99-byte, 48 kHz Opus
microphone reports. The wire layout was cross-checked against the independent
[siri-remote](https://github.com/azais-corentin/siri-remote) reverse-engineering
project.

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
