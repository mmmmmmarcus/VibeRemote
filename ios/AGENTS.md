# vvhisper iOS

## Private credentials (2026-11-24)

User chose personal-only builds with no backend. This supersedes credential-entry
and credential-sync instructions below. Build scripts embed ignored, locally
generated credentials; runtime reads PrivateCredentials (Android: bundled asset).
No key entry/removal/export controls. Seed uses its new-console key, independent
of preserved legacy App ID preferences. Settings transfer must not read, export,
or apply credentials. Preserve existing Keychain/Keystore entries. Never print
or commit keys or publish these private binaries. See macos/Design/PrivateBuilds.md
(relative to repository root) for provisioning and verification limits.


The iOS app is a separate native UIKit host plus keyboard extension. Build with
`./build.sh`; the checked-in XcodeGen `project.yml` generates the ignored project.
Target arm64 iOS/iPadOS 27.0, device families 1 and 2, personal team Q9MD524YL5. Never change macOS compatibility IDs.

Emoji Back uses the same single tap feedback as Emoji entry. Enter has two tactile
stages: normal touch-down feedback, then a stronger/sharper confirmation when its
hold inserts a line separator. Never pulse again on release or when insertion is
cancelled. Both obey the user's haptic settings, including strength zero.
Extended Delete (2026-11-22): after the direct Delete hold threshold, grow a
visual-only surface left over its adjacent same-row key (M on phone letters).
Keep the real key frames and hit targets unchanged. The broom center is the
latched clear-all target; reaching it clears once, and release never deletes again.
The current SDK has no built-in broom: `DeleteBroom.symbolset` is original artwork
compiled as a custom SF symbol, not a system-provided icon. Keep the 180 ms reveal,
120 ms dismissal and Reduce Motion support. Restore borrowed key paint on release,
cancel, second-key input, field changes, rotation, mode changes and dismissal.
Use actual geometry in continuous/split, portrait/landscape and symbol layouts;
mini borrows only a bounded edge of Dictate, and iPad uses Delete's adjacent number
row key. Gap dictation and dictation slide-cancel never expand Delete. Preserve
destination guards and bounded clear-all work. The HTML is the approved reference.

## Configuration sync and transfer (2026-11-22)

The user replaced iCloud Keychain synchronization with a password-encrypted JSON
file selected in iCloud Drive. Mac and the iOS host remember a security-scoped
bookmark and a local-only Keychain password; the keyboard reads existing local
keys. Android imports/exports the same authenticated format. Keep existing key
services and values working; no additional sync access group or Mac provisioning
profile is required. Never put plaintext keys in defaults, files or logs.
Settings-only export is default; including keys is explicit and encrypted.
Only Seed/Ark keys and polishing/punctuation settings transfer. Missing values
never erase local keys. Conflicts require a choice; offline failures preserve
local operation. See macos/Design/ConfigurationSync.md for the shared format.

## Text first, better later (2026-11-25)

User request: dictation commits text quickly and stays robust; this supersedes the
older 5 s refinement wait, the 15 s polish wait and "no dictation history".
KeyboardVoiceSession.Budget owns the numbers and the tests pin them:
- Seed live + nostream sockets open at hold start (audio queues until connected);
  release before the first audio chunk still completes silently and closes them.
- Refinement: wait 1.5 s after release for the nostream final, then use the live
  final, else the latest live partial. If neither stream has any text, wait until
  5 s, then retry. A dead live stream also waits to 5 s before retrying.
- Polishing budget 3 s (translation 8 s). Past it, commit the unpolished text
  with Sentence Punctuation and drop the late result; never swap text afterwards.
  Ordinary polishing has no notice for the budget; translation says it kept the transcript.
- Short utterances skip ordinary polishing: Han char = 1 unit, Latin/digit word =
  1.5 units, ≤ 6 units skips (≤ 6 Han chars or ≤ 4 words). Translation still polishes.
- Retry: the utterance's PCM stays in memory only (cap 3.84 MB = 120 s 16 kHz PCM16)
  so that after both streams fail, or both stall for 5 s, it can be resent once to a
  fresh nostream session (6 s budget) after release. Auth/quota failures never retry.
  Ark retries once on connection errors (not timeouts/HTTP errors), inside the budget.
- After failure keep the best text; with no text show a classified message
  (DictationFailureKind: offline, auth 401/403, quota 429/Seed 55000031, timeout, other).
  SeedStreamingSession emits only that class, never provider text or log IDs.
