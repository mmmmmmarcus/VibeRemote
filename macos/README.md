# vvhisper

vvhisper is an experimental macOS menu-bar app becoming a general voice interface for
the Mac: dictate text into apps and give Computer Use spoken tasks. The baseline is the
Mac’s built-in microphone and keyboard, without a dedicated accessory. Siri Remote and
future supported devices enhance the experience with additional controls and audio inputs.

Development focuses on four priorities: **general dictation**, **faster and easier
Computer Use**, **more device support**, and **product design that fits this direction**.
[Product direction](Design/ProductDirection.md) records the intended experience and
separates current functionality from planned work.

## Using the Mac alone

In Settings › Dictation, choose a service and configure the keyboard modifier under
**Voice Input**. Hold that key alone to dictate
through the Mac’s microphone; release it to finish. The Microphone menu can follow the
system input or select the built-in microphone explicitly.

Open **Computer Use** from the menu bar, type or dictate into its input field, and press
Return to submit. Configure its OpenRouter models and key in Settings › Computer Use. Auto Computer Use
currently applies only to Siri Remote dictation holds; the keyboard path uses the bar
and explicit submission. The first-run guide still emphasizes remote setup and is part
of the planned product-design work.

## Chinese and English dictation

Seed ASR uses its default Chinese-English model for live output, final refinement and
fallback transcription. Speak Mandarin, English, or mix both in one sentence without
switching languages. Settings shows **Chinese + English** for Seed; other services retain
their own language picker. This applies to Mac, Siri Remote and Soundcore input, including
Soundcore's hold and hands-free gestures. Words stay in their spoken language rather than
being translated. Recognition accuracy still needs checking with the user's speech.

## Settings and diagnostics

Dictionary has its own Settings tab and uses the same saved vocabulary across voice inputs.
Open **About → Open Diagnostics…** for hardware reports, helper/daemon repair, logs and
Soundcore microphone testing. Diagnostics opens in a separate retained window; it can
stay open when Settings closes. It shares the app's existing hardware connections.

Build targets and source assets now use vvhisper. A small set of old identifiers is kept
for installed permissions, saved data and driver compatibility; see
[Naming compatibility](Design/NamingCompatibility.md).

Each Siri Remote model and Soundcore Work has a **Release Buffer** toggle and **Buffer Time**
slider in its device tab: 0.1–2.0 seconds, in 0.1-second steps, defaulting to enabled at 1 second.
Soundcore continues recording until this time elapses after key release; pressing again
within the buffer continues the sentence. Cancel and disconnect stop immediately. Siri
Remote retains the available trailing audio; firmware determines how long its microphone
continues transmitting. The black-glass remote's former fixed 0.3-second tail now uses this
setting. Audio already in transit still drains when the optional buffer is off.

Mac microphones are captured through AUHAL at the device's native sample rate, then
converted to 16 kHz mono on a serial processing queue. AUHAL does not resample input;
requesting 16 kHz directly from a 48 kHz MacBook microphone can deliver no audio.
The explicit `--verify-mac-microphone` launch flag checks the selected input with two
three-second captures in memory, logging sample counts and levels only (no ASR or files).

Each Siri Remote model and Soundcore Work has an **Input Gain** slider in its device
settings: 0 to +24 dB, in 1 dB steps, defaulting to 0 dB. The value is captured when a
recording starts and amplifies decoded audio before vvhisper's live transcription,
final/refinement transcription, and level meter. Samples are limited to the valid PCM
range. It does not change system volume or the remote's third-party held-key mappings.

The menu-bar menu's **Microphone** submenu switches the same voice-input preference as
Settings → Dictation. It lists System Input, currently available Mac microphones, and
Soundcore Work only while connected and ready. Saved disconnected devices stay out of
the menu. Switching inputs cancels an active keyboard-triggered recording; Siri's own
microphone remains tied to its physical button. The Mac's system input is not changed.

Soundcore supports both gestures on the same dictation key: hold to talk and release to
finish, or tap briefly (up to 0.22 seconds) to keep listening hands-free, then tap again to
finish. Both use the device's release buffer. The shared dictation cursor shows microphone
state and audio level; Escape cancels immediately. Soundcore taps no longer trigger
Computer Use double-tap; Mac microphone
hotkeys keep their existing behavior. Disconnect, cancellation and the existing 115-second
capture limit clear hands-free state; reconnection never resumes listening automatically.

