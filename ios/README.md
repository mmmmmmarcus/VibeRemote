# vvhisper for iOS and iPadOS — local prototype

> Personal-build update (2026-11-24): credentials are bundled at build time; no API-key
> setup or backend is required. Settings transfer now carries preferences only.
> Older credential setup instructions below are historical. See the repository's
> `macos/Design/PrivateBuilds.md`. Do not distribute these private app archives.


## Soft lift character previews — 2026-11-28

Character previews use one continuous outline, with vertical-tangent curves joining
the raised head to the pressed key. Show and hide are immediate, with no animation.
The head shifts inward at the edges and compresses within the keyboard's available
top space. Preview ownership, typing, hold actions and touch targets are unchanged.
Android uses the same shape in its keyboard drawing overlay, without a separate
character popup window.

## Duo keyboard host sizing — 2026-11-27

The keyboard's design height is a request, not a guarantee from the remote host.
The previous controller positioned fixed-height rows using that request even when
its actual bounds were shorter, and only recalculated metrics on width/orientation
changes. A constrained controller-host regression reproduces the missing/clipped
fourth row at unfolded widths before the fix.

The input view now opts into public self-sizing and publishes its preferred height.
Layout independently uses the granted bounds on every pass, including height-only
changes: first reclaim bottom/top whitespace and row gaps, then share the remaining
height among all rows without changing the fonts. Height-only fitting updates the
existing row constraints, preserving candidate/snippet state, and does not lower
the next preferred-height request. Expanded candidates use the same fitted row
geometry so they cannot cover the bottom controls. Normal-height metrics, Pinyin
and Snippet storage/insertion policies are unchanged.

`KeyboardHostBoundsTests` exercises a host with required edge constraints against
the extension's optional height request, dynamic unfold/rotate/shrink/grow cycles,
375/402/440/466-point layouts, historical 655/802-point extension widths, and
669/951-point inner-display-derived fixtures (plus host-margin variants). It
checks all four rows, unchanged letter font sizes, candidates, Snippet insertion
and full granted-frame PNGs. This is an isolated Builder controller harness, not
an installed remote keyboard or proof of actual Duo system height negotiation.
The exact system-granted bounds, physical fold/rotation behavior and host-specific
safe areas still require device validation; no shared simulator or TestFlight
release is part of this fix.

## Local Snippets — 2026-11-27

Settings → Keyboard → Snippet manages arbitrary abbreviation/content pairs. The
native editor validates ASCII letters/digits/underscore and case-insensitive
uniqueness, preserves the complete original Unicode text, and confirms unsaved
cancellation and deletion. There are no product count or length limits. List and
keyboard previews show only the first 20 graphemes; neither preview nor visual
truncation changes saved or inserted content. Inactive app snapshots are covered.

`Shared/SnippetStore.swift` owns an independent App Group `Snippets` directory:
complete file protection, backup-exclusion metadata, cross-process `flock`,
optimistic revisions, and protected temporary-file/atomic-rename commits. Nothing
is added to preferences transfer, sync, clipboard/history, AI requests or logging.
The main app does not need keyboard Full Access. Keyboard reads do; permission,
loading and read errors never masquerade as an empty store or show stale values.

The neutral toolbar entry follows Messages and precedes the unchanged clipboard
pills. It replaces only the existing header with a fixed Back button and a
virtualized horizontal strip. Manual taps insert the entire original once, never
delete an abbreviation, and leave the strip open. Key geometry/modes are unchanged.

An owned `@@` segment bypasses Pinyin/English correction. Exact case-insensitive
lookup offers a candidate; only its explicit tap expands. Every tap rereads the
store and validates id/revision, permission, document/session, original-case token,
context, selection revision and composing state. Only tokens typed in the current
verifiable keyboard session qualify; pre-existing/pasted tokens and ambiguous
hosts fail closed. Destructive expansion acknowledges each single ASCII deletion
before issuing another; there is no blind batch deletion, compensation, retry or
pasteboard fallback. Unresolved text-will/did notifications are a write barrier;
selection-will notifications cancel expansion immediately, even if the proxy still
reports the last acknowledged context. Hosts that emit indistinguishable selection
changes for owned edits may therefore stop after one delete rather than risk a
second. Candidate reads capture the context revision and lose raw ownership on
selection changes even before publication. Scheduled reads do not count as evaluated
until the owned raw suffix is acknowledged; delayed acknowledgments can retry.
Tap locks belong to operation IDs so canceled old reads cannot lock out or unlock
newer taps. UIKit provides neither an atomic cross-process replace nor a
success receipt: an interrupted host can leave a partially removed prefix, and
physical-host validation remains necessary. Full original content is inserted
once, without fabricated success/failure receipts.

Builder verification: `runtest <project-id> --script app` includes the real-Rime
integration, fake/coalescing/deferred proxy guards, native editor failures,
privacy cover, backup/policy checks, unchanged key frames and offscreen light/dark
PNG evidence at 375/402/440/466 points. `--script snippets-storage` runs 64 actual
macOS worker processes against the production locking/validation/rename code,
using `ios/scripts/test-snippet-concurrency.sh`, with only iOS-only protection calls adapted for macOS. It checks one concurrent
case-insensitive winner and no lost independent writes. This is not device Data
Protection evidence. Simulator cannot report protection classes; locked-device
behavior, actual Full Access/extension host transitions, VoiceOver/Switch Control
feel and physical-host proxy behavior still require device checks. No shared
simulator, release upload or version bump is part of this feature.

## Chinese multi-error suggestions — 2026-11-27

Continuous mistyped Pinyin can now offer optional whole-input Chinese candidates,
including `woxhfiaole` → `我知道了`, without replacing the marked spelling or changing
the existing Space default. Exact spellings retain their Rime order. A local,
build-time trie of 80,000 frequent dictionary spellings supports bounded combinations
of neighboring-key slips, transpositions and missing/extra letters. Edit cost plus
original dictionary frequency ranks repairs; a separate Rime session verifies full
commits. There is no phrase-specific mapping, network typing or learned history.
Search/candidate counts, time and memory are capped; cancelled or exhausted searches
fall back to the native path. Suggestion commits validate input and revision, and
queued edits preserve their order. Rare spellings outside the small correction index
remain available through the unchanged full Rime dictionaries.

Validation: all 331 tests passed on the isolated Xcode 27.2 Builder (iPhone 18 Pro,
iOS 27.2), including real-Rime multi-error/exact/negative cases, stale revisions,
cancellation, both bilingual policies, coalesced-host candidate-tap then digit order,
and the existing 375/402/440-point and Duo offscreen layout suite. Twelve warm Debug
samples measured search median/p95 10.5/13.9 ms and final-key engine response
15.4/16.8 ms. The generated index is 4,730,480 bytes (295,654 nodes); this is index
size, not measured total process memory. Cold-start and physical-device latency,
physical typing feel and broad corpus false-positive rates remain unverified.
No shared simulator was used; no version bump or release is part of this change.

## Extended Delete — 2026-11-22

Holding Delete expands its surface left over M and reveals a broom at the left
edge. Sliding to the broom clears the field once; release restores the normal
keys. Quick taps and held repeats keep their existing behavior, including word
deletion in mini mode. Dictation cancellation remains a separate gesture.

Geometry comes from the actual neighboring key, including Duo's folded/unfolded
portrait/landscape and split layouts. Symbol pages borrow the adjacent symbol;
mini borrows only the right edge of Dictate; iPad uses the adjacent number-row key.
The overlay changes paint only, preserving all key hit targets. It restores on
interruption, rotation, mode changes, field changes and keyboard dismissal.

Apple's installed catalog has no built-in broom. `DeleteBroom.symbolset` contains
original broom artwork in Apple's custom SF Symbols format, compiled and validated
by the asset catalog. It supports monochrome tinting and light/dark appearance;
the motion uses a 180 ms reveal and 120 ms dismissal, respecting Reduce Motion.

Validation: all 280 unit/integration checks passed. The new cases cover clear-once
behavior at the visible broom, release without clearing, field/rotation/dismissal
cleanup, preserved M hit targets, gap dictation and dictation slide-cancel. Native
light/dark contact sheets were inspected for Duo folded and unfolded portrait and
landscape, including mini mode (`build/verification/delete-expansion.png`). Symbol
pages and iPad sizes also pass geometry and editing checks.
The installed-extension simulator touch test passed: a real held drag from Delete
through M clears the synthetic field, then M inserts normally and a Delete tap
removes one character. This is simulator evidence, not a physical-device check.
The personal-signed build passed strict signature verification and was installed
on the Duo without erasing data. Physical automation is still blocked by the
Wi-Fi XCTest IDE-channel failure (exit 74); on-device gesture feel remains manual.

## Motion and tactile feedback refinements — 2026-11-22

Full/mini transitions now keep a stable full-height canvas while the key faces
move with the pinch, committing the final host height after a 120–200 ms settle.
This avoids per-frame remote-host height updates and the initial target-height
jump. Emoji Back has tap feedback; Enter gives normal touch-down feedback and a
stronger, sharper confirmation when the hold inserts a line break. Shift and
Emoji icons fade with the letters during dictation and return after release.

Translation's purple target confirms gesture selection. The former generic
“Translation failed” represented an unsuccessful HTTP response or rejected
response format, not a failed gesture. Notices now distinguish authentication,
model access, rate limits/quota, server errors and invalid responses; transport
failures and timeouts are also explicit. Original recognized text is retained.
No exact cause of the reported live failure has been established yet; synthetic
tests verify that release translation reaches Ark even with normal polish off.

Three interactive Delete-hint proposals are in
`Design/Prototypes/delete-gesture-hints.html`; they do not change the keyboard's
current Delete behavior. The recommended option reveals a leftward cue beside
Delete only after a hold.

Validation: 270 unit/integration checks passed, plus a new Emoji entry/Back haptic
check and a rerun of the interactive motion test with five captured intermediate
frames. Three installed-extension simulator touch tests passed: Emoji round trips,
pinch/reopen/typing, and symbol shortcuts/Return hold. Physical haptic feel and
live translation remain unverified while the Duo's Wi-Fi XCTest channel fails
with exit 74; this is not evidence of an unanswered permission prompt.
The personal-signed build passed strict signature verification and was installed
on the Duo without uninstalling or erasing app data.