- Recent results: the last 10 final texts with timestamps in the App Group
  (DictationRecent.json, complete-unless-open protection, excluded from backup), local
  only, never logged/sent. Cancellation after release (dismissal, field change,
  typing, timeout) saves the best in-flight text; cancelling while recording does not.
  The keyboard shows them as an inline "Recent Dictation" section of the existing
  Clipboard History menu, with its own Clear action, inserting via completePaste.
- Timing metrics: DictationTiming.json in the App Group, last 200 utterances,
  durations, path, polish outcome and error class only; never text, lengths or keys.
  Host Settings → Dictation Timing shows count, median/p90 release→text and the most
  common slow step, and copies the JSON. Real-device timing needs a physical device.

## Direct keyboard dictation (2026-11-22)

The user authorized WebKit capture as the primary path, superseding the older
host-owned microphone and host-only credentials rules. The main app now grants
microphone permission and manages settings only. No background-audio mode, idle
microphone, readiness timer or automatic app-return mechanism remains. Preserve
legacy preference values, but do not expose Keep Dictation Ready in Settings.

A nonpersistent WKWebView, attached at 1×1 pt / alpha 0.01, loads bundled HTML only.
Create AudioContext and getUserMedia only during an explicit hold; release, cancel,
dismissal, interruption and the 120-second hold limit stop all media tracks. Guard
both sides of every async startup boundary with the hold UUID. The page watches
native heartbeats and stops after 3 seconds without one. Block network/navigation
in the page, grant only its own main-frame microphone request, and never pass it
credentials, transcripts or editor context. WebKit behavior is not guaranteed by
Apple's keyboard contract; validate on physical devices after OS updates.

KeyboardVoiceSession owns streaming Seed, refinement and Ark polishing in the
extension. Audio is 16 kHz mono s16le; levels stay in memory, capped at 20 Hz.
Keep DictationTextSession's field/selection/marked-span guards. Typing or deleting
cancels pending polishing synchronously and late callbacks never replace edits.
Empty recognition and holds released during startup complete silently.

VoiceConfiguration stores only non-secret settings in App Group defaults. Separate
Seed/Ark keys remain device-only native Keychain items in the explicit shared voice
access group. The host copies and verifies existing keys once, retaining originals;
never import a Mac key, send keys to JS, or put them in shared files. Migration failure
must not erase an existing key or mark migration complete. Actual audio-route,
media-output, haptic and process-termination behavior requires device verification.

On iPad widths >=600 points use five continuous rows: number row with Delete,
QWERTY with Tab, home row with a wide Return, lower letters with punctuation and
Shift, and language/emoji/Dictate/Space/arrows. Preserve the same mini row and
input policies. Widths below 600 fall back to phone geometry; do not force iPad
layout onto the Duo or request unsupported floating-window behavior. Validate
portrait, landscape and narrow windows; host and extension target both families.

