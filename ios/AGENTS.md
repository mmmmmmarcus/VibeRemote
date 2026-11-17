# vvhisper iOS

The iOS app is a separate native UIKit host plus keyboard extension. Build with
`./build.sh`; the checked-in XcodeGen `project.yml` generates the ignored project.
Target arm64 iOS 27.0, personal team Q9MD524YL5. Never change macOS compatibility IDs.

The main app uses native grouped settings with a separate Try Keyboard page. Prepare
voice automatically on foreground activation or after saving a Seed key; there is no
manual voice enable/disable control. Keep the session bounded and discard idle audio.
Keep Dictation Ready offers 1, 5, 10, 15, 30 or 60 minutes (15 by default, including
migration). Measure expiry from microphone activation, never from the last hold.
Changing duration updates the current deadline; if elapsed, stop immediately even
during recording. Publish the same deadline to the keyboard's readiness file.

The host owns microphone capture and Seed credentials (Keychain). The extension
never records audio or reads credentials. App Group files carry bounded, expiring
commands/results. No audio or typed text is logged. Idle audio is discarded; only
an explicit hold is sent to Seed. Stop capture on interruption and session expiry.
All async responses must match the hold and focused document before inserting.
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
function holds keep their normal tap action on release. Once recording starts,
track the originating finger across the keyboard. Entering the actual Delete
keycap immediately cancels this hold, restores its displaced selection and shows
red feedback until release. Entering Return stops recording, shows blue feedback
and requests one Return only after a nonempty successful polished final is
committed to the same field. Gaps cannot trigger these actions. The originating
touch must never emit a letter, delete, or second Return. Normal release only
finishes dictation. Cancellation, timeout, typing, field/cursor/layout changes
invalidate pending submission. Use the public proxy Return operation; whether
it sends or inserts a newline depends on the host field. Never automate host UI.
Delete itself remains a normal editing key: tap deletes once, hold repeats, and a held
left swipe clears the focused field through public proxy operations. Cancel stale
deletion when the document/context/selection changes; never queue repeat ticks
behind Pinyin work. Clear-all must be bounded, yield between batches and invalidate
pending composition. During recording hide key text and the voice status label;
keep key geometry and accessibility labels intact. Return is wider in every layout.
Chinese typing uses pinned Rime Ice dictionaries in `Typing/Resources/Rime/cn_dicts`.
Preserve upstream weights, source/license notices and provenance hashes. Compile
with `scripts/compile-rime.py` into `build/resources/Rime`; never deploy/compile
inside the keyboard. Validate phrase ranking and Space commits through the real
engine, including `wozhidaole` → `我知道了`.
Typing defaults to explicit Chinese/English modes (2026-11-17). The 中 / EN key
sits immediately left of the emoji/system keyboard key in every layout.
Chinese mode follows Rime's candidates; English inserts directly
without Chinese candidates or Pinyin composition. Persist the selected mode in
extension-local preferences so typing still works without Full Access. Switching
keeps unfinished spelling and preserves queued keystroke order. Dictation's speech
language recognition remains independent of this typing mode.
Settings → Experimental → Mixed Chinese & English optionally restores bilingual
candidates in Chinese mode and labels that key 中英. It is off by default, including
when migrating existing haptic-only settings. English mode remains direct input.
Store the experiment in shared KeyboardPreferences, retaining haptic strength;
refresh when the keyboard appears and while visible. Latch the candidate policy
for each composition so preference changes cannot rerank an unfinished word or
change its Space action. Space always accepts the highlighted first candidate.
Missing system spell-check data must not classify every Pinyin phrase as English.
Keycaps and touch targets are separate. `KeyboardTouchSurface` owns hit testing:
direct hits stay literal; nearby gaps go to the closest key edge with bounded
reach. Keep the candidate strip, split center and wide accessory spacers outside
key targeting. Do not independently enlarge overlapping key views. Ordinary
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
Direct character holds on symbol pages open an alternative-symbol chooser. Slide
and release to select; a stationary hold retains the printed symbol. Preserve gap
dictation on these pages. Dismiss without inserting on field changes, rotation,
another finger's press or cancellation. Chinese quote caps are 「 and 」; English
keeps straight quotes. The chooser must remain legible above other key legends.
The first candidate's outer inset is 2 points, plus its 8-point text padding.
Honor the host field's keyboardAppearance independently of app appearance. Key
fills let the system-owned tinted backdrop through, with opaque accessibility
fallbacks; do not replace the system background with an opaque gray rectangle.
Production builds must not use private APIs for host-app switching. On 2026-11-16,
the user explicitly authorized a Debug-only local MVP experiment for automatic
keyboard → host microphone activation → source-app return. Keep this isolated,
use only a fresh destination for the current request, never a historical fallback,
and verify private hooks/selectors are absent from Release binaries. This exception
does not authorize other private APIs or App Store distribution.
Native keyboard parity is a design
target, not a claim: Apple's keyboard implementation is not available to extensions.
Build/test caches must be removed after work; keep the completed signed app in build/.