## Language-key keyboard picker — 2026-11-22

Tap Language to switch Chinese/English; hold it to open Apple's list of enabled
keyboards. Fixed the old delayed-event path that switched straight to the next
keyboard after a hold. UIKit now receives the original direct-touch sequence from
the beginning; its short-tap advance is suppressed only during the local language
key event. Gap dictation and release-over-Language translation remain separate.

The installed-extension simulator touch test verified two short taps, the native
picker appearing on hold, and choosing English (US) to activate Apple's keyboard.
All 17 dictation-gesture regressions passed. Device automation remains blocked by
runner error 74, so this is not a physical gesture verification.

## Keyboard refinements — 2026-11-22

Chinese letters give the old period key's width to Space; periods remain in the
symbol palette and double-Space shortcut. The shortcut pill/menu and gesture pill
are removed. Symbol pages show Clipboard History, newly copied Code when available,
1Password and Messages directly in the candidate strip. Phone and standalone Paste
are removed. Holding Enter inserts a line break without invoking Send/Search.

Full ↔ mini pinch motion follows finger separation continuously, including reversal,
and settles after release. Only the completed mode is remembered. Shared key faces
keep their legends at native size, and Reduce Motion uses a fade. Emoji has one
pill-backed Back button and a gradient at its bottom edge; hold Language on the
letter keyboard to open the system input-method picker.

This section supersedes the older pill, period-key and mode-animation notes below.

Validation: 266 unit/integration checks passed, then all 14 motion tests passed
after adding two-thumb-drift replay coverage. Three installed-extension simulator
touch tests passed: emoji round trips, pinch/reopen/typing, and symbol shortcuts
plus Return hold. The emoji mask/back-button screenshot was visually checked.
The personal-signed build was installed on the Duo without uninstalling or erasing
data. Physical regression remains pending while the Duo automation runner fails before
establishing its IDE channel (exit 74); simulator evidence is not physical QA.

## Direct keyboard dictation — 2026-11-22

The keyboard now captures speech on demand through a bundled, nonpersistent WebKit
view and runs Seed streaming/refinement and Ark polishing in the extension. Open
vvhisper once after upgrading to migrate existing keys and grant microphone access;
then holds work without opening the main app. Full Access remains required.

The app no longer keeps an idle microphone or background audio session. The old
Keep Dictation Ready setting and automatic app-return experiment are removed.
No credentials or text enter the WebKit page: it sends UUID-tagged PCM and RMS to
native code. Native Keychain sharing preserves the separate Seed/Ark credentials.
Existing text ownership, cancellation, translation and submit gestures remain.

WebKit capture is platform-dependent behavior, not an Apple-guaranteed keyboard
capability. This section supersedes historical activation/return/readiness notes
below. Validation on 2026-11-22: 265 simulator tests passed, the bundled JavaScript
lifecycle checks passed, and the signed build was installed on the Duo without
uninstalling. The user subsequently confirmed that direct dictation works on the Duo without
opening the host. This is user verification; media-route and termination tests
still need separate physical checks.
Capture lifecycle tests: `node scripts/test-web-capture.mjs`; Swift session tests:
`KeyboardVoiceSessionTests` in the existing iOS test scheme.