Only audio from an explicit dictation hold is sent to Seed. Never log audio,
transcripts, credentials or provider response bodies.
All async responses must match the hold and focused document before inserting.
After final Seed recognition, the extension runs a separate text-only Volcengine Ark
polish pass (2026-11-19). Use `doubao-seed-2-0-mini-260428` at
`https://ark.cn-beijing.volces.com/api/v3/chat/completions` with
`thinking: {"type":"disabled"}`. Polish Dictation defaults on; shared settings latch
at hold start, with a separate device-only Ark Keychain key. Never reuse/fall back
to ASR or legacy OpenRouter credentials or a saved OpenRouter model. The Model row
identifies the fixed Seed 2.0 Mini model; label the key Volcengine Ark API Key.
Never transfer Mac credentials or put keys in shared IPC. Send only transcript
and editing instructions, no tools/editor context. Preserve meaning, tone,
uncertainty, negations, names, numbers and mixed languages. Require complete
finish_reason=stop JSON with only a nonempty text field. Missing credentials,
timeout and invalid responses keep the original recognized text with a notice.
Distinguish authentication, model access, quota/rate limits, server failure,
timeout and invalid responses without exposing provider bodies or transcript text.
Use an ephemeral session with a 15 s resource deadline (the keyboard's 3 s polish budget
ends the wait sooner; see Text first, better later). Keep recognized text
marked while awaiting polish; release never commits early. UITextDocumentProxy
cannot force an underline in arbitrary host apps: marked-text appearance belongs
to the host. Never insert decoration or mutate document underline formatting.
Real keyboard proxies can exclude marked text from surrounding context (observed
on the Duo, 2026-11-19). DictationTextSession keeps the original composition anchor
and predicted own-write context; never treat that anchor as a cursor move or wait
forever for marked text to appear in context. If the field was initially empty,
its first marked draft makes hasText true while both outside-context values stay
nil. Normalize that pair only for this session's known-empty anchor, matching
document and empty selection, while it owns a marked span or in-flight write;
never accept hidden context generally or a changed document. Test empty fields
on the real device as well as prefilled ones. Commit the final result with public
`insertText`, replacing the owned marked span as normal text, then unmark; setting
another marked final and merely unmarking left a blue underline on the Duo even
when the host's markedTextRange was nil. A preview write may settle as the same
verified outside-marked context on the next main-loop turn. Keep field/selection/
context guards, and wait for final text acknowledgement before sending Return. Debug's
explicit `--verify-dictation` checks a synthetic draft through the real extension
and records marked-state flags, not user text; it performs no ASR/provider request.
The keyboard allows 25 s after release for ASR plus polishing. Cancellation/new
holds invalidate the polish task and late completion; the keyboard revalidates
document, selection and context before replacing or submitting. No transcript,
key, provider body or provider error logging. Live verification requires a key.
Sentence Punctuation (2026-11-19) is a separate default-on shared setting, latched at
hold start. Apply DictationSentencePunctuation only to final text after optional
polishing, including disabled/failed/interrupted polishing fallbacks. Never alter
streaming text or ordinary keyboard typing. Keep its pure helper byte-identical to
the Mac helper and run the same fixtures: at most 120 Unicode scalars / 20 words,
at most 40 scalars if Han is present; longer, multiline, multi-sentence and ambiguous
URL/email/abbreviation text bypass unchanged. Only terminal .!?。！？… runs before
closing quotes/brackets are controlled; preserve decimals/interior punctuation.
Existing hold cancellation and keyboard document/caret checks still own insertion.
Stream stable dictation into the host field as marked text, then replace only that
hold's span with the polished final result. Keep transcripts out of the keyboard's
status strip. Deduplicate replies and guard document, context and selection;
typing/cursor/field changes must stop pending replacement. Candidate controls use
intrinsic text width plus padding, never equal columns or system minimum widths.
Only direct holds on ASCII letter keys start dictation. Holding an ordinary gap
between keys also starts dictation, including on symbol pages. Latch whether a
press began in a gap; gap holds must not repeat Delete or invoke a function key.
Direct holds on Space, Shift, Return, language/mode switches, numbers, punctuation
and emoji never start it; ordinary
function holds keep their normal tap action on release, apart from Space's cursor
hold, Return's line-break hold and Language's system keyboard picker described below. Once recording starts,
track the originating finger across the keyboard. Entering the actual Delete
keycap immediately cancels this hold, restores its displaced selection and shows
red feedback until release. Entering Return stops recording, shows blue feedback
and requests one Return only after a nonempty successful polished final is
committed to the same field. Gaps cannot trigger these actions. The originating
touch must never emit a letter, delete, or second Return. Normal release only
finishes dictation. Cancellation, timeout, typing, field/cursor/layout changes
invalidate pending submission. For a dictation submit gesture, emit the public proxy Return operation only when
the final focused field advertises returnKeyType.send. Otherwise commit without
a newline and show “Text ready. Tap Send in the app.” The system owns the action;
there is no universal send-message API. Never automate host UI. Ordinary Enter
taps retain the field's normal Return behavior.
Delete itself remains a normal editing key: tap deletes once, hold repeats, and a held
left swipe clears the focused field through public proxy operations. Cancel stale
deletion when the document/context/selection changes; never queue repeat ticks
behind Pinyin work. Clear-all must be bounded, yield between batches and invalidate
pending composition. During recording hide key text and the voice status label;
keep key geometry and accessibility labels intact. Return is wider in every layout.
Full-mode dictation keeps the candidate strip quiet (2026-11-18): no particles,
polishing animation or routine status label during recording/refinement. Keep
functional activation/error messages. Quiet Keys uses the approved center-out
voice-level response (2026-11-18). All text legends fade together in 120 ms at
recording start and return on release; inactive Shift and Emoji icons fade too.
Active Delete, Return and Language icons remain legible. Neutral
key fills respond from the center as speech grows, using a 35 ms attack,
140 ms release and 6% normalized noise gate, followed by a 0.65-power response
(2026-11-20: gentler than the previous square-root lift). Light appearance uses
white fill up to 90% plus a soft white rim/glow (6-point radius) on the keycap;
never darken light-mode keys in response to volume. Dark uses up to 32% white. Lit-key opacity also
tracks level. Preserve system-tinted fills and existing geometry/hit targets.
Mini uses a clipped, soft center fill inside Dictate and the same field on its
remaining function keys. No molecules, candidate-strip effects or polishing animation remain.
Final text commits immediately. Cancel, errors, rotation and dismissal clear the
feedback; old sessions cannot revive it. Reduce Motion uses a stationary low
center indication (18% white in light mode / 12% in dark mode), with no legend transition or amplitude-driven extent changes.
The capture page reports RMS with each PCM chunk; native code bounds its level
and publishes it in memory at most 20 Hz, with hold UUID and timestamp. Reject
old IDs and stale values. Stop feedback on release/cancel/dismissal. No display
link, idle meter timer, capture outside a hold or post-release meter loop.
Space has a separate cursor hold (2026-11-17): after 380 ms, haptic feedback marks
trackpad activation; a tap still inserts Space or accepts the first candidate.
Drag distance drives public proxy caret offsets, with no release momentum. Move
whole graphemes horizontally and preserve the preferred column across explicit
newline-separated lines vertically; never pretend to know the host's soft-wrap
geometry. Commit the highlighted Pinyin candidate before moving, without adding
a space. Keep both split Space keys, mini mode and symbol pages functional.
Gap-origin holds retain dictation. Cursor drags never delete, submit or dictate,
even when crossing those keycaps. Cancel stale polish and pastes, preserve visible
text, and stop on release, field/text/selection changes, another key, two-finger
mode gestures, rotation or dismissal. No text logging or extra permissions.
Cursor commands cross a process boundary: serialize them until the proxy
acknowledges the predicted destination. A delayed acknowledgement or a context
window growing/shrinking is not a user cursor change. Compare the local neighbours
and document identity; retain the actual-edit/field guards. Do not turn an idle
held Space into a timer-based cancellation. Debug's explicit `--verify-cursor`
fixture exercises this transport in the app's own test field; it stores only
synthetic outcomes, caret offsets and haptic error codes, never user text. Its legacy comparison flag
and App Group test commands must remain absent from Release.
Chinese typing uses pinned Rime Ice dictionaries in `Typing/Resources/Rime/cn_dicts`.
Preserve upstream weights, source/license notices and provenance hashes. Compile
with `scripts/compile-rime.py` into `build/resources/Rime`; never deploy/compile
inside the keyboard. Validate phrase ranking and Space commits through the real
engine, including `wozhidaole` → `我知道了`.
Typing defaults to explicit Chinese/English modes (2026-11-17). The language key
sits immediately left of the emoji/system keyboard key in every layout. Its
`character.book.closed` SF Symbol uses its explicit `.zh` variant for Chinese and
an en-US image locale for English, using the `withConfiguration:` initializer for
the current typing mode, independently of the host app/device language (2026-11-19).
Chinese mode preserves Rime's Chinese order and also offers recognized English.
English words that cannot be fully segmented into Pinyin lead the first page;
ambiguous words such as `can` keep Chinese first and offer English second. Use
local UIKit recognition plus the bundled English hints, with at most two prefix
completions for non-Pinyin spelling. Do not promote raw Pinyin or capitals alone.
English inserts directly without Pinyin composition. Typing assistance (2026-11-19)
offers local spelling suggestions and corrects close misspellings at word boundaries.
Own only the currently typed word: never rewrite pasted/dictated text or a different
field/caret. Immediately pressing Delete restores an automatic correction and rejects
it for this word. Suppress assistance in secure, URL, email, numeric, username and
one-time-code fields, with host autocorrection off, hidden context or a selection.
Preserve bundled product terms, complete Pinyin and all-caps/mixed-case tokens.
English Auto-Correction and Smart Spacing default on under Typing Assistance.
Spacing applies to selected English candidates and English punctuation, consumes a
redundant Space after an automatic one, and removes only an owned preceding space.
A directly typed dot does not add a space (domains/decimals). No spaces between Han
characters. Suggestions/undo are bounded and ephemeral; never log or learn text.
Pinyin typo assistance tests at most eight single-slip repairs in a separate Rime
session on its serial queue, only for non-complete spellings of 4–32 letters.
Promote up to three fully committed Chinese results; exact spellings retain their
original dictionary ranking. Do not globally enable Rime's broad correction:
it regressed correctly spelled phrases. Preserve raw marked spelling until selection
or Space and use the displayed candidate's action. Recognizable bundled English
repairs remain available in Chinese mode. Persist the selected mode in
extension-local preferences so typing still works without Full Access. Switching
keeps unfinished spelling and preserves queued keystroke order.
Commit Pinyin results with `insertText` (replacing the marked spelling), then
unmark; never setMarkedText(committed)+unmarkText (2026-11-25). Hosts coalesce a
turn's proxy output and may apply insertions before marked writes, so a queued
digit/symbol landed before the spelling ("B03" became "0B3"). Dictation's speech
language recognition remains independent of this typing mode.
Settings → Experimental → More English Suggestions optionally favors capitals
and unconverted Latin spelling in Chinese mode; the language key retains its Chinese
symbol and describes the mixed mode for VoiceOver. It is off by default, including
when migrating existing haptic-only settings. English mode remains direct input.
Store the experiment in shared KeyboardPreferences, retaining haptic strength;
refresh when the keyboard appears and while visible. Latch the candidate policy
for each composition so preference changes cannot rerank an unfinished word or
change its Space action. Space always accepts the highlighted first candidate.
Missing system spell-check data must not classify every Pinyin phrase as English.
Haptics has independent Strength and Sharpness controls in 1% steps, with fine
steppers and Test Tap. Preserve old strength values and default missing sharpness
to 0.7. Settings and the extension share one transient Core Haptics pattern, using
haptics-only mode without changing the microphone's audio session. Warm the engine
asynchronously; use UIKit feedback immediately when cold or unavailable, never
queue late taps. Strength zero is Off. Stop on dismissal and retain auto shutdown.
Rapid taps use a bounded pool of eight prewarmed advanced players (2026-11-18).
Never restart a player until its completion callback; saturated/cold/error paths
use immediate UIKit feedback. Match completion tokens and engine generations so
late callbacks cannot release a newer pulse or invalidate a restarted engine.
Preference changes retire in-flight players without cutting off their pulses;
dismissal cancels callbacks and stops the engine. Debug's explicit --verify-haptics
fixture requests 80 pulses at 40 ms intervals in the app's synthetic test field.
It reports counts/error codes only; API completion is not physical perception.
Ordinary keys give feedback on accepted finger-down, not release (2026-11-18).
The pinch recognizer must acknowledge the second thumb it intercepts, or both
thumbs when they arrive before UIControl tracking. Replayed two-thumb text must
not replay haptics. Keep one pulse for VoiceOver activation; mini Dictate retains
its hold-activation feedback. Never boost or overwrite saved strength/sharpness
to mask a missing input event. `--verify-haptics --observe-haptic-touches` observes
24 externally driven key touches in the synthetic field instead of generating
pulses, covering the physical two-thumb route the pulse-only check cannot test.