## Optional Siri Remote integration

Both Siri Remote hardware families are supported:

| | 1st gen (A1513 / A1844) | 2nd & 3rd gen (A2540 / A2859) |
|---|---|---|
| Look | thin, black glass touch surface | thicker, aluminum clickpad ring |
| Buttons | Menu, TV, Play/Pause, Siri, Volume ± | adds Power and Mute |
| Microphone | HID report sniffing (see below) | dedicated `0xFA` audio collection |

Both can be paired at the same time and each keeps its own mapping. Settings has separate **Siri Remote · Black Glass** and **Siri Remote · Aluminum** tabs,
each editable while disconnected.

## Features

- A native settings window (System Settings style) opened from the menu bar's **Settings…**
  item, also while the remote is disconnected. The Siri Remote pane shows the remote as a 3D
  model built from the supplied STEP CAD assemblies (second/third generation share one
  model); drag to turn it, release to restore the guide pose.
- Every button's function sits in a glass pill beside the remote. Click a pill to choose
  what Back/Menu, TV, Play/Pause, Volume Up/Down, Power and Siri do; the Advanced Menu
  opener, the clickpad / touch surface and the directions keep fixed roles.
- **Per-app button profiles** (see [Button profiles](#button-profiles)): General for every
  app, plus Claude and ChatGPT out of the box, and any installed app you add.
- **vvhisper Dictation** (see [Dictation](#dictation)): choose Dictation for Siri and the
  app transcribes the remote's microphone itself — streaming text as you speak with Seed
  ASR — with an orange cursor at the insertion point while you hold Siri.
- Automatic per-generation layouts. The 1st-gen remote has no Mute and no Power key, so
  its Play/Pause opens Advanced Menu and its TV sends Shift+Enter. Only Siri does
  something different when held; Back and the arrows just repeat. On both generations Siri's mapping
  applies only to the physical Siri button, and the remote microphone transmits only while
  that button is held.
- Press-and-hold Siri mappings for Space, Right Command and Right Option (for your own
  dictation app), or vvhisper Dictation.
- Back/Menu deletes a word immediately on every press, including rapid repeated presses;
  holding repeats word deletion. Use Advanced Menu to clear the full input.
- Aluminum Play/Pause opens Computer Use (pressed again it closes the bar or stops its command);
  Esc and Skill (`/`, `$` or the frontmost app's trigger) are choices for any button. Mute opens Advanced Menu.
- Slide on the touch surface / clickpad ring to position the text cursor; see
  [Text-cursor positioning](#text-cursor-positioning).
- A static voice-balloon menu-bar icon, with connection and battery rows for Siri Remote
  and Soundcore Work when available. No disconnected-device row when neither is connected.
- Suppression of duplicate HID/media-key delivery without globally unloading macOS's
  remote-control daemon.
- Microphone bridge with diagnostics (see [Microphone bridge](#microphone-bridge)).
- **Computer Use** (see [Computer Use](#computer-use)): press Play/Pause (aluminum remote) or
  any button set to Computer Use to open the input bar, dictate a task into it, and run it.
  With **Auto Computer Use** on, holding Siri with no text field in focus opens it for you,
  fills it with what you say, and sends it when you let go; in a text field Siri dictates as usual.

## Requirements

For the baseline Mac experience:

- macOS 27 or newer on Apple Silicon, with a microphone and keyboard. The Mac’s built-in
  microphone is sufficient; no Siri Remote is required.
- Microphone permission for Mac-microphone dictation, Accessibility for text insertion
  and computer actions, and Speech Recognition permission when using the Apple service.
- Any credentials or setup needed by the selected service: Apple and WhisperKit dictation
  need no API key; OpenAI and Seed ASR use your own keys. Computer Use requires its chosen
  OpenRouter key for model-backed tasks (see [Computer Use](#computer-use)).
- To build from source: Xcode Command Line Tools, plus full Xcode to compile the app icon
  (see [App icon](#app-icon)).

The optional Siri Remote integration additionally uses:

- A paired Siri Remote, Bluetooth permission, and Input Monitoring for remote input.
- For its microphone bridge: vvhisper’s virtual audio device (legacy VibeRemote,
  BlackHole 2ch, and Soundflower (2ch) are supported), the privileged helper for prompt-free
  capture, and Apple’s PacketLogger. See [Microphone bridge](#microphone-bridge).

The remote bridge components are not required for Mac-microphone dictation.

## First launch and Settings

New users get a short introduction: features, Bluetooth/permission and helper setup, the
Siri mapping, then the main gestures. Finish saves the choice; closing leaves setup
unfinished. Existing configured installations keep their mapping without a forced tour.
Reopen the guide with **Getting Started** in Settings › Siri Remote.

The Settings sidebar has two groups. **System** holds Dictation, Dictionary and Computer
Use. **Device** holds separate Black Glass and Aluminum Siri Remote tabs, plus Soundcore
Work. Each Siri tab contains its own model, profiles, controls, cursor guide and connection
settings. About sits at the bottom and opens the separate Diagnostics window. Settings
opens to Dictation by default.

## Button profiles

The Siri Remote pane edits one profile at a time, picked from the profile switcher in the
window's top-right corner. **General** applies in every app that has no profile of its own. The menu lists
every profile with its app icon, **Add App** offers every installed application, and an
app profile can be removed from the same menu. Claude and ChatGPT come preinstalled and start
out following General. A **Normal | Advanced** switch at the top of the remote card shows either
what each button does, or what it does while the Advanced Menu is open.

An app profile keeps only the buttons you change for it. Every other button does what
General does, and keeps following later changes to General; a pill's **Same as General**
choice undoes an app-specific change. Siri is per profile and per model too, so Dictation can be on in
one app or model and off in another. Restore Defaults restores only the selected model in
the profile on screen (an app profile goes back to following General).

The profile is chosen by the app in front when a button goes down and kept until it comes
back up, so a press that switches apps — or a hold you carry into another app — releases
the way it pressed.

## Dictation

Choose **Dictation** on the Siri pill (in any profile) to have vvhisper transcribe the
remote's microphone instead of holding a key for a third-party dictation app; Settings ›
Dictation picks the service (Apple, WhisperKit on device, OpenAI, or Seed ASR from
ByteDance/Volcengine) and the language, and stores your own API keys in the keychain.

With Seed ASR and **Streaming Output** on, the words stream into the focused editor as you
speak. Text already typed is never deleted while you hold Siri; when you let go, the whole clip is recognized once more by the accurate recognizer and
the text is refined in place. That accurate pass is uploaded while you speak, so it usually lands within a second of letting go, and it places periods by meaning, not by how long you paused to think. Without it the clip is transcribed when you let go. Text is typed as keystrokes, never through the clipboard, and
corrections only ever delete what the current hold typed.

Live draft words have a temporary orange underline while awaiting refinement. It clears
when the final text is ready or dictation stops. This is visual feedback, not saved text
formatting; it appears where the editor exposes usable accessibility text geometry.

**Dictionary.** Settings › Dictionary lists names and terms dictation tends to get
wrong. Seed ASR listens for them when it refines the text after you let go, OpenAI is given them
as its vocabulary, and every engine writes them with your capitalization.

**Cleaner, more accurate Seed text.** Two Seed ASR switches, both on by default: **Remove
Filler Words** drops um, uh, 嗯, 那个 and stutters such as "我想我想"; **Use Text Before the
Cursor** sends up to 500 characters already in the field along with the audio, so names and
topics you have already typed come out right (that text goes to Volcengine with the recording;
password fields are never read).

**Hotkey.** Settings › Dictation › Voice Input assigns one keyboard modifier (Left or
Right Option, Command or Control). Hold it to dictate exactly as with Siri, through a Mac
microphone (the remote's microphone only works while Siri is held). Pressing another key
while holding it counts as a shortcut and records nothing.

Once a hotkey is set, its **Microphone** menu chooses what it records:

- **Same as System** (the default) follows the Mac's input setting. The menu names the
  microphone this means right now. While the system input is vvhisper's own device, it uses
  the built-in microphone, or another real microphone on a Mac without one.
- **Soundcore Work**: uses its BLE microphone directly in vvhisper when connected. The
  same hotkey drives this source; there is no separate device hotkey setup. After the
  first successful connection, vvhisper reconnects automatically when the device is
  nearby and available, including after restarting the app. Disconnect pauses this
  until Reconnect or the next app launch. Keep its phone Bluetooth connection off.
- **A specific microphone**: any connected input, such as a USB mic or a Bluetooth headset.
  vvhisper's own device, BlackHole and Soundflower are not listed, because they carry only the
  remote's voice. A chosen microphone that is not connected shows as "(Not Connected)", and
  holds use Same as System until it comes back.

The hotkey never changes the system input; it records the chosen microphone directly. Opening a
Bluetooth headset's microphone usually switches the headset to its call profile for the hold, so
its playback may sound lower quality until the hold ends. The hotkey needs Microphone access for
vvhisper; the Dictation pane shows a Microphone Access row once a hotkey is chosen; the remote does not.

While you hold Siri, an orange copy of the caret-positioning cursor stands at the insertion
point. Its mic fills with the live input level, so a stopped bridge reads visibly empty, it
follows the words as they stream in, and a spinner replaces the mic while the last words are
recognized. It works in native text views and in web editors such as Claude's and ChatGPT's
composers; an editor that exposes no caret geometry shows no cursor, but dictation still types.

## Computer Use

Choose **Computer Use** in the menu bar, type or dictate into the input bar, and press
Return to run the task. A Siri Remote button mapped to Computer Use opens the same bar;
Select submits it. The bar accepts input immediately while its position is adjusted to
vvhisper’s Dock icon. While a task runs, focus returns to the previous app, the bar shows
progress and a Stop button, and the Dock icon turns green. The outcome shows briefly with
a ✓ or !. Pressing the Computer Use remote button again stops a running task or closes the bar.

Computer Use chooses its execution path automatically:

- **Local actions first.** Recognized app-opening and explicit web-address commands use
  native Mac actions without a model request.
- **Jev for judgment.** For a named conversation in ChatGPT, Codex, or Claude, the quick
  path looks only at conversation navigation exposed by the app’s current accessibility
  tree. An exact unique title is selected locally; Jev can match a topic against the
  observed candidates through OpenRouter’s Decisions API. It does not search an entire
  hidden chat history. Unresolved targets can pass to the automation model before any
  conversation selection is dispatched. After a selection is sent, an uncertain result
  stops with a status message rather than replaying the request through another route.
- **An automation model for planning.** Tasks outside the direct capabilities use the
  selected OpenRouter model with [agent-desktop](https://github.com/vercel-labs/agent-desktop),
  bundled in the app. It observes native accessibility trees and executes tool commands.

Settings › Computer Use has **Automation Model**, **Decision Model**, and one **OpenRouter
API Key** shared by both. The decision model defaults to `typesafe/jev-1.14`; it must support
OpenRouter’s Decisions API. The automation model must support tool calls. The key stays in
the login Keychain. Previous CLI-specific settings are retained for compatibility, but the
current Computer Use interface uses OpenRouter for model requests.

**Auto Computer Use** (off by default) applies to Siri Remote dictation holds. With Siri set
to Dictation, holding it outside a text field opens the bar and sends the finalized transcript
as a task on release; in a text field, Siri dictates as usual. The Mac keyboard dictation
hotkey can dictate into the open bar, followed by Return to submit.

The automation model is instructed not to send, post, buy, delete, or change settings unless
the task asks for that exact action. Each run stops after ten minutes. agent-desktop uses
vvhisper’s Accessibility permission; screenshots additionally need Screen Recording.
See [Computer Use routing](Design/ComputerUseRouting.md) for boundaries and validation.

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

Settings › Siri Remote › **Advanced** shows what each button does while the menu is open, and
lets you change it per remote family. Outside the menu, Siri performs its configured action;
Advanced Menu and active caret positioning take priority over it.

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

## Build

Build, sign, and install over `/Applications/vvhisper.app`:

```bash
./install.sh
```

`install.sh` signs with Haolin Fei’s personal Developer ID (Q9MD524YL5), stages the new
bundle, and checks that its signing requirements remain compatible with the installed
app before quitting it. It exchanges the bundles atomically at `/Applications/vvhisper.app`
and keeps the previous bundle available until verification and launch succeed. Failed
verification restores the previous bundle; a failed rollback preserves recovery files.
macOS uses the designated code requirement to remember privacy approvals across builds.
The installer rejects a different team or incompatible requirement and never falls back
to ad-hoc signing. Pass `CODESIGN_IDENTITY=...` to select another certificate on the same
personal team.
The team migration from the former company signature is covered in [Release/README.md](Release/README.md). Builds target Apple Silicon (arm64) only;
Intel Macs and universal binaries are no longer supported.

Or create an optimized, personally signed arm64 bundle without installing it:

```bash
./create_app_bundle.sh
```

Use `./install.sh` for permission and device testing so the running copy has one stable
path. Do not run an older company-signed `VibeRemote.app` from the repository alongside
vvhisper: both retain `com.viberemote.app`, but have different signing identities.

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

Bundle creation defaults to the personal Developer ID. This explicit command is equivalent:

```bash
SIGNING_MODE=developer \
CODESIGN_IDENTITY="Developer ID Application: Haolin Fei (Q9MD524YL5)" \
./create_app_bundle.sh
```

`SIGNING_MODE=local ./create_app_bundle.sh` explicitly creates an ad-hoc development
bundle. Do not install it over the personally signed app; changing code identity can
require fresh privacy approvals.

Distribution builds also require a `notarytool` keychain profile; release mode
signs with secure timestamps, submits the archive, and staples the result:

```bash
SIGNING_MODE=release \
CODESIGN_IDENTITY="Developer ID Application: Haolin Fei (Q9MD524YL5)" \
NOTARY_PROFILE="VVHISPER_NOTARY" \
./create_app_bundle.sh
```

The microphone helper is built from the local Swift source in
`VoiceBridgeHelper/` and is included in local bundles by default.

## Permissions

Approve the required capabilities on first use in System Settings. Moving from the
former company signing team to the personal team can require one-time reapproval.
Normal updates installed with `./install.sh` should retain these approvals; repeated
requests after compatible signed updates need investigation. Ad-hoc builds have a
different code identity and can prompt again after every rebuild:

1. Privacy & Security > Accessibility
2. Privacy & Security > Input Monitoring
3. Privacy & Security > Bluetooth
4. Privacy & Security > Microphone (Dictation)

## Tests

```bash
swift test
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=complete
./scripts/clean-build.sh
```

CI runs both commands on macOS for every push and pull request.

## Microphone bridge

With the app open, the bridge automatically starts when its dependencies and the
approved, current privileged helper are available. A stopped capture pipeline is
retried with bounded backoff; reconnect and Mac wake also request recovery.
Automatic recovery never falls back to an administrator password prompt. Complete
missing setup in About › Diagnostics. Quitting vvhisper stops recovery and capture.

The default microphone engine is PacketLogger, including when no engine preference
is saved. It uses
Apple's separately installed PacketLogger, enables Bluetooth debug capture, and
runs only the capture supervisor as root. The voice decoder remains in the user
session. The Direct HID engine is retained as an explicit diagnostic override
(`defaults write com.viberemote.app microphoneBridgeEngine directhid`), but does not
deliver audio on the tested macOS configuration. Audio is emitted only while the physical Siri button is held.

Some black-glass remotes also expose a dedicated audio collection (observed with
product 0x026D / hardware revision 0A00), which vvhisper prefers. Only older remotes
without that collection use report sniffing on interfaces large enough to hold a
20 ms Opus frame; the voice helper validates framing per report.
Both generations encode CELT-only, single-frame Opus (`0xB8` — wideband, 20 ms), which is
what makes sniffing safe on an interface that also reports buttons: a report only becomes
audio if its length prefix and Opus TOC byte both check out.

For framing diagnostics, each bridge start keeps at most 128 raw audio HID
reports in the app's private Application Support directory. These reports can
contain microphone audio. Keep captures local, stop the bridge when it is not
needed, and inspect diagnostics before sharing them.

The bridge keeps its audio output stream warm for the lifetime of a bridge
session so each voice burst plays without per-press start-up latency. Siri Remote
firmware still decides when its physical microphone produces packets; current
remotes emit real audio only while the Siri button is held, so the bridge cannot
capture audio hands-free regardless of app settings.

**Audio path.** The voice helper sends decoded 48 kHz mono Float32 samples through a
two-second shared-memory ring directly into the vvhisper audio driver's input callback.
The file is created by helper v4 for the authenticated user's UID under
`/Library/Application Support/VibeRemote/Audio/`, mode 0660 for that user and
`_coreaudiod`, inside root-owned directories. No public `/tmp` file is used. The
render callback performs no allocation, filesystem access or blocking lock. Hardware
format is fixed to 48 kHz; CoreAudio converts client formats. Buffer overrun invalidates
successful drain reporting, underrun produces silence, and a stale writer heartbeat
returns the driver to ordinary loopback. An older driver or helper that cannot carry the ring
falls back to AVAudioEngine output automatically.

Physical Siri release, protocol voice-end, and rendered/read completion are separate
log events. A 250 ms quiet interval collects packets arriving just after protocol end;
these packets continue the ending session instead of starting another one. Only completed output releases a pending held dictation key; a 4-second
old-remote / 3-second new-remote deadline prevents stuck keys when markers or consumers
are absent. A timed-out or interrupted output is never logged as successfully drained.
HAL read completion does not prove that the receiving app transcribed the audio.

After changing the shared driver, run `./build_audio_driver.sh`, build and install the
signed app, and restart an already running privileged daemon
(`sudo launchctl kickstart -k system/com.viberemote.helper`). About › Diagnostics offers
**Install Audio Driver** while no supported audio device is present; installing restarts
CoreAudio. Check `voice-helper.log` for `Audio output: shared-memory HAL` and
`Voice buffer drained` during an actual recording.

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

`vvhisper.icon` is the Icon Composer source for the application icon. Bundle creation
uses Xcode's `actool` to compile its layers and appearances into `Assets.car` and a
compatibility `.icns`, then merges the generated icon metadata into `Info.plist`.
Full Xcode is required for this step; `ICON_DEVELOPER_DIR` can select its
`Contents/Developer` directory independently of the Swift build toolchain.

## Automatic updates

vvhisper 0.3 adds Sparkle, with daily update checks and a manual **Check for Updates…**
action. Downloads/installations use Sparkle's standard UI and signed archives.
The first Sparkle-enabled version needs a manual installation. Release preparation
and update verification are documented in [Release/README.md](Release/README.md).

## Firmware research

First-generation microphone-control findings, evidence, diagnostic tools and cross-machine handoff are indexed in [Design/Research/README.md](Design/Research/README.md). Software-only capture and a reliable unlock/restore workflow remain unverified; current button mappings are unchanged.

## Project status

This remains an experimental utility built around HID and media-event behavior
that can change between macOS releases. Hardware validation is required for
each supported Siri Remote generation.

## License

The vvhisper source is available under the MIT License. Third-party
components retain their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Open Computer Use with a double press

Double-press Siri on the remote, or double-press your selected dictation
Hotkey, to open the Computer Use bar above the Dock. Hold either trigger for ordinary
dictation. Use two quick taps (each under 220 ms, with the second release within 450 ms
of the first). Keyboard shortcuts using the modifier do not count as double presses.

**Polish Dictation** adds a text-only Seed 2.0 Mini editing pass after recognition to correct
grammar and spelling and improve sentence flow while preserving meaning and language.
It is enabled by default; add its API key in Settings > Dictation. The Volcengine Ark key is
stored separately from ASR and Computer Use. The fixed model is `doubao-seed-2-0-mini-260428`
with thinking disabled. The request has no tools and receives only the transcript.
Draft underlines remain until this pass finishes. Missing credentials, request failures,
empty or truncated responses keep the recognized transcript and report polishing skipped
or unavailable. Meaning preservation is a model instruction, not a semantic guarantee.

**Sentence Punctuation** in Dictation settings controls ending punctuation for one short
sentence, independently of polishing. It defaults on. Turn it off for casual messages
such as `Thanks` instead of `Thanks.`; commas remain. Longer and multi-sentence dictation
keep their punctuation. Short means up to 120 Unicode scalars and 20 words (40 scalars
when Chinese characters are present). The rule is applied after polishing.
