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

The app detects which one is attached and switches layout automatically; both can be
paired at the same time and each keeps its own mapping.

## Features

- A native settings window (System Settings style) opened from the menu bar's **Settings…**
  item, also while the remote is disconnected. The Controls pane shows the remote as a 3D
  model built from the supplied STEP CAD assemblies (second/third generation share one
  model); drag to turn it, release to restore the guide pose.
- Every button's function sits in a glass pill beside the remote. Click a pill to choose
  what Back/Menu, TV, Play/Pause, Volume Up/Down, Power and Siri do; the Advanced Menu
  opener, the clickpad / touch surface and the directions keep fixed roles.
- **Per-app button profiles** (see [Button profiles](#button-profiles)): General for every
  app, plus Claude and ChatGPT out of the box, and any installed app you add.
- **VibeRemote Dictation** (see [Dictation](#dictation)): choose Dictation for Siri and the
  app transcribes the remote's microphone itself — streaming text as you speak with Seed
  ASR — with an orange cursor at the insertion point while you hold Siri.
- Automatic per-generation layouts. The 1st-gen remote has no Mute and no Power key, so
  its Play/Pause opens Advanced Menu and its TV sends Shift+Enter. Only Siri does
  something different when held; Back and the arrows just repeat. On both generations Siri's mapping
  applies only to the physical Siri button, and the remote microphone transmits only while
  that button is held.
- Press-and-hold Siri mappings for Space, Right Command and Right Option (for your own
  dictation app), or VibeRemote Dictation.
- Back/Menu deletes a word immediately on every press, including rapid repeated presses;
  holding repeats word deletion. Use Advanced Menu to clear the full input.
- Aluminum Play/Pause opens Computer Use (pressed again it closes the bar or stops its command);
  Esc and Skill (`/`, `$` or the frontmost app's trigger) are choices for any button. Mute opens Advanced Menu.
- Slide on the touch surface / clickpad ring to position the text cursor; see
  [Text-cursor positioning](#text-cursor-positioning).
- Siri Remote connection and battery status in the menu bar.
- Suppression of duplicate HID/media-key delivery without globally unloading macOS's
  remote-control daemon.
- Microphone bridge with diagnostics.
- Computer Use: press Play/Pause (aluminum remote) or any button set to Computer Use to
  open the callout, dictate a task into it, and run it. With **Auto Computer Use** on
  (Settings › Computer Use), holding Siri with no text field in focus opens it for you, fills it
  with what you say, and sends it when you let go; in a text field Siri dictates as usual. See [Computer-use agent](#computer-use-agent).

## Requirements

- macOS 27 or newer on Apple Silicon.
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

## Computer-use agent

Press Play/Pause on the aluminum remote (or any button set to Computer Use in Settings ›
Controls; the 1st-gen remote has none by default) or choose **Computer Use** in the menu bar.
A floating panel takes focus; hold Siri and your dictation app types the task into it.
Select (or Return) runs it; pressing the Computer Use button again stops a running task, or
closes the panel. While the task runs, focus returns to the app you were in.

The planner operates the Mac through [agent-desktop](https://github.com/vercel-labs/agent-desktop),
bundled in the app, which acts on native accessibility trees without moving the pointer.
Pick the planner in the panel:

- **Claude Code** runs `claude -p` with only Bash, and only `agent-desktop` commands
  pre-approved. Sign in to the `claude` CLI first.
- **Codex** runs `codex exec`. Codex's sandbox blocks agent-desktop, so it runs with
  full access and no approval prompts; it is told, not forced, to use only agent-desktop.
- **OpenRouter** calls the chosen model directly (default `anthropic/claude-sonnet-5.5`)
  with a single `agent_desktop` tool; VibeRemote runs each command. The API key is stored
  in the login keychain.

The planners are told not to send, post, buy, delete or change settings unless the task
asks for that exact action. Each run stops after ten minutes. agent-desktop uses
VibeRemote's Accessibility permission; screenshots additionally need Screen Recording.

## Advanced Menu

Tap the bottom-left remote button (Mute on aluminum remotes; Play/Pause on the
first generation) to show a glass menu beside the text insertion caret (falling back
to the mouse pointer if no text caret bounds are available). The menu preserves
the focused editor. Back clears the input; on the old remote TV opens the Skill picker.
On aluminum remotes Skill has moved to ordinary Play/Pause and the menu's TV slot is inactive.
The middle-left Stop current task button sends Esc: Siri on the first generation,
Play/Pause on the second and third generations. Volume Up redoes (⌘⇧Z), and Volume
Down undoes (⌘Z), with forward/backward curved-arrow icons. Pressing the menu button leaves the menu
open, however long you hold it. While it is still held, another action button executes
immediately on press. In the latched menu, actions
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

Siri directly performs its configured action on press and release. Advanced Menu and
active caret positioning retain priority.

## Firmware research

First-generation microphone-control findings, evidence, diagnostic tools and cross-machine handoff are indexed in [Design/Research/README.md](Design/Research/README.md). Software-only capture and a reliable unlock/restore workflow remain unverified; current button mappings are unchanged.

## Button profiles

The Controls pane edits one profile at a time, picked from the profile switcher in the
window's top-right corner. **General** applies in every app that has no profile of its own. The menu lists
every profile with its app icon, **Add App** offers every installed application, and an
app profile can be removed from the same menu. Claude and ChatGPT come preinstalled and start
out following General. A **Normal | Advanced** switch at the top of the remote card shows either
what each button does, or what it does while the Advanced Menu is open.

An app profile keeps only the buttons you change for it. Every other button does what
General does, and keeps following later changes to General; a pill's **Same as General**
choice undoes an app-specific change. Siri is per profile too, so Dictation can be on in
one app and off in another. Restore Defaults restores the profile on screen (Claude and
ChatGPT return to their Skill trigger); Auto Disconnect lives on the Device pane.

The profile is chosen by the app in front when a button goes down and kept until it comes
back up, so a press that switches apps — or a hold you carry into another app — releases
the way it pressed.

## Dictation

Choose **Dictation** on the Siri pill (in any profile) to have VibeRemote transcribe the
remote's microphone instead of holding a key for a third-party dictation app; Settings ›
Dictation picks the service (Apple, WhisperKit on device, OpenAI, or Seed ASR from
ByteDance/Volcengine) and the language, and stores your own API keys in the keychain.

With Seed ASR and **Type While Speaking** on, the words stream into the focused editor as you
speak. Text already typed is never deleted while you hold Siri; when you let go, the whole clip is recognized once more by the accurate recognizer and
the text is refined in place. That accurate pass is uploaded while you speak, so it usually lands within a second of letting go, and it places periods by meaning, not by how long you paused to think. Without it the clip is transcribed when you let go. Text is typed as keystrokes, never through the clipboard, and
corrections only ever delete what the current hold typed.

**Dictionary.** Settings › Dictation › Dictionary lists names and terms dictation tends to get
wrong. Seed ASR listens for them when it refines the text after you let go, OpenAI is given them
as its vocabulary, and every engine writes them with your capitalization.

**Cleaner, more accurate Seed text.** Two Seed ASR switches, both on by default: **Remove
Filler Words** drops um, uh, 嗯, 那个 and stutters such as "我想我想"; **Use Text Before the
Cursor** sends up to 500 characters already in the field along with the audio, so names and
topics you have already typed come out right (that text goes to Volcengine with the recording;
password fields are never read).

**Alternative hotkey.** Settings › Dictation can also assign one keyboard modifier (Left or
Right Option, Command or Control). Hold it to dictate exactly as with Siri, through the Mac's
own microphone (the remote's microphone only works while Siri is held). Pressing another key
while holding it counts as a shortcut and records nothing.

While you hold Siri, an orange copy of the caret-positioning cursor stands at the insertion
point. Its mic fills with the live input level, so a stopped bridge reads visibly empty, it
follows the words as they stream in, and a spinner replaces the mic while the last words are
recognized. It works in native text views and in web editors such as Claude's and ChatGPT's
composers; an editor that exposes no caret geometry shows no cursor, but dictation still types.

## First launch and Settings

New users get a short introduction: features, Bluetooth/permission and helper setup, the
Siri mapping, then the main gestures. Finish saves the choice; closing leaves setup
unfinished. Existing configured installations keep their mapping without a forced tour.
Reopen the guide with **Getting Started** in Settings › About, or **Restart Onboarding** in
the menu bar.

Settings panes: Controls (the profile switcher, the remote and its pills with a Normal | Advanced
switch, and the text-cursor guide), Device (status, Auto Disconnect and diagnostics), Dictation, Computer Use, and About (version,
updates and links) at the bottom of the sidebar.

## Automatic updates

VibeRemote 0.3 adds Sparkle, with daily update checks and a manual **Check for Updates…**
action. Downloads/installations use Sparkle's standard UI and signed archives.
The first Sparkle-enabled version needs a manual installation. Release preparation
and update verification are documented in [Release/README.md](Release/README.md).