Keyboard simplification (2026-11-22): no gesture pill and no shortcut pill/menu.
Ordinary KeyControls have no editing-swipe callback. Direct Return holds insert
one U+2028 LINE SEPARATOR without invoking Send/Search; consume the release tap
and validate the original field. Commit Pinyin before inserting. Ordinary Return
and dictation-slide submission retain their existing behavior. Preserve Space
trackpad, pinch, held-Delete clear-all, symbol alternatives and dictation slides.
Chinese phone letters have no separate period beside Return: Space gets its width.
Chinese punctuation pages and language-aware double-Space periods stay available.

Show Clipboard History, a new copied code when available, 1Password and Messages
directly in the candidate strip on symbol pages only, when no candidates/voice
status take precedence. No Phone or standalone Paste shortcut. Keep 44-point
shortcut targets and horizontal scrolling on narrow windows. Clipboard observation
continues while the keyboard is visible, independent of shortcut visibility.
User authorized five-item local clipboard history on 2026-11-20,
superseding the earlier no-history choice. Retain at most five unique copied text
items (20,000 UTF-16 units each), newest first, observed by the existing visible
keyboard monitor or explicitly pasted. No extra background polling; no system
historical list is available. Use extension-local complete-file-protection storage,
excluded from backups. Never send clips to providers or log their contents.
History selection validates the captured destination and does not change the system
clipboard or reorder the history. Clear History removes only our saved items;
unchanged clipboard contents must not silently refill the cleared list. The code
monitor still persists version/expiry metadata separately. Recent dictation results are a separate, user-requested store (see Text first, better later). Public app URLs contain no recipients, phone numbers or message bodies;
never call or send. An unavailable app/empty Phone URL shows a manual-open hint.
Double-Space replaces only this field's own recent Space within 450 ms with `. ` in
English or `。` in Chinese; never transform URL/email/numeric/code fields, changed
context or a selection. Keep `。` visible in Chinese full letters; corner quotes do
not replace it.


