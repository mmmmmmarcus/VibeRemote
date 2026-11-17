# Keyboard touch accuracy

The visible keycap and the area that accepts a tap serve different purposes.
We can make the keyboard more forgiving without moving its visible keys.

The starting implementation only accepted touches within each key view. Its gaps
were unassigned. It also cancelled the previous key when another finger touched
down, so overlapping thumb presses could lose a character. Capitalization rebuilt
the key views, which could invalidate a finger already resting on the next key.

## Implemented first pass

`KeyboardTouchSurface` resolves a touch against all visible controls. A touch
inside a key's rectangle always selects that key. Nearby whitespace selects the
nearest rectangle edge, capped at 14 pt horizontally and 10 pt vertically. One
central resolver gives each point one owner. The split keyboard's large empty
center, accessory spacers and candidate strip are not converted into key targets.
The system keyboard-picker button retains its native input-mode-list action on
its keycap. Gap targeting goes to ordinary key controls so gap holds can dictate.
The press origin is latched: direct function-key holds keep their normal behavior,
while a gap hold uses the dictation threshold, including beside Delete and Return.
Quick gap taps retain the chosen key's tap behavior and destination guards. The
large split center, accessory spacers and candidate strip remain excluded.

When another finger lands, a pending character, Space, Shift or Delete tap commits
in press order. Its later release/cancellation and stale hold timer do nothing.
Already-recognized holds never produce an extra character. Return and layout
switches are cancelled on overlap rather than submitting or changing modes from
another finger's press. Capitalization updates the existing key legends and Shift
icon, preserving key identity under the fingers. Explicit layout/orientation
changes still cancel active touches.

One character balloon previews the current letter/case or symbol on touch-down.
It is drawn above its key within the extension bounds, with edge clamping,
light/dark colors and a subtle shadow. It neither intercepts touches nor moves
keys or candidates. Release, cancellation, dictation start and layout/dismissal
hide it; a late release from an older finger cannot dismiss a newer preview.

This is deterministic geometric targeting, not a language model or autocorrection.
Typing remains local, with no touch-position logging, learned profile or network
request. Separate Chinese and English modes remain the default. The optional
Mixed Chinese & English candidate setting does not change touch targeting.

## Predictive targeting direction

Apple's [published keyboard design](https://patents.google.com/patent/US8232973B2/en)
describes adjustable invisible hit regions informed by preceding input. That
publication establishes the design approach, not the exact behavior of current
iOS releases.

A later experiment can combine touch position with the probability of the next
letter. Keep a protected center for each visible key and adjust only ambiguous
boundaries between neighboring letters. Bound the displacement so a prediction
cannot steal a deliberate central tap or reach Delete, Return, language/emoji,
Space, the candidate strip or the split center. Freeze interpretation for a given
touch so an asynchronous prediction cannot change its destination mid-gesture.

Chinese probabilities must follow the current Pinyin composition; English needs
an English model. Do not silently enable mixed-language mode detection through
touch targeting; mixed candidates require the separate Settings opt-in. Missing or stale
context, names, URLs and uncertain predictions should fall back to geometric
targets. This predictive experiment is not enabled in the current build.

## Verification

Automated checks exercise actual view hit testing at key centers and horizontal/
vertical gaps across phone and all four Duo layouts. They also cover split-center
exclusion, overlapping thumbs, one-shot capitalization, Delete repeat, stale
releases/holds and preventing overlap from submitting Return or switching modes.
Real typing comfort and error rate require the user's later physical comparison;
automated checks do not establish native-keyboard parity.