Technique reference: [ios-keyboard-dictation](https://github.com/stephancill/ios-keyboard-dictation/tree/c86b6cf54fae774a3c98ecedc163e204923db9e5),
with MIT attribution in `Dictation/WebAudioCapture-NOTICE.txt`.


### Media mixing, editing pills and iPad layout — 2026-11-20

The ready microphone now uses normal audio mode with mixing and Bluetooth stereo
output. Measurement mode was lowering other apps' playback levels; no system volume
is changed and no ducking is requested. Empty recognition finishes without a notice.

The left shortcut pill expands to Paste, newly copied Code, 1Password, Messages and
Phone, and Clipboard History. Phone and Messages only open an app;
they never populate a recipient or make a call. iOS may reject the empty Phone URL,
in which case the shortcut asks you to open Phone manually.

The right editing pill owns left/right word delete/restore, down for a line break,
and up for end-of-text. Ordinary keys no longer interpret editing swipes. Space
trackpad, held Delete, pinch and dictation slides retain their separate behavior.
Double-Space inserts `. ` in English or `。` in Chinese. Chinese full letters now
include a dedicated `。` key.

iPad support shares the app, extension and settings. At >=600 points it uses a
continuous five-row layout with a number row, Tab, wider Return and arrow keys.
Narrow windows fall back to the phone layout; mini keeps its single row. The minimum
OS remains 27.0. The installed 27.1 simulator runtime supports only the Duo, so
actual iPad launch is pending a compatible runtime/device; UIKit layout tests cover
744/834/1194/1366-point widths. Device media playback and app shortcuts remain
unverified while hardware is disconnected.

Validation: 241 iOS tests passed, followed by 10 focused pill tests and nine
candidate/tablet regressions after final refinements. The signed device build passes
strict signature verification and declares both iPhone and iPad device families.
This records source/build/test coverage, not installation or physical acceptance.

### Compact keyboard and emoji — 2026-11-20

Mini mode is now one row: **Expand · Dictate · Delete Word · Enter**. Expand or
pinch out restores full letters. Mini Delete removes one word per tap/repeat,
including Chinese word boundaries; full-mode Delete remains character-based.
The language key is absent from mini, so release-to-translate is full-mode only.

Light-mode voice feedback now uses white fill and a soft white halo; it never
pulses black ink over the caps. Dark mode retains its white level response.

The smiley opens a local emoji panel with nine categories, skin tones, ABC,
Delete and a system globe. Unicode Emoji 16.0 data and its license are bundled.
Emoji insert literally, and no emoji history is saved or sent over the network.

A dictation slide into Enter now requests Return only when the final host field
advertises **Send**. Other fields keep the finalized text without a newline and
show “Text ready. Tap Send in the app.” iOS exposes no universal send-message API;
the host still owns what its advertised Send action does. Ordinary Enter taps
retain normal host behavior. Earlier build notes below describe historical behavior.

Validation: all 238 iOS tests passed. The signed device build passed strict signature
verification. Native test renders cover the single-row mini layout in portrait and
landscape, light and dark, plus quiet/soft/strong voice feedback. The Duo was disconnected,
so installation, live emoji interaction and Send behavior in third-party apps remain
unverified for this build. Duo-specific floating-keyboard support is also unconfirmed.

### Sentence Punctuation — 2026-11-19

**Voice Input → Sentence Punctuation** defaults on, independently of polishing.
It controls the final ending of one short dictated sentence: On retains an existing
ending or adds a period (`。` when Han is present); Off removes its terminal sentence
punctuation, including before closing quotes/brackets. Interior punctuation stays.
The limit is 120 Unicode scalars and 20 words, or 40 scalars when Han is present.
Longer passages, multiple sentences/lines, URLs, email addresses and ambiguous dotted
text such as abbreviations remain unchanged; decimal points are preserved.

The host captures this choice at hold start and applies it after optional polishing,
including disabled, failed or interrupted polishing. It does not alter streaming
drafts or normal keyboard typing, and does not make a separate network request.
The helper and shared behavioral fixtures match the Mac implementation.

Validation: all 220 iOS tests passed, including the shared fixtures, independent
setting persistence, per-hold values and final output after successful/disabled/failed
polishing. The signed build passed strict signature verification and was installed on the
Duo without uninstalling. The toggle defaulted On, persisted Off after reopening
settings, and was restored to On. Live spoken dictation was not retested for this
change; output behavior has the shared fixture and polishing-path test coverage.

### Typing assistance — 2026-11-19

English offers local spelling corrections in the candidate strip and applies close
corrections when finishing a word. Immediate Delete restores the original spelling;
it will not correct that same word again. Known product/design terms, Pinyin, acronyms,
URL/email/numeric fields, hidden context and the host's autocorrection preference are
protected. Suggestions only own letters entered through this keyboard, never pasted
or dictated text. Missing system spelling data leaves text unchanged except for a
small set of common slips. Joined words can be split when the system suggests them.

Chinese Pinyin tests bounded single-slip repairs (adjacent transpositions, repeated
letters and nearby keys) against the existing Rime dictionary. Only complete Chinese
results appear, and exact Pinyin retains its existing ranking. Typo suggestions commit
through the same tap/Space path; the raw spelling stays marked until then. This does
not guess a different word for a valid but unintended Pinyin spelling.

**Keyboard → Typing Assistance** has independent, default-on English Auto-Correction
and Smart Spacing controls. Smart spacing adds a space after selecting an English
candidate and after English punctuation; a redundant Space is consumed and subsequent
punctuation replaces only the keyboard's own trailing space. Directly typed dots stay
unspaced for domains/decimals. Chinese characters remain unspaced. All processing is
local, with no typed-text logging, network calls or persistent learning.

Validation: 213 simulator tests passed across typing, Pinyin phrase ranking,
gestures, haptics and dictation. Targeted keyboard checks also cover correction
undo, settings, delayed editor acknowledgements and nil empty proxy contexts.
The animation build was installed on the Duo on November 19; physical full/mini
hold tests verified legend hide/restore, quiet strip and pinch transitions.
The acoustic test returned no recognized speech, so live amplitude sensitivity
remains unverified. See `build/verification/quiet-keys-device-nov19.json`.

The final signed typing build was installed without uninstalling. All 23 targeted
checks passed after the final proxy/settings fixes. On the physical Duo, `teh`
offered **the**, Space committed it, and Delete restored `teh`; `wozhdiao` offered
**我知道** first and Space committed it. Typing `hello,` followed by an explicit
Space and `world` produced exactly `hello, world`. The new settings page showed
both controls enabled. Synthetic test text was cleared and Chinese mode restored.
See `build/verification/typing-assistance-device-check.json`.

### Edge taps and thumb movement — 2026-11-18

A brief finger drift no longer cancels a tap before reaching the swipe threshold.
Movement of 14 points stops a pending hold; intentional left/right swipes still
require 36 points and down requires 28. A large unsupported movement cancels the
press. Existing dictation, cursor and delete holds keep their established behavior.

A separate physical comparison found an iOS-hosted boundary: the Duo outer display
is 466 points wide, but the extension receives a 452-point hosted window, leaving
about 7 points at each side outside its input surface. At 5.6 points from either
screen edge, Apple accepted Q/P/A/L while vvhisper received none; at 9.3 points,
vvhisper accepted all four. Enlarging key hit targets inside the extension cannot
capture touches outside that window. Apple documents that the system determines
custom keyboard width. Geometry-only temporary diagnostics were removed after the
measurement; no new runtime probes or private API were retained.

Validation: 181 unit tests passed. The signed build was installed without
uninstalling. On the real Duo, 18.6-point inward drifts that previously dropped
Q/P now committed Q/P/A/L, and Shift, Delete and symbol/alphabet switching worked.
Deliberate word deletion, restoration and line separators were also verified.
The simulator coordinate UI test failed its first baseline center-key tap before
reaching the new checks; it is not counted as passing. See
`build/verification/edge-tap-device-comparison.json` for evidence and limits.

### Text polishing — 2026-11-19

After final Seed recognition, a separate Volcengine Ark language-model request corrects
grammar/spelling and natural phrasing. It sends only the transcript and editing
instructions: no tools or editor context. The prompt preserves meaning, tone,
uncertainty, negations, names, numbers, facts and mixed languages, and never answers
questions or follows instructions contained in the transcript.

Open **Voice Input → Polish Dictation**. The toggle defaults on; add a **Volcengine
Ark API Key** on this iPhone. The fixed model is Seed 2.0 Mini
(`doubao-seed-2-0-mini-260428`), with thinking disabled. Requests use
`https://ark.cn-beijing.volces.com/api/v3/chat/completions`. The key is stored in a
separate host-only, device-only Keychain item. ASR keys and existing OpenRouter
keys/models are never reused. Mac credentials are not copied and the extension never reads them.
Only subsequent holds use changed settings. Without a key, dictation keeps the
recognized text and shows a setup notice; provider/model charges may apply once configured.

The recognized draft stays marked during the text-only pass. A complete, valid
JSON text response replaces it; disabled/missing setup, network failure, a 15 s
resource timeout, empty/truncated/invalid responses all preserve recognized text.
The keyboard allows 25 s for final ASR plus polishing. Edits, field/caret changes,
cancellation and new holds invalidate stale replacement/submission. Slide-to-cancel
still restores the selection displaced by that hold. No transcripts, keys or
provider bodies are logged. iOS host apps control marked-text appearance; the
extension cannot guarantee a visible underline in every app and never changes
document underline formatting. Live provider verification requires a configured key.

The November 19 underline fix was checked through the real keyboard extension on
the Duo: a synthetic draft remains marked while pending, final text replaces it,
and the visible blue underline clears. This checks editor delivery, not provider
latency. Real proxies can exclude marked text from their context; final text is
committed with `insertText` rather than another `setMarkedText` followed by unmarking.
The follow-up empty-field cancellation fix was checked on the Duo with English
and Chinese drafts from empty fields, plus the prefilled-field case. All three
synthetic flows completed and cleared the visible underline. The 227-test suite
also covers nil surrounding context for an owned draft and rejection of changed
documents or hidden context in a previously nonempty field.

### Release to translate — 2026-11-19

While dictating, slide onto the language key and release to translate: Chinese
speech becomes English, and English speech becomes Simplified Chinese. The key
highlights indigo while targeted; slide away to keep the original language.
This works in full mode without switching the typing language or sending
the text. Mini no longer has a language key. Polishing and translation share one Ark request and the existing key.
The gesture works with automatic polishing off; failures retain the transcript.
Validation: 232 tests passed, including full/mini layouts, release-only translation,
slide-away, cancel/send precedence, changed fields and stale completions. Synthetic
live Ark requests returned valid English and Chinese output in about 1.1–1.2 s.
The signed build was installed on the Duo; silent physical drags verified indigo
hover feedback in full and mini mode and disarming on exit. A spoken end-to-end
translation on the phone remains to be checked.

### Quiet Keys — from the center — 2026-11-18

The approved [Quiet Keys A](Design/Prototypes/quiet-keys.html) is implemented natively.
Text legends fade out together on hold; a group of neutral key fills responds from
the center and widens with speech. The host supplies a short-lived volume scalar
from the existing microphone stream, never raw audio. Silence fades the field away;
release restores legends without a polishing animation. The candidate strip stays
empty through recording and refinement. Mini uses a soft fill inside Dictate with
the same quiet response on its function keys. Both appearances and Reduce Motion are
supported. See the [motion specification](Design/Prototypes/QUIET_KEYS.md).

The visibility refinement uses a 6% noise gate with a square-root response for
softer speech, 35 ms attack and 140 ms release. Light mode now uses up to 90%
white fill and a 6-point white halo; dark mode uses up to 32% white. Opacity tracks
volume, with no black pulses in light appearance.
Mini uses the same response inside Dictate. Reduce Motion retains a stationary,
lower-contrast indication. Microphone/ASR gain and the quiet candidate strip are unchanged.
The refinement passed 193 tests, including softer-speech response and unchanged
layout/session guards. Full/mini light/dark renders were inspected, and the signed
build was installed on the Duo. Live speech sensitivity still needs an in-hand check.

The molecule renderer is removed from the app and keyboard; the studies below are
historical references. Streaming and final replacement remain in the host text field.

Validation: 180 simulator tests passed, including stale/future/session checks,
RMS bounds, silence, attack/release, Reduce Motion, cancellation, final replacement
and full/mini geometry across five layouts. The signed final Debug build passed
strict signature verification and was installed on the Duo without uninstalling.
Physical light-mode checks covered full and mini holds, legend fade/restore,
center response, quiet strip, and pinch transitions. The on-device comparison led
to reducing the light base shade to 3.5% so keycaps remain visible against the
system backdrop. Dark, reduced-motion and other geometries have simulator/model
coverage; they were not rechecked physically in this iteration. Artifacts and
install hashes are under `build/verification/quiet-keys-*`.

### Previous molecule dictation animation (superseded) — 2026-11-18

The earlier [molecule study](Design/Prototypes/README.md) ran in UIKit before Quiet Keys replaced it.
Visible streaming text builds a monochrome field from the center: four particles
per Chinese (Han) character, one per other letter/digit, ignoring spaces and
punctuation. Silence adds none; corrections adjust the count, with a width-based
safety cap of at most 320. The cloud occupies a shallow central band with more
clearance from the top edge and keys. Release sends every molecule directly from
its current position to the top-center opening in 330 ms, with no gathering stage.
The transcript stays in the host text field; final polishing replaces it immediately,
even when the visual sequence has not finished.

Full mode uses the candidate strip. Mini mode keeps the entire animation inside
the Dictate key and its rounded corners, scaling density and the receiving opening
for the smaller space. The canvas receives no touches. Cancelling, changing the
layout or dismissing the keyboard clears it. Idle, detached and waiting-for-final
states do not run display frames. Reduce Motion uses stationary molecules.

Validation of the weighted-text revision: all 179 simulator tests pass. Coverage
checks Chinese/English grapheme weights, silence and transcript corrections, the
shallow listening band, immediate departure from existing positions, bounded density,
Reduce Motion, immediate final-text insertion, stale-session rejection, cancellation
and clipped mini geometry across five layouts.
Native light/dark full/mini listening and send renders were reviewed in
`build/verification/molecules-stream-count-layouts.png`.
The signed Debug app and keyboard passed strict signature verification under
Q9MD524YL5 and were installed on the Duo without uninstalling. The phone's UI
automation channel still fails to establish (exit 74), so launch, physical
dictation smoothness and battery behavior remain unverified. The weighted-text,
direct-flight revision was also signed, verified and installed on the Duo without
uninstalling on 2026-11-18.

### Key gaps and Chinese candidate browsing

Every gap within the keys belongs to the nearest key in its row, including staggered-row
insets and the split keyboard's center. The whole area left of A types A; the
whole area right of L types L, including the top and bottom corners of that row.
Tap to type; hold a gap to dictate. Keycap
sizes and positions stay the same. The candidate panel and the system-owned area
remain separate from key targeting.

The installed-extension touch test reproduced a failure that local hit-test tests
missed: completely transparent gaps never received a touch event. The touch
surface now has an imperceptible background fill so iOS forwards those events,
while the system keyboard backdrop remains visible.

Chinese candidates follow the [iPhone candidate-list interaction](https://support.apple.com/en-ie/guide/iphone/iph3c50f96e/27/ios/27):
swipe horizontally to browse, or use the right-hand chevron to expand a vertically
scrolling list over the letter rows. Choices keep their natural text widths; the
first stays highlighted and Space accepts it. Selecting a choice collapses the
panel. More candidates load on demand without changing inline composition or
resetting scroll position. This uses our Rime dictionary, not Apple's private IME.

Validation (2026-11-18): all 156 simulator regression tests pass, plus an installed
extension UI test that sends 61 coordinate taps and checks the editor after each.
It covers both sides of every horizontal letter gap, vertical row gaps, and the
outer A/L areas. The regression suite also covers full/mini/symbol/split layouts,
wide-gap tap and hold behavior, later
Rime candidate selection, stable Space commits, stale-result rejection, scrolling,
expansion and composition cleanup. Collapsed/expanded view renders were inspected.
The signed Debug app and keyboard extension passed strict signature verification
under Q9MD524YL5 and were installed on the Duo over Wi-Fi without uninstalling.
Physical gesture and visual comparison remain unverified because the phone's
XCTest connection still fails to start, including with Xcode 27.2.


### Haptics and editing swipes

Settings → Haptics now separates **Strength** from **Sharpness** (soft to crisp).
Both have 1% slider/stepper adjustments and a **Test Tap** preview. Strength zero
turns haptics off. The app and keyboard use the same short haptic transient, with
UIKit feedback as a fallback when the custom engine is unavailable.
Rapid taps now use eight prewarmed players, with each reserved until its pulse
finishes, so two-thumb bursts cannot restart an unfinished pulse. Engine restart
and completion callbacks are generation/token guarded; no late feedback is queued.
The rapid-playback, retirement, failure, dismissal and Off regressions pass as
part of the 188-test iOS suite. Debug's explicit `--verify-haptics` fixture checks
80 requests at 40 ms intervals in the real extension and exports only counts,
timing and error codes to `Documents/haptic-device-check.json`. API completion
does not measure how each pulse feels in the hand.
The signed build was installed on the Duo on 2026-11-18. The real keyboard
extension completed all 80 requests in 3.201 seconds with 80 custom starts,
80 completions, zero fallbacks and no reported errors. Evidence is in
`build/verification/rapid-haptics-device-check.json`.

A follow-up found a separate input-routing omission: stationary two-thumb chords
replayed their letters without requesting any feedback. Ordinary keys now pulse
on accepted finger-down; the pinch handler acknowledges any fingers intercepted
before key tracking, and text replay/release adds no duplicate pulse. VoiceOver
activation still gets one pulse. Strength and Sharpness retain their saved values.
The new overlap regressions reproduced zero feedback before the fix and cover
staggered thumbs, simultaneous same-key touches, ordinary rollover and cancellation.
For device QA, `--verify-haptics --observe-haptic-touches` observes 24 externally
driven touches in the synthetic field instead of generating haptics directly.
All 192 tests pass. The updated signed build was installed on the Duo; twelve
physical two-finger taps produced 24 haptic requests, starts and completions,
with zero fallbacks or errors (`build/verification/haptic-touch-device-check.json`).
This covers event delivery and playback callbacks; subjective feel remains manual.

Before a hold starts, swipe **left** to delete the preceding word, **right** to
restore a swipe-deleted word, or **down** for a line break. Down inserts Unicode
LINE SEPARATOR directly instead of invoking Return/Send; a host may restrict which
line separators it supports. Pinyin commits before the edit. Restore is limited
to the current field and uninterrupted editing session; deleted text stays only
in memory. Existing dictation, held-Space cursor control, symbol alternatives and
held-delete gestures retain their behavior. The mini Dictate button is reserved
for voice and two-finger mode pinches; one-finger editing swipes start on its other keys.

Paste, Paste Code and 1Password use plain icon buttons without a background.
Explicit Paste may ask for clipboard permission.

Validation (2026-11-17): all 141 tests pass, including word boundaries, consecutive
restore, delayed proxy acknowledgements, field-change guards, gesture conflicts,
Pinyin commitment, fine haptic settings and transparent helper buttons. Signed
Debug and Release builds pass strict app/extension signature verification; Debug
verification hooks are absent from Release. Debug was installed on the Duo without
removing app data, and the main Settings page was launched. The explicit synthetic
device check confirmed custom haptic playback in the extension and the existing
5.5-second Space-hold cursor regression. This confirms playback, not perceived
haptic quality or physical swipe feel. Those checks remain manual while the
screen-control runner is blocked by the Xcode/iOS mismatch. Owned temporary
DerivedData was removed and the pre-existing simulator returned to Shutdown.

### Space-hold cursor movement

Hold Space briefly until the haptic, then drag to move the cursor. Horizontal
distance moves through whole characters (including Chinese, emoji and accents);
vertical distance moves between explicit text lines while retaining the column.
Release to stop; there is no momentum or extra space. This works in full,
symbol and split layouts. A normal Space tap still inserts a space or accepts the
first Chinese candidate. Starting a cursor hold also accepts that candidate before
moving, without adding a trailing space. Holds starting in a gap still dictate.

Movement uses [Apple's public text proxy](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards).
The host provides text context rather than visual caret/line geometry, so vertical
movement follows available newline boundaries, not automatic visual wrapping.
No microphone session or Full Access is needed for cursor movement. Cursor commands
wait for the host's acknowledgement, so delayed context updates, changing context
windows and an empty side at a document boundary do not end a held gesture.

Validation (2026-11-17): all 141 simulator tests pass. The cursor checks cover
distance/reversal, fractional split-key coordinates, boundaries, Chinese/emoji/
accented characters, delayed proxy acknowledgements, document-edge nil context,
context-window refresh, explicit-line movement, Pinyin commitment, both split Space
keys, mini/symbol layouts, stale paste/polish rejection and gesture cancellation.
The cursor update's signed Debug and Release app/extension passed strict signature verification
under personal team Q9MD524YL5. Debug was installed without uninstalling on
iPhone[marcus] (Duo, `00008160-000934DA0C200036`). Its explicit synthetic
`--verify-cursor` check exercised the real extension-to-host proxy: move two
characters, remain held at 4.5 seconds, move one more, release at 5.5 seconds.
The expected caret and unchanged text were verified. The immediate-snapshot
comparison also passed; the user's physical-touch cancellation was not reproduced.
Screen-control QA is blocked because the iOS 27.2.1 device's automation runner
fails with the installed Xcode 27.1. This self-check is not a physical finger test.
Debug verification commands are absent from Release. The pre-existing simulator
was returned to Shutdown, and temporary test/build DerivedData was removed.

### Mini mode and easy input

**Pinch in** for mini mode, or **pinch out** to restore the full keyboard. This
replaces the two-finger up/down swipe. The switch happens during the pinch,
without waiting for your fingers to lift. Horizontal, vertical and diagonal
pinches work, including keeping one finger anchored. Moving both fingers together
does not switch modes. A second finger can land up to 250 ms later.
The last full/mini selection is remembered when you
dismiss, switch away from, or restart the keyboard, including without Full Access.
The keyboard scales slightly with your fingers, then resizes
and fades into the selected mode; Reduce Motion uses a brief fade. Mini mode's top
and side padding match, with at least 8 points of space. Mini is a single row:
Expand, Dictate, Delete Word, Enter. Hold Dictate to speak, release to finish,
slide to Delete to cancel, or Enter to finish and request Send where supported.
Dictate waits a quarter-second for a second finger before starting voice; a shorter
tap does nothing. Expand returns to full letters. Entering mini mode commits the
highlighted Chinese candidate first.
VoiceOver offers Mini Keyboard on Space and Full Keyboard on Dictate.

The pinch update passes 159 regression tests and an installed-extension simulator
UI test: pinch in, reopen with mini remembered, pinch out, then type a character.
Both fingers can start on one wide key; close starting fingers are accepted while
small jitter is ignored. The test verifies no stray characters during switching.
The signed Debug update was installed on the Duo with app data preserved. Physical
gesture feel remains unverified; the device was locked during this verification.

The earlier swipe-based, remembered-mode update passed all 148 tests, including
short diagonal swipes, staggered fingers, one-shot recognition, stationary/pinch
rejection, dismissal and controller recreation, saved full-mode restoration, and
two fingers on Dictate without voice activation. The signed Debug app and keyboard
pass strict signature verification. Installed on the Duo with app data preserved;
Try Keyboard was launched. Physical gesture feel remains unverified because the
screen-control runner is blocked by the Xcode/iOS mismatch. Temporary build/test
DerivedData was removed; both pre-existing Duo simulators are Shutdown.

The earlier swipe-based mini-mode follow-up passed all 128 tests, including unequal finger travel,
diagonal swipes, rejection of stationary/opposing movement, equal top/side padding
at five sizes, animated reversal, dismissal cleanup and Reduce Motion. Native
light/dark mini-layout renders were reviewed in `build/verification/mini-padding.png`.
The final clipping change also passed the eight mini-mode tests. The signed Debug
update was installed on the Duo with app data preserved and the test page launched.
Physical two-finger feel remains unverified while the Duo's screen-control runner
is blocked by the Xcode/iOS mismatch.

Chinese symbol pages now use **，。？！：；（）【】「」**, with Latin alternatives on
hold. English and URL/email fields retain ASCII punctuation. Paste preserves the
original text exactly.

The empty candidate strip provides right-aligned, icon-only **Paste** and **Open
1Password**, with a monochrome 1Password mark and accessible action labels.
All helper artwork fits the same 20-point image box inside a 44-point control.
Paste extracts a copied code when the host marks its field as a verification
code field. **Paste Code** appears only when a new clipboard version contains one
unambiguous code. It disappears after use, clipboard replacement, or two minutes.
The visible, idle keyboard checks version metadata and inspects each new version
once; iOS may ask for paste permission. First setup/reboot establishes a baseline
without inspecting old clipboard text. Only version/expiry metadata is saved;
the monitor itself does not save clipboard text. The separately authorized local
history below retains observed text, potentially including copied codes; neither
feature logs contents. This is copied-code detection,
not incoming-SMS access. Opening 1Password is a shortcut: copy an item there,
return to the original app, and paste. It does not embed iOS AutoFill or automatically
return from 1Password. See [Apple's paste control](https://developer.apple.com/documentation/uikit/uipastecontrol)
and [1Password AutoFill](https://support.1password.com/ios-autofill/) for the separate
system-managed flows.

Initial validation (2026-11-17): all 107 simulator tests passed, including mini layouts at
five sizes, two-finger gesture policy, Chinese candidate commitment before
shrinking, dictation cancel/finish, punctuation, copied-code extraction and stale
paste rejection. Native UIKit light/dark renders were reviewed; contact sheets
are in `build/verification/`. The signed arm64 app and keyboard pass strict
signature verification, and both provisioning profiles include the Duo.
The icon strip retains right alignment and accessible action labels.
The 126-test suite covers newly copied-code detection, one read per version,
denied access, expiry, clipboard replacement during a read, single-use pasting,
metadata-only persistence and controller restart/reboot handling.
The copied-code Debug build passed strict signing validation and was installed on
the Duo without removing app data. Its launch was refused because the phone had
locked again; device paste-prompt/UI verification remains pending. Open the
keyboard once to establish its clipboard baseline, then copy a code and return.
Clipboard versions follow Apple's [changeCount](https://developer.apple.com/documentation/uikit/uipasteboard/changecount).
Light/dark icon-strip renders were reviewed. The subsequent combined
cursor build above was installed and launched after the Duo reconnected.
Physical gesture/1Password/paste checks remain for the user. The signed app remains
in `build/vvhisper.app`.

A UIKit app automatically prepares a bounded microphone session when opened (15 minutes by default). A custom
keyboard provides offline Chinese Pinyin + English QWERTY, candidate selection,
shift/caps lock, numbers/symbols, delete, space, return, and keyboard switching. Hold a letter key or a regular gap between keys for 380 ms to dictate;
release to finish. Holding consumes the key instead of inserting its character.
While recording, slide into **Delete** to cancel immediately (red feedback), or
into **Return** to stop recording and send after polishing (blue feedback).
For this gesture, Return is emitted only in a Send field; other fields keep the
final text without a newline and ask the user to send from the app.
Direct holds on Shift, Space, Return, Delete, numbers/symbols and other function
keys never start dictation. Character keys show a raised preview on press, including
their current capitalization or symbol. The preview disappears when dictation
starts. Slide outside the keyboard to cancel and remove this hold's preview. Typing, moving the
cursor or changing fields cancels pending refinement and preserves visible text.

The keyboard uses the iOS 27 Figma reference for key geometry, spacing, typography,
and the system keyboard-switcher artwork, with responsive iPhone / Duo layouts.
The language key sits immediately left of the emoji/system keyboard key. It uses
`character.book.closed`, localized to Chinese or English for the current typing mode.
Tap it to switch between Chinese Pinyin and direct English typing; the selected
mode is remembered locally, including without Full Access.
Chinese mode also suggests recognized English words without changing modes.
Settings → **Experimental → More English Suggestions** additionally favors
capitalized and unfinished English spelling; it is **off by default**. When enabled,
the language key keeps its Chinese symbol, and English mode still types directly.
Candidates use the full strip; errors and polishing status temporarily use that same strip. Recording hides key text and leaves the strip blank. Return occupies the former microphone
position; hold a letter key to dictate. A hold automatically opens the host
when its microphone session needs enabling; an error can offer a retry button. This is not Apple's keyboard and
not full native feature parity: QuickPath, native prediction/autocorrection, emoji
browser are not implemented. Apple's built-in
keyboards remain available through the smiley input-mode key (hold it for the system keyboard list). Chinese/English speech works
through Seed, independently of the typed keyboard layout.

## Chinese and English typing

Chinese mode uses Rime's offline Simplified Chinese Pinyin engine with
Rime Ice's character, base, extended and Tencent phrase dictionaries (1,872,937
source entries, before compilation/deduplication), plus 101 authored design
glossary entries such as **走查**, **视觉还原**, **组件变体** and **触控热区**.
The expanded source includes names such as **迪丽热巴** and **赵露思**.
Upstream word frequencies and phrase segmentation determine the Chinese order;
the local glossary is imported last to preserve existing weights.
`wozhidaole` offers **我知道了** first.
Type `nihao`, then choose **你好** or press Space to accept it. Space always follows
the highlighted first choice. Chinese mode also offers recognized English words:
unambiguous English such as `design`, `layout` and `figma` leads the row, while
spellings that are also valid Pinyin, such as `can`, keep Chinese first and offer
English alongside it. Recognition uses the local system dictionary and 277 bundled
common/design English hints. Non-Pinyin prefixes can offer up to two completions.
Space accepts a highlighted English word with a trailing space; tapping accepts
the word alone. Raw Pinyin such as `haode` stays in
the inline composition and is omitted from the candidate row when Chinese
candidates exist; Return can still accept the Latin spelling. If there are no
Chinese choices, the spelling remains a fallback. Swipe the row for more
candidates horizontally. Tap the downward chevron or swipe down from the strip
to expand a wrapping, scrollable candidate panel. The chevron has a 56-point-wide,
full-strip touch target and points upward when expanded. Expansion uses a short slide and fade;
Reduce Motion uses a fade only. Pulling never commits a word, and bottom-row
controls remain available.
Shift changes capitalization without
changing languages. Return accepts unfinished Pinyin as Latin spelling; a second Return
performs the editor's normal return action. Backspace edits the pending composition
before deleting document text.

English mode inserts letters directly into the field, with ordinary Space,
Return and Delete behavior and no Chinese composition or candidate suggestions.
Switching modes preserves unfinished visible spelling and returns to the letter
layout. Keystrokes queued behind a Pinyin edit stay in order across the switch.
The typing mode does not change Seed's speech-language recognition.

The optional More English Suggestions experiment uses a broader English policy.
Recognized English words, unconverted Latin
spelling and capitalized words can lead the row; Space accepts that English word
with a trailing space. Tapping the candidate accepts the word alone. Chinese
phrases such as `haode` keep **好的** first without a redundant raw-spelling choice.
Changing the setting applies to the next composition, preserving the current
word and queued taps. Existing haptic settings survive the preference upgrade.

Pending Pinyin appears as marked text in the host field using UITextDocumentProxy.
Choosing a candidate replaces that spelling; Backspace updates the marked range.
Changing the field/selection or
dismissing the keyboard abandons candidate state and preserves the visible spelling. Finish a typed
composition before starting a voice hold. Typing does not need Full Access, a Seed
key, a running host voice session, or a network connection; voice keeps its existing
requirements. No typed text is logged or stored in a learning database.

References: [Hamster](https://github.com/imfuxiao/Hamster) and
[Cantoboard](https://github.com/Cantoboard/Cantoboard). The bundled engine is
[Rime](https://github.com/rime/librime), with the GPL-3.0
[Rime Ice dictionaries](https://github.com/iDvel/rime-ice).
See [third-party notices](THIRD_PARTY_NOTICES.md) for pinned versions and licenses.

## App icon

The iOS target compiles `../macos/vvhisper.icon` directly, sharing the updated
Figma balloon and voice bars with macOS. Edit that Icon Composer source to keep
both platforms in sync; no separate flattened iOS icon needs regeneration.

## Build and install

Requires Xcode 27+, XcodeGen (`brew install xcodegen`) and the signed-in personal
Apple Developer team Q9MD524YL5. The app/keyboard require a provisioned App Group,
`group.com.vvhisper.ios`. Generated Xcode projects and build outputs are ignored.

```sh
./build.sh
xcrun devicectl device install app --device YOUR_UDID build/vvhisper.app
./test.sh
# Coordinate taps against the installed extension; use a dedicated simulator.
IOS_TEST_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' ./test-touches.sh
```

The build and test scripts fetch a pinned, SHA-256-verified Rime XCFramework into
`build/dependencies/`; it is not downloaded by the running keyboard. They own
temporary DerivedData and remove it on exit. A
completed device build stays at `build/vvhisper.app`. `./build.sh
CODE_SIGNING_ALLOWED=NO` performs a compile check, not an installable signed build.
Dictionary compilation also stages `build/resources/Rime/` with just the compiled
tables, syllables and notices; source YAML stays in the repository. Never compile
or download dictionaries inside the keyboard extension.

## Set up

1. Open vvhisper and save a Seed API key.
2. Settings → General → Keyboard → Keyboards → Add New Keyboard → vvhisper.
   Enable Allow Full Access for its app-container communication.
3. Open vvhisper and grant microphone permission. Voice input prepares automatically;
   there is no enable/disable button.
4. Open **Try Keyboard** to test in its separate page, or return to your editor,
   select vvhisper with the input-mode key, and hold a letter key.

The main page uses native grouped settings for voice readiness, the Seed API key,
keyboard setup and haptic strength. **Try Keyboard** has its own editor that resizes
above the keyboard. Voice sessions stop on audio interruption, engine failure or
at the selected duration; reopening vvhisper prepares a new session. Idle audio is discarded.
**Voice Input → Keep Dictation Ready** offers 1, 5, 10, 15, 30 or 60 minutes,
counted from microphone activation. Holds do not extend it. Changing the setting
updates the current session's deadline, and expiry stops capture even during a hold.

Holding a key while the host is not ready creates a nonce-bound, ten-second App
Group activation request and opens `vvhisper://voice` through SwiftUI's public
`OpenURLAction`. The host consumes the matching request and enables its microphone.
An accepted URL alone is never considered readiness. Full Access, a saved Seed
key and microphone permission are still required. If iOS refuses to open the app,
the keyboard offers a retry or the user can open vvhisper manually.

The user authorized a **Debug-only local MVP** experiment for automatic return.
The containing app observes UIKit's transient keyboard source identity from launch,
accepts only events received after the current activation request, and attempts one
return after capture readiness and foreground activation. Old destinations, self,
malformed identifiers, expired requests and cancelled scene transitions are rejected.
The private API path is omitted from Release. This is not an App Store-ready approach.
Physical verification of the new containing-app observer is pending.

App switching cancels the original touch. After returning, hold a letter key again to
speak; activation itself never submits speech or inserts a character. A ready
microphone session uses the existing in-place dictation path without another jump.

## Recognition and privacy

The host ports the Mac's Seed binary framing and serial WebSocket session: 16 kHz
mono PCM in 200 ms packets to `bigmodel_async`, plus `bigmodel_nostream` refinement.
Stable partials appear directly in the focused editor as one marked-text span,
using the Mac's agreed-prefix growth rule. The keyboard shows only Listening / Polishing
status. After release, the refined text replaces that span and is committed;
surrounding text is preserved. A five-second refinement timeout falls back to live results. Results are
bound to a session UUID and an unchanged document/context, and expire. No audio is
written to disk. Keys stay in the host's Keychain, inaccessible to the extension.
Duplicate/out-of-order replies cannot insert again. User edits, cursor movement,
field changes and keyboard dismissal stop pending replacements. Explicit gesture
cancellation restores any selection displaced by the preview; failures/timeouts
keep the already-visible preview. Candidate widths follow their text with eight
points of padding on each side, preserving the first-choice highlight.

A Debug-only `Documents/seed-development.json` import supports local device setup
with `apiKey` and optional legacy `appID`. It is consumed into Keychain on launch
and immediately deleted; never place this file in the repo or app bundle.

## Validation boundaries

Compilation does not establish background recording, keyboard activation,
app-to-keyboard IPC, Seed service access or final insertion on a physical phone.
Record actual device checks here as they are completed. App Store acceptance is
not part of this local prototype build.

## Local checks — 2026-11-16

- Signed arm64 build and embedded keyboard verified with team Q9MD524YL5.
- Installed on the selected iPhone Duo (`iPhone[marcus]`, iOS 27.2).
- Four simulator unit tests passed (tap/hold exclusion, cancellation, Seed framing,
  readiness expiry). These are not proof of a real voice-input round trip.
- The moved macOS package passed 392 tests (one skipped), strict concurrency build,
  shell syntax, entitlements lint and update-tool tests.

Physical-device acceptance on iPhone Duo / iOS 27.2:

- Keyboard and Full Access enabled; Settings needed a relaunch to refresh its
  cached extension list after installation.
- Ordinary key taps inserted text; a real user-spoken hold produced a Seed
  transcript and inserted it on release in the app’s test field.
- With the host backgrounded, the keyboard in Settings search showed a fresh
  ready heartbeat (published only while the audio engine is running).
- With capture stopped, tapping the keyboard’s SwiftUI enable link from Settings
  opened the host and started capture. The explicit Stop control stopped it.
- The Mac speaker-to-phone synthetic test produced no recognized speech; it is
  not counted as audio validation. The real spoken test above is the evidence.
- Remaining: a spoken round trip in other apps, longer holds, interruptions,
  Chinese/mixed-language accuracy, selection changes during recognition and
  extended battery/lifecycle testing. Native keyboard feature parity remains
  outside what this first prototype has implemented.

## Bilingual typing checks — 2026-11-16

The dated records below describe earlier builds. The explicit typing modes added
on 2026-11-17 supersede their mixed-language candidate behavior and switch removal.

Nine simulator tests passed: five against the real bundled Rime engine/dictionary,
plus all four existing voice/IPC model tests. Device UI acceptance is recorded
separately after installation; this does not establish Apple keyboard feature parity.

Physical iPhone Duo / iOS 27.2 checks for this build:

- Signed bundle installed as an update, preserving the existing app data and keyboard setup.
- With voice capture off, screen taps composed `nihao`; selecting 你好 inserted Chinese.
- The same bilingual keyboard composed `soundcore`; selecting its spelling inserted English.
- Backspace changed pending `nihao` to `niha` without deleting the document text.
- Space accepted the Chinese candidate. English-only mode typed `hello` directly.
- Final test field value: `你好 soundcore 你好 hello` (read back from the actual text field).
- Holding a key with voice disabled showed the existing enable-voice message and inserted no letter.
- Left in 中/En mode, voice off. No speech was submitted for this typing check.
- Candidate paging is engine-tested; cross-app composition/selection lifecycle and full long-form
  typing quality remain to be tested. No native autocorrection/QuickPath parity is claimed.

## Inline composition and crash correction — 2026-11-16

Device crash reports confirmed SIGABRT in `buildKeys`: equal-width constraints were
activated before sibling keys shared an ancestor. Constraints now activate after
insertion. A layout regression test loads and rebuilds all width variants.
Dictionaries are compiled on the build Mac with the pinned Rime library; the
keyboard loads bundled binaries without running dictionary maintenance.

Verified on the installed iPhone Duo build with voice off:

- The actual extension stays visible, identified by its `keyboard.key.*` controls.
- `nihao` appears inline as marked `ni hao`; choosing 你好 replaces it exactly.
- `hello` offers Latin spelling, English completions, and Chinese candidates together.
- Choosing English replaces the Pinyin preedit; Return at the former mic position inserts a newline.
- Backspace changes inline `ni` to `n`, then removes the composition without touching prior text.
- Switching to Apple's keyboard and back restores vvhisper without the startup crash.

The resulting host field was read back as `你好 hello\n`. Cross-app marked-text
behavior, all physical orientations, and speech accuracy remain separate checks.

Validation: signed device build succeeded; 11 simulator tests passed, including
keyboard load/rebuild regression and English completion commit. Build/test scratch
directories were removed by the scripts. No speech retest was performed in this pass.

## Always-bilingual layout alignment — 2026-11-16

Removed the language toggle and its saved-mode preference. Shift controls English
capitalization while Chinese candidates remain available. The system keyboard picker
remains on the smiley key. Candidates use the full available width.

Compared the installed extension with both native English and Simplified Pinyin
keyboards on the physical Duo's outer portrait display, in the same host text field.
Adjusted horizontal insets (accounting for iOS's outer container), key heights,
row spacing, letter size, modifier icons and the bottom-row widths/order. Letter-key
edges and row positions now visually align; the simplified bottom row retains the
requested Return and omits dictation/language controls. Other device orientations
have layout regression coverage but were not physically compared in this pass.

Signed update installed. All 11 simulator tests passed. On-device Shift + `nihao`
showed `Nihao` and `你好` together; choosing English then typing/choosing Chinese
produced `Nihao 你好`, read back from the actual host field. Voice remained off.

## Inner display and landscape alignment — 2026-11-16

Compared Apple's native keyboard and vvhisper on the physical Duo in inner portrait,
inner landscape, and folded outer landscape, using the host test field. The user
changed the physical fold/orientation and selected the native keyboard for captures.
This supersedes the earlier note that only outer portrait had been visually checked.

- Inner portrait: removed the extra accessory row; placed the keyboard picker and
  Return in the fourth row, and matched key spacing, size, typography and side margins.
- Inner landscape: matched the native split arrangement, including duplicated G/V at
  the thumb boundaries, two space keys, and full-height bottom keys. Prevented the
  split stacks from reapplying the system bottom safe area inside their keys.
- Outer landscape: corrected layout classification for the extension's available
  width (not the full screen width), then aligned its compact key rows and margins.
- Reused the square switcher glyph instead of squeezing a tall side-accessory SVG
  into a key. Bilingual candidates remain simultaneous, with no language toggle or mic key.

Signed updates were installed and observed. The final inner-landscape and outer-
landscape captures showed the corrected rows and bottom keys; inner portrait was
also physically compared after removing its extra row. These are visual checks,
not a new speech or long-form typing acceptance pass. Voice was off at completion.

The phone automation runner retained outer-display touch dimensions on the inner
screen, even after one reconnect, so automated taps were unreliable there. Debug
builds can be launched with `--keyboard-test` to focus the harmless test field;
the setup page now scrolls a focused test field into view as keyboard geometry changes.
This flag does not start microphone capture or insert text. Ordinary launches are unchanged.

Final validation: signed device build succeeded; all 12 simulator tests passed,
including split-key dimensions, duplicated boundary keys, landscape classification,
and existing Pinyin/voice model tests. Build/test scratch directories were cleaned.

## Test-field keyboard avoidance — 2026-11-16

The test field now reveals itself when editing begins and on keyboard frame changes,
not only during controller layout. Scroll updates are coalesced after content/viewport
layout, animate with the keyboard, and leave a 12-point gap. If the viewport is too
short for the entire editor, the caret is prioritized. The keyboard layout guide
continues to own the viewport, avoiding a second manual keyboard-height inset.

Installed and checked on the Duo: the whole field stayed above the keyboard on
initial focus, dismissal/reopening, and switching between vvhisper and the native
Chinese keyboard. All 12 existing tests passed. Voice remained off.

## Tap haptics — 2026-11-16

Keys, candidate selections/paging, and the keyboard switcher now request a light
impact at 0.45 intensity. A retained generator is prepared on touch-down and fires
on accepted taps, outside the deferred typing queue, so queued input does not produce
extra pulses. Cancelled touches and dictation release do not produce tap feedback;
the existing dictation-start haptic remains separate. The host audio session allows
haptics while armed via Apple's `setAllowHapticsAndSystemSoundsDuringRecording` API.

Signed build installed on the Duo; key-tap smoke input appeared in the test field.
Physical haptic strength still needs user feel-testing; screenshots cannot verify it.

## First-candidate hint — 2026-11-16

The default candidate now appears first with a rounded, adaptive fill and semibold
text. It also exposes a selected accessibility state and a Space-key hint. English
spelling/completions and the remaining Chinese candidates stay in the same strip.
Space accepts the highlighted Chinese candidate, or the English spelling when no
Chinese candidate is available. Button padding preserves the existing text spacing.

Signed update installed on the Duo. The outer-portrait capture showed `你好`
highlighted beside `nihao`; pressing Space committed `你好` in the host field.
Selecting the English spelling also worked. All 12 existing simulator tests passed;
build and test scratch directories were cleaned. Voice remained off.

## Automatic microphone activation — 2026-11-17

A hold with no fresh microphone heartbeat now opens vvhisper automatically, using
a fresh App Group nonce. The host rejects replayed, malformed and expired URLs,
consumes the request before enabling, and waits for actual capture readiness.
Stopping while microphone permission is pending prevents a late permission result
from restarting capture. Disappearing keyboards cancel the original touch.

The Debug return experiment now observes source-app events in the containing app,
informed by [OpenWhispr's UIKit observer](https://github.com/OpenWhispr/openwhispr/blob/main/openwhispr-mobile/modules/app-group-storage/ios/HostAppObserver.swift).
The unsuccessful extension arbiter, process-ID and system-navigation probes were
removed. No source app identities, typed text, audio or credentials are logged.
One overwritten Debug diagnostic records only the handoff stage and time.

Validation: all 14 simulator tests passed. Signed Debug and unsigned Release
builds succeeded. The Release app and keyboard Mach-O binaries were checked for
the experimental private class/selector names; none were present. Build/test
DerivedData was cleaned; the completed signed Debug bundle remains in build/.

Observed on the Duo: the earlier automatic wakeup opened vvhisper and enabled
capture. A recording of the temporarily enabled 豆包输入法 showed its main-app
launch and automatic return to the empty test field with listening active. That
comparison establishes its behavior, not its implementation. The new vvhisper
main-app observer still needs physical verification; phone automation became
unavailable before that check and before restoring 豆包's disabled setting.

The installation attempt for this observer build failed with CoreDevice
`Failed to allocate RSD device`. The completed local bundle is newer than the
installed app. Reconnect/unlock the selected Duo, install the bundle, verify the
cold/warm return path, then disable the temporary 豆包 keyboard and select vvhisper.

## Candidate consistency and attached haptics — 2026-11-17

The visible candidate list now supplies the Space action directly. For `haode`,
`好的` is first and Space selects it; the raw `haode` is omitted because it is not
an English word. Recognized English words and completions stay alongside Chinese
choices. Return still accepts arbitrary Latin spelling, including names that the
English checker does not know. If no Chinese choices exist, raw spelling is the
first fallback. All spelling checks remain on-device.

The first candidate uses a stronger adaptive rounded fill and semibold text, plus
the existing selected accessibility state and Space hint. The retained light
haptic generator now uses Apple's view-attached initializer and prepares when the
keyboard appears, keeping the 0.45 tap intensity. Candidate taps, Space, Return,
delete and modifier keys use the same tap feedback; queued typing does not replay it.
Physical haptic feel must still be checked on the Duo.

Validation for this refinement: all 16 simulator tests passed, including the real
Rime `haode` → `好的` first-choice/commit regression and simultaneous English-word
availability. The signed arm64 build succeeded and its temporary build/test
DerivedData was removed by the scripts. Device validation remains separate.

The combined update was successfully installed and launched on the selected Duo
after CoreDevice recovered (bundle `com.vvhisper.ios`). This supersedes the earlier
failed install; it also includes the pending main-app return experiment. Screen
automation remained unavailable, so the visual/haptic checks, automatic-return
check, and temporary 豆包 keyboard cleanup are still unverified.

## Adjustable haptics and mixed typing — 2026-11-17

The host now has a Haptic strength slider: Off to 100%, in 5% steps, with a live
preview and a persisted App Group setting. The keyboard refreshes it when opening
and once per second while visible. Off suppresses key, candidate and dictation
start feedback; the default stays 45%. Actual strength depends on the hardware.

Recognized English words now lead the candidate strip. Unknown spellings that
Rime only partially converts, or that cannot form a normal Pinyin sequence, also
remain Latin by default. Explicit capitalization can preserve names such as Luma.
Chinese candidates remain beside them; clear Pinyin such as haode/nihao keeps its
Chinese first choice and hides the raw spelling. Short Chinese initialisms remain
available. This is local heuristic ranking, not a language model or autocorrection.
Space accepts the highlighted choice, adding a space for English only. Candidate
taps insert the chosen word; a subsequent Space can insert the separator.

The handoff coordinator now waits for the containing scene to be foreground-active
before enabling its microphone. Diagnostics distinguish startup failure, a ready
microphone awaiting a source app, cancellation, return acceptance/rejection and
expiry, without logging any app identity, text, audio or credential. Device
verification is pending permission to resume a session ended on the phone.

All 20 simulator tests passed, including English words/names/contractions, mixed
Chinese-English commits, Pinyin syllables/initialisms and haptic value validation.

Signed Debug and unsigned Release builds succeeded for this update. The Release
app/keyboard Mach-O files contain none of the experimental private API names.
Temporary DerivedData and the unsigned Release check artifact were removed.
The signed build is ready locally; installation and physical return verification
await permission to reconnect the Duo after remote control was ended on-device.


## Chinese phrase dictionary upgrade — 2026-11-17

Replaced the minimal 65,125-entry conversion dictionary with the pinned Rime Ice
character/base/extended dictionaries: 891,394 source entries. Original frequencies
are preserved. Compilation remains on the Mac; the app and extension load compiled
tables and contain the data license/provenance. Cache generation is now v3 so an
old schema cannot override the new table.

A fixed 36-phrase comparison using the actual Rime library improved from 32/36 to
36/36 first-choice matches. Representative corrections:

| Input | Previous first choice | New first choice |
| --- | --- | --- |
| `wozhidaole` | 我只到了 | 我知道了 |
| `woyijingzhidaole` | 我一精致到了 | 我已经知道了 |
| `womenyihuiliao` | 我们一会了 | 我们一会聊 |
| `womenkeyishiyixia` | 我们可以是一下 | 我们可以试一下 |

The same 36 phrases are covered by the iOS regression suite through
`BilingualCandidates` and its Space commit action. This is a bounded regression
sample, not a general accuracy score or native-keyboard parity claim. No contextual
language model, cloud typing service or user-learning database was added.

Validation: 21 iOS tests passed on a fresh iOS 27.1 Duo simulator, including all
36 phrase rankings/Space commits and the existing English/mixed-typing tests.
The existing simulator stalled before executing tests; the clean simulator run
completed successfully. The signed build was installed on iPhone[marcus] (Duo).
Physical typing and extension memory under prolonged use remain unverified for
this larger dictionary.


## In-field dictation and candidate sizing — 2026-11-17

Dictation now owns a single marked span in the focused host field. The preview uses
the Mac's stable growth rule; after release it stays visible while polishing, then
the final result replaces the span and commits it. No transcript is shown in the
keyboard. Existing text around the span is preserved, including when dictation
starts over a selection. Explicit slide cancellation restores that selection;
user interruption or recognition failure preserves visible speech.

Each hold validates document identity, text context, selection, reply identity,
timestamp and ordering. It snapshots its own edits and ignores duplicate replies.
A field/cursor/user edit abandons pending replacement. Tests exercise the actual
UIKit UITextView marked-text methods behind a proxy adapter, including Chinese,
emoji, multiline output, bounded context, cancellation and stale results.

Candidate controls now use measured text width plus 8 pt per side, with no system
button minimum width. The first choice retains its fill, semibold text and selected
accessibility trait. The layout test verifies unequal widths for one-, two- and
three-character Chinese candidates and an English word.

Validation: all 31 iOS simulator tests passed and the signed arm64 device build
succeeded. These changes are included in the subsequent 42-test build installed
on iPhone[marcus] (Duo), described below. Live Seed speech has not been retested yet.

## Delete gestures and quiet recording — 2026-11-17

Return is wider on the phone and all four Duo layouts; the mode key keeps its
previous width. The inner-landscape return now uses the shared metric too.
During recording, key text and the voice status label are hidden without changing
key geometry or accessibility labels. Functional icons remain visible. Labels
return on release, and polishing still happens in the host field.

Delete never starts dictation. A tap deletes once; a 380 ms hold starts repeating
at 80 ms intervals. After holding, a left swipe of at least 60 pt clears the current
field once, including text after the caret. Vertical movement beyond 40 pt cancels
the gesture. Release, cancellation and layout changes stop repeat timers, and
repeat ticks cannot pile up behind asynchronous Pinyin edits.

Clear-all invalidates pending composition and edits through the public document
proxy in short batches. Document, context and selection changes or another key
press cancel pending batches. Missing context reports an incomplete clear rather
than claiming success; work is capped at 20,000 iterations or ten seconds. Tests
cover selections, Chinese, emoji, repeated/truncated context and blank paragraphs.

The English ranking check now verifies that the system dictionary can reject a
nonsense word before treating an unflagged spelling as English. A missing system
dictionary otherwise reports no misspelling for every Pinyin phrase. This fallback
keeps Chinese choices first while the system dictionary becomes available.

Validation: all 42 iOS simulator tests passed, including the real Rime phrase and
mixed-language regressions. The signed arm64 app and keyboard build succeeded;
signature verification passed. The owned simulator and temporary build/test caches
were removed. This build also includes the in-field dictation and candidate-width
changes above. After the Duo reconnected, this signed build was installed on
iPhone[marcus] (00008160-000934DA0C200036) and launched successfully on 2026-11-17.
Physical gesture, layout and live voice checks remain unverified for this build.

## Separate Chinese and English modes — 2026-11-17

At the user's request, the keyboard now has explicit language selection again.
The 中 / EN key is immediately left of the emoji/system keyboard key in phone,
Duo outer/inner portrait and landscape layouts, including split and symbol pages.
The key identifies the current mode; its accessibility hint names the next mode.
The wider Return key and Delete gestures are retained.

Chinese mode uses Rime's candidate order with no English word detection or mixed
completion strip. English mode inserts directly without Pinyin marked text or
Chinese candidates. A language change preserves unfinished visible spelling,
invalidates old composition callbacks and keeps subsequently queued taps in order.
The last mode is stored in extension-local UserDefaults, with Chinese as the
initial default. This selection does not affect multilingual dictation.

Validation: all 45 simulator tests passed, including language switching during
queued Pinyin edits, direct English insertion, persistence, the 36 Chinese phrase
regressions and switch placement in all five layouts. The signed arm64 build and
signature verification passed; temporary build/test caches and the owned simulator
were removed. Installation is pending because the Duo disconnected during the
update. Physical UI and voice checks remain unverified for this build.

## Touch targeting and overlapping presses — 2026-11-17

Keycaps keep their existing geometry, while a shared touch surface assigns nearby
gaps to the closest key edge. Direct hits remain literal. Expansion is bounded
to 14 pt horizontally and 10 pt vertically; the split center, large accessory
spacers and candidate strip remain outside key targeting. This avoids independent,
overlapping hit boxes and retains the native system keyboard-picker action.

Overlapping finger presses now commit pending character/Space/Shift/Delete taps
in press order. Old releases, cancellations and hold timers cannot repeat the
action. A recognized dictation/Delete hold does not emit a stray character.
Return and layout switches cannot be triggered by another finger's press.
Capitalization updates labels and the Shift icon without rebuilding key views
under an active finger. Explicit page/orientation changes still invalidate touches.

This pass uses geometry, not language prediction. The rationale and a bounded
predictive-targeting direction are in [Keyboard Touch Accuracy](Design/KeyboardTouchAccuracy.md).
The user is away from the computer and will test on the Duo later; installation
and physical typing comparison are deferred at their request.

Validation: all 53 iOS simulator tests passed. The signed arm64 app/extension build
and signature verification passed. The owned simulator and temporary test/build
caches were removed. The completed build is retained in `build/vvhisper.app` and
includes the language-switch update above; it has not been installed on the Duo.

## Optional mixed typing — 2026-11-17

The main Settings page now includes **Experimental → Mixed Chinese & English**,
off by default for both new and existing installations. Enabling it restores
combined Chinese/English candidates in Chinese mode and changes the language key
to **中英**. EN remains direct English input, and the language key stays beside
the emoji/system picker. Disabling the experiment restores normal Chinese ranking.
The preference is shared with the keyboard and preserves saved haptic strength.
Each word keeps its candidate policy until committed or cancelled, including when
the preference changes with asynchronous keystrokes still queued.

Validation: all 64 simulator tests passed, covering Settings persistence, older
preferences, both candidate policies, missing system spell-check data, mid-word
changes and the existing Chinese phrase, touch, deletion and dictation regressions.
The signed arm64 app and keyboard build and strict signature verification passed
with team Q9MD524YL5. Temporary build/test caches and the owned simulator were
removed. The completed build is retained in `build/vvhisper.app`; it has not been
installed on the Duo. Physical typing and voice checks remain deferred while the
user is away from the computer.

## Letter holds and dictation targets — 2026-11-17

Only the letter keys start dictation. Holding Shift, Space, Return, language/mode
keys, punctuation or numbers preserves their normal single action on release;
Delete keeps its repeat and held-swipe clear behavior, and the system picker
keeps its keyboard-list gesture.

Once recording starts, the originating finger can move across the keyboard without
typing other keys. Entering Delete's actual keycap immediately cancels this hold,
discards its preview and restores any selection it displaced. Delete turns red
with a light haptic until release. Entering Return's actual keycap stops recording,
turns Return blue with a light haptic, and requests one Return after a successful,
nonempty polished result replaces the preview. The field's Return behavior decides
whether this sends or inserts a newline. Return shows a paper-plane icon while
recording so it remains visible with key labels hidden.

Crossing gaps does not trigger either target. Releasing elsewhere finishes without
sending; sliding outside the keyboard cancels. The original letter's release
cannot type a character, delete text or send twice. A failed/empty/stale result,
typing, cursor/field changes, rotation or cancellation invalidates pending sending.
No private host-app submission API or UI automation is used.

Validation: all 76 iOS simulator tests passed, including letter-only activation,
normal function-key holds, cancellation and final-result submission across all
five layouts, marked-text restoration, duplicate/stale replies and interruption.
The first simulator launch stalled before tests ran; after restarting the owned
simulator, the full suite passed. The signed arm64 app/extension build and strict
signature verification passed with team Q9MD524YL5. The owned simulator and
temporary build/test caches were removed. `build/vvhisper.app` contains this update.
At the user's subsequent request on 2026-11-17, this signed build was installed
as an update on iPhone[marcus] (Duo, `00008160-000934DA0C200036`), preserving app
data. CoreDevice confirmed installation and launch, and the running app process
was observed (PID 1901). Screen automation remained stopped. This also deploys the
preceding language-switch, touch-targeting and optional mixed-typing changes.
Physical gestures, haptic feel, live Seed speech and sending in actual host apps
remain unverified for this build.

User feedback after installation: the user reported all the new gestures working
on the Duo and that the keys felt substantially easier to press. This is a user
confirmation of the preceding gesture/touch update, not a native-keyboard parity
claim or verification of the subsequent gap/preview update.

## Gap holds and character previews — 2026-11-17

Holding an ordinary inter-key gap now starts dictation, including gaps beside
function keys and on symbol pages. The press origin is latched: direct function
holds retain their normal behavior, while gap holds never repeat Delete or invoke
Return. Quick taps retain the chosen key's tap behavior, including cancelling a
Delete tap if the field/cursor changes before release. The existing slide-to-Delete
and slide-to-Return actions also work after a gap hold. The large split center,
accessory spacers and candidate strip remain outside key targeting.

Letters, numbers and punctuation show a raised character balloon immediately on
press. It follows the displayed case/symbol, stays within the keyboard's bounds,
adapts to light/dark appearance, and never intercepts touches or moves the keys.
Release, cancellation, dictation start, rotation and dismissal hide it. Overlapping
presses cannot leave a stale popup or dismiss the next finger's preview.

Validation: all 85 simulator tests passed. Native UIKit renders were reviewed in
light/dark appearance for phone and all four Duo layouts; the contact sheet is
retained at `build/verification/key-previews.png`. The signed arm64 app/extension
build and strict signature verification passed with team Q9MD524YL5. On 2026-11-17,
the update was installed on iPhone[marcus] (Duo, `00008160-000934DA0C200036`) without
uninstalling or clearing app data. CoreDevice confirmed launch and the new app's
process was observed (PID 1991). Screen automation remained stopped. The temporary
simulator and build/test caches were removed. The user has not yet confirmed the
new gap-hold behavior or popup appearance on the physical Duo.

## Symbols, appearance and voice lifetime (2026-11-17)

The first candidate now starts 10 points from the left edge (2-point outer inset
plus 8-point label padding). Direct holds on symbol-page character keys open a
chooser for related punctuation, currencies, fractions and other variants. Slide
and release to choose; a stationary hold inserts the printed symbol. Sliding out,
changing fields, rotation and a second finger cancel the chooser. Gap holds still
dictate. Chinese quote keys display 「 and 」; English retains straight quotes.

Keycaps transmit the system keyboard backdrop and respect the focused field's
keyboard appearance, including a dark keyboard requested by a light app. High
contrast and Reduce Transparency use opaque fills. Symbol choices have a solid
material-colored surface so key legends behind them cannot impair readability.

Validation: 94 simulator tests passed, including every symbol key in all five
layouts, slide/release/cancellation, Chinese quotes, appearance overrides, older
preference migration, persistence and exact session expiry boundaries. Native UIKit
contact sheets were reviewed in light/dark appearances. Signed arm64 device builds
passed. Live Spotlight comparison, physical session-expiry testing and installation
of this update remain pending: CoreDevice reports the Duo unavailable.

## Clipboard pills — 2026-11-27

Symbol pages (with no Pinyin candidates) show one scrolling row in the candidate
strip: 1Password and Messages as filled brand-colour pills, a newly copied code
as a pill with its digits, up to five recent clips (newest first, each with a
link/email/phone/number/text icon and a 20-character title), then the Clipboard
History clock. Tapping a clip pastes its full original text without reordering;
the code pill replaces the old Paste Code button. Without Full Access or history
only the two shortcuts and the clock appear. Copies marked concealed (for example
1Password passwords) are never shown or recorded. Offscreen light/dark renders at
375/402/440/466 are written by `ClipPillsTests` to `.airbuild/artifacts/phone-layout/`;
contrast over the real keyboard glass still needs a physical-device check.

## Local clipboard history — 2026-11-20

Shortcuts → Clipboard History shows up to five unique text clips, newest first.
Repeated copies move an item to the top. Text is retained when the visible keyboard
observes a new clipboard version, or after explicit Paste through vvhisper. The
system may request paste permission. Copies made while vvhisper cannot observe the
clipboard cannot all be recovered; this is not access to an OS history service.

Each clip is bounded to 20,000 UTF-16 units. Original text and whitespace are kept
for pasting; only menu previews are shortened. Selecting history validates the
original field/cursor, leaves the system clipboard untouched and does not reorder
items. Clear History clears only vvhisper's list, without rereading the same clip.
Storage is local to the keyboard, protected while locked and excluded from backups.
No clips are logged or sent to ASR/polishing. This applies to iPhone and iPad layouts
and supersedes the earlier no-history decision.

## Punctuation, emoji stability and dictation contrast — 2026-11-20

The English and Chinese punctuation pages follow Apple's per-language key order.
Chinese preserves ASCII symbols where Apple does, includes its six-key punctuation
row, and retains visible 「」. Its face-mark key opens local text emoticons.

Keyboard switching now tolerates a missing document identifier during teardown
and late text callbacks, rather than trapping in Swift's UUID bridge. The shortcut
and editing pills are raised three points. While dictating in light mode, resting
key fills fade to 22% so the center-out white volume highlights are easier to see;
icons and touch targets remain intact, and fills restore when dictation ends.

Validation for this update: 250 simulator unit/integration tests passed. The signed
Debug build was installed on the Duo without removing app data. Six consecutive
local Emoji → ABC round trips passed on the device; no new vvhisper crash report
was present afterward. Both native English punctuation pages and both native
Chinese pages were captured as references. The installed English pages and raised
pills were checked visually. Native UIKit contact sheets cover full/mini listening
contrast and restoration. Installed Chinese-page and live speech-level checks
remain pending. The separate simulator UI test could not select the extension
reliably and did not complete; it is not counted as a pass.

Listening sensitivity refinement (2026-11-20): use a gentler 0.65-power visual
response instead of the square-root lift. Quiet/ordinary speech illuminates a
narrower center region; loud speech can still reach full extent. Keep the approved
light-mode opacity, noise gate, attack/release timing and ASR audio unchanged.
The 17 focused meter, rendering and keyboard-lifecycle tests passed.

Action keys (2026-11-20): named Return actions such as Send, Search, Go and Done
use black fill with white text/icons in light appearance, reversed in dark
appearance. Full and mini layouts share the style; ordinary newline Return keeps
its normal fill. Voice-meter highlights cannot wash out the action key. Seventeen
focused lifecycle, dictation-feedback and compact-keyboard tests passed.

Candidate-strip refinement: hide the shortcut pill while candidates are visible
and use the freed left space for suggestions. Restore shortcuts when candidates
clear; keep the right gesture pill while the panel is collapsed. Fifteen focused
candidate, pill/layout and keyboard-lifecycle tests passed.

## Compact emoji panel and emoji candidates — 2026-11-20

Hold Language for the system keyboard picker; a short tap still switches Chinese
and English. The emoji panel has one compact row of navigation/category icons,
including a keyboard-return icon and globe. Removing its category title and bottom
action row gives the grid more height. Skin-tone choices are available by holding
an emoji that supports them.

English and Chinese names/keywords can suggest up to three emojis alongside words.
Matching uses bundled Unicode CLDR 47 data locally. A word stays first, so Space
does not automatically substitute emoji. Explicit selection replaces the current
owned word or Pinyin composition. Matching never sends or saves typed queries.

Validation: all 258 simulator tests passed, including bilingual emoji replacement,
stale-field rejection, compact-panel navigation and language-hold tap suppression.
The signed Debug build is installed on the Duo without removing app data. Native
input-mode picker behavior on a physical hold remains pending a screen-control
window; unit tests do not verify UIKit’s system picker.