Keycaps and touch targets are separate. `KeyboardTouchSurface` owns hit testing:
direct hits stay literal; every gap within the key surface first chooses the
nearest row, then the nearest key edge. The full left/right insets beside A/L
belong to A/L at every height in their row, including its corners. Include the
split center and accessory spacers (user request 2026-11-18). Preserve the surface's
0.001-alpha background fill: in the installed extension, completely unpainted gaps
receive no touch events from the remote keyboard host, even when local hitTest
tests pass. Keep view alpha at 1 and verify changes with coordinate UI taps in
`test-touches.sh`, not only direct KeyControl method calls. Keep the candidate panel
and system-owned area outside key targeting. The Duo outer portrait display was
measured at 466 points while the extension's entire hosted window was 452 points
(2026-11-18): approximately 7 points per side belong to the system, outside our
view and its hit targets. Do not describe that margin as an internal gap or claim
we can capture it by expanding KeyControl rectangles. The system owns custom
keyboard width; do not force a screen-wide frame onto its remote window.
A wide-gap press must survive
move/release at its origin. Hide
covered rows from both touch targeting and accessibility in the expanded candidate
browser. Do not independently enlarge overlapping key views. Ordinary
overlapping finger presses commit in press order without duplicate releases or
late hold callbacks. Return and layout switches must not fire from another
finger's press. Capitalization changes update legends without rebuilding pressed
keys. Prediction-driven target changes are not implemented; preserve this boundary
until a separately tested language model and touch policy are introduced.
Character keys show one raised preview immediately on touch-down, using their
current case/symbol. Keep it inside the extension bounds, with no hit testing or
layout changes. Hide it on release, cancellation, dictation start, rotation and
dismissal. A late release from an older finger must not dismiss a newer preview.
Function keys have no character preview. Keep light/dark appearance legible.
During dictation, hovering over the language key highlights it indigo with one
haptic on entry; recording continues. Release over its actual keycap opts that
hold into Chinese-English translation. Leaving the key (including its gaps)
disarms translation. Existing Delete/Return targets retain immediate cancel/send
semantics and take precedence. Translation is available in full mode; the new
one-row mini has no language key. The gesture never switches the saved typing language or submits the translated text.
The finish command's optional `translate` flag is latched by the host before
recognition finalization. Use the same Ark key/model and a single bounded request
to polish then translate into the opposite spoken language, independent of typing
mode. Mixed speech uses its dominant language; ties translate to English. The
explicit gesture works even when automatic polishing is off. Keep the normal
preserve-language polishing prompt for all other holds. Translation failures keep
the recognized transcript with a notice. Preserve document/cancellation guards,
final punctuation, marked-draft lifetime and the existing 25-second final deadline.
Direct character holds on symbol pages open an alternative-symbol chooser. Slide
and release to select; a stationary hold retains the printed symbol. Preserve gap
dictation on these pages. Dismiss without inserting on field changes, rotation,
another finger's press or cancellation. Chinese quote caps are 「 and 」; English
keeps straight quotes. The chooser must remain legible above other key legends.
After committing punctuation from either symbol page, return to the full letter
layout. Apply to Chinese/English punctuation and held alternatives; numbers and
non-punctuation symbols remain on their current page. Switch only after insertion,
including when a pending Pinyin composition must commit first.
The first candidate's outer inset is 2 points, plus its 8-point text padding.
The Chinese candidate strip scrolls horizontally and has a fixed expand/collapse
chevron, down when collapsed and up when expanded, with a 56-point-wide target
that fills the strip (44 points tall in portrait, bounded by the shorter strip in
landscape so it never steals the top of a letter key). Pulling down from the strip
also expands it; horizontal pans remain browsing
and must not select a word. Use a 220 ms slide/fade (120 ms fade for Reduce Motion),
with noninteractive snapshots cleaned up on interruption and dismissal. Keep the
strip's almost-transparent fill so the remote host delivers touches in its gaps.
Expanded candidates wrap at intrinsic word widths and scroll vertically
over the three letter rows, keeping bottom controls available. Selecting a word
collapses the panel; empty composition, language/layout changes and dismissal reset
it. Browsing reads Rime candidates in bounded asynchronous batches without changing
the engine's current page or Space choice. Use absolute indices for fetched choices,
and reject responses for old engine/composition revisions. Appending must preserve
the scroll position and any finger-down candidate. Scrolling must cancel candidate
taps and must not become editing, dictation or two-finger mode gestures. No page
arrows or cancel item mixed into the word list.
Chinese symbol pages use Chinese punctuation (，。？！：；（）【】「」 etc.), with
ASCII forms available through holds. English, URL and email layouts retain ASCII;
never transform pasted text. When no composition/candidates or voice status are
visible, the strip shows right-aligned, icon-only Paste and Open 1Password, with
clear button backgrounds in every state. Fit Paste, Paste Code and 1Password
artwork into matching 20-point image boxes; keep the 44-point control width.
Plain Paste reads only on an explicit
tap and may show the system paste-permission prompt.
Use the bundled monochrome 1Password mark and retain accessibility labels. The
code icon appears only for a newly observed copied code (user choice 2026-11-17),
not an incoming SMS. While the keyboard is visible and idle, observe clipboard
version metadata and inspect each new version once; this may prompt for paste
permission. Ignore existing contents on first setup/reboot. Expire the suggestion
two minutes after observation, or on clipboard change/use. Re-read and validate the
same version on the explicit tap. Persist only version/expiry metadata, never
clipboard text or code values; never log them or continuously poll their contents.
Pastes are bounded, single-use and tied to the document, cursor and typing generation.
Paste extracts one unambiguous copied code in a oneTimeCode field.
This is not SMS access or system AutoFill. The user explicitly
chose an app-opening 1Password shortcut (2026-11-17), followed by manual copy/return.
Do not claim direct credential suggestions or automatic return from that app.
Pinch inward to enter mini mode; pinch outward to restore the full keyboard
(2026-11-18). This replaces the two-finger up/down swipe. Mini
is exactly one row: Expand, a large Dictate key, Delete Word, and Enter. No Shift,
language, emoji, number/symbol or Space key is present. Expand returns to full
letters; pinch out remains available. Mini Delete taps and repeats remove words
using WordEditingSession's bounded, language-aware deletion and asynchronous
acknowledgement guards. A selection is deleted once as a selection. Full-mode
Delete stays character-based. Keep held-left clear-all and dictation slide-cancel.
Give Dictate a 250 ms grace period for a second finger before starting voice or
opening the host. A shorter physical tap does nothing; VoiceOver activation still
starts/stops voice. Settle pending Pinyin before shrinking. Mini's top, bottom and
side insets match, with an 8-point minimum; never add the old accessory row or split
mini into two halves on the inner display.
Two-finger mode gestures consume their touches before rollover can type/delete;
brief stationary two-thumb overlaps may replay ordinary taps in press order,
never Return or mode switches. Cancel held keys, timers and pending submission on
layout changes. Provide VoiceOver actions on Space and Dictate for changing mode.
Pinches measure the distance between two fingers in any orientation, including
one anchored finger. Accept close starting fingers on mini's short surface; require
an 8% distance change clamped to 12–24 points. Parallel swipes, pure rotation and
jitter do not switch. KeyControl must accept multiple touches so both fingers on
one wide key reach the mode recognizer before either key action can run.
Count the first finger's head start when the second lands within 250 ms; rebase
after an older hold. The full/mini transition alone follows the fingers: use
80 points of separation change for its reversible timeline, with no autoplay
while held. Keep the touched view hierarchy alive until release. Settle on lift
using distance plus 100 ms projected velocity (28% threshold), over 120–200 ms.
Hold the remote host at full height during the transition and move bottom-anchored
faces within that canvas; commit the destination height only on completion.
Do not resize the host every frame or jump to target height while preparing faces.
A cancelled gesture, field change, rotation or dismissal restores the starting
mode; never save an intermediate mode. Shared key faces retain unscaled legends;
Return stays bottom-anchored and Delete enters its lane after Return clears it.
Start only on keys, excluding candidates, helpers and the native picker. Remove
transition faces/display links on completion or interruption. Reduce Motion uses
a fade with endpoint geometry and no sliding. Mini's top inset equals its side
inset, with an 8-point minimum; full keyboard geometry remains unchanged.
Persist the completed full/mini selection in extension-local KeyboardLayoutMode
preferences, independently of Full Access. Restore before the first layout and on
reappearance without an entrance animation or haptic. Unfinished/cancelled mode
requests must not overwrite the saved selection. Opening symbols from mini saves
full mode because that is the layout now in use.
Honor the host field's keyboardAppearance independently of app appearance. Key
fills let the system-owned tinted backdrop through, with opaque accessibility
fallbacks; do not replace the system background with an opaque gray rectangle.
Do not use private APIs for host-app switching. The old Debug-only automatic
return experiment was removed when direct capture replaced the round trip.
Native keyboard parity is a design
target, not a claim: Apple's keyboard implementation is not available to extensions.
Build/test caches must be removed after work; keep the completed signed app in build/.

Emoji panel (2026-11-20): the full-mode smiley opens our local EmojiPanel, not
the system emoji keyboard. Bundle fully-qualified Unicode Emoji 16.0 sequences
with Unicode's license and provenance; no network lookup. Category browsing,
skin-tone choices and category icons live inside the panel. The compact top row
contains one pill-backed Back button and scrolling category icons; there is no
category title or bottom action row. Fade the bottom 22 points of the grid with a
viewport-pinned gradient mask and enough bottom inset to reveal the final row. Hold an emoji for skin-tone choices. Preserve
Pinyin candidate commit before opening; emoji insert literally, without correction
or spacing. Validate the press's field/context before insertion; scrolling never
selects a glyph. Hide ordinary keys and the candidate/helper strip while browsing,
so emoji touches cannot start dictation or mode gestures. Keep VoiceOver labels
and activation. No typed text or emoji history is persisted.

## Native punctuation and detached documents (2026-11-20)

KeyboardSymbols.rows is the phone punctuation source of truth, captured from
Apple's English (US) and Simplified Pinyin keyboards on Duo. Chinese must not be
a blanket full-width conversion of English: keep slash, hyphen, @, #, %, math
symbols and currency in their observed forms. The Chinese number page has six
central punctuation keys, including both 。 and ASCII dot. Corner quotes 「」
remain visible as the requested exception to native curly quotes, and in the
second page's otherwise empty slots. Preserve English quote-hold alternatives.
The Chinese face-mark key opens a local emoticon collection. URL/email/ASCII
fields use the English palette; explicit literal palette entries bypass mapping.

UIKeyboard's remote documentIdentifier can be nil during switching despite its
nonnull Swift API. KeyboardDocumentIdentity invokes only that public getter via
Objective-C and conditionally bridges it. An unavailable identity produces a fresh
nonmatching snapshot, never the last valid ID. Ignore callbacks while detached;
teardown clears local composition/dictation state without touching the vanished
proxy. Retain destination matching on every asynchronous edit.

During light-mode recording, reduce only the resting key fill to 22% of its normal
opacity, while white voice highlights and functional icons stay undimmed. Restore
the fill on release/cancel/dismissal. Never reduce the control's alpha or touch
coverage. High Contrast/Reduce Transparency keep opaque fills. Pills sit three
points higher in the candidate strip, with the same button sizes.

Action Return keys (Send, Search, Go, Done, Next and other named actions) use
opaque black fill/white ink in light appearance and white fill/black ink in dark
appearance, including mini mode. Plain newline Return keeps the ordinary key
style. Refresh the role on text callbacks as fields change. Suppress voice-meter
painting on action keys so contrast stays intact; dictation gesture target colors
still take precedence and restore the action styling when cleared.

When word candidates are present, hide symbol shortcuts and let candidates use
the full strip width, starting near the left edge.

Language holds and emoji suggestions (2026-11-20): a direct language-key tap
switches English/Chinese. Forward the real direct-touch sequence from finger-down
to UIKit's public input-mode list; waiting until our hold timer fires makes UIKit
interpret release as a next-keyboard tap. Suppress UIKit's advanceToNextInputMode
only while dispatching a short local language-key event, then let the existing
tap action switch English/Chinese. Holds keep UIKit's picker/selection behavior
and consume the local tap. Never replay or synthesize UIEvents. Its gap still holds to
dictate, and dictation sliding over Language still opts into translation. The
emoji panel has one Back button; hold Language after returning for native input-mode switching. Never fabricate
touch events or enumerate private input modes.

EmojiKeywords.json is a local CLDR 47 English/Chinese name-and-keyword index
restricted to bundled emoji. Match exact normalized words, not substrings. Insert
up to three deduplicated emoji suggestions after the first word candidate so Space
never chooses emoji automatically. Chinese queries include raw input and the top
five conversions; English uses its owned in-progress word. Selecting emoji replaces
only the current owned word/composition, with existing destination guards, without
an automatic trailing space. No typed queries leave the keyboard or are persisted.
