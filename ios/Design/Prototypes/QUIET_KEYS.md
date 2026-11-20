# Quiet Keys — motion pitch 05

A quiet acknowledgement of the microphone, while attention stays on streamed text.
Open `quiet-keys.html` directly or at the local preview server. Everything is inline;
there are no external assets, analytics, microphone requests or recordings.

## Two directions

- **A · From the center — recommended.** A small central group of keys brightens
  with soft speech. The group widens as the level rises. It has no travelling wave,
  scatter or stagger. The effect should be readable peripherally.
- **B · Left to right.** The same key surfaces act as segments of a familiar level
  meter. It communicates amplitude more literally but introduces a stronger direction.

Both retain the keyboard's geometry and hit targets. Only key fills and legend
opacity change. Functional icons (Delete, Shift, Return and emoji) remain legible.
The candidate strip has no effect or status label during voice input. Only errors
or microphone activation would need functional messaging in the native product.

## Choreography

| Moment | Response |
| --- | --- |
| Hold recognised | Letter legends fade together over 120 ms; no spatial movement. |
| Speech | The key brightness field follows a smoothed level, with a 70 ms attack and 240 ms release. |
| Silence | Below the 10% prototype noise gate, the field settles to zero; letters stay hidden while listening. |
| Release | Letters return over 120 ms; the brightness field settles. No polishing effect on the keyboard. |
| Result | The synthetic draft is replaced in the editor, without an arrival animation. |
| Cancel / page hidden | Clear the scene, cancel frame/timer work, restore the keyboard. |

On light appearance, white is composited at at most 38% over a near-white listening
key; the resulting brightness shift is only about eight RGB levels. Dark appearance
uses at most 10% white over the charcoal key. These are draft values to judge on-device.
There is no bloom, outer glow, scaling, color cycling or animated key outline.

Mini mode hides the strip. The wide Dictate key uses a shallow, soft fill in its own
bounds; the bottom keys participate in the same quiet meter. It introduces no new
control or moving geometry. Reduce Motion keeps a low stationary indication while
voice is present, without varying its extent or animating the letters.

## Reviewing the prototype

- Play a sentence to see streaming, pauses, release and final replacement.
- Hold any letter key or the Hold to try button; release to finish.
- Select Silence / Soft / Normal / Strong or drag Voice level for direct comparison.
- Switch A/B, Full/Mini and light/dark. Escape cancels. Keyboard activation is supported.
- The demo uses simulated voice levels and synthetic Chinese/English text. It does
  not measure your voice or run recognition; it never requests microphone access.

## Native scope

Native visibility refinement (2026-11-18): the original HTML study above retains
its draft tuning. The app now uses a 6% gate, square-root sensitivity curve,
35 ms attack and 140 ms release. Pale caps receive up to 20% black ink; dark
caps receive up to 32% white. Opacity and width follow volume. Reduce Motion
retains a fixed extent with maximum 8% ink / 12% white. This supersedes the
native sensitivity/contrast values below; PCM gain and IPC cadence stay the same.

Direction A is now implemented in UIKit in full and mini mode. The older molecule
renderer has been removed. The strip stays empty through recording and pending
refinement; streaming text, final replacement and submission safeguards are unchanged.

The existing host audio tap measures RMS on the ASR PCM, mapping -55…-15 dBFS to
0…1 before the prototype's 10% gate. A session-scoped scalar and timestamp cross the
App Group at most 20 times per second; no audio crosses into the extension. Readings
expire after 300 ms. Wrong/old session IDs, out-of-order/future/invalid readings and
changed text destinations cannot drive feedback. Missing readings decay to silence.
The meter never serves as proof of microphone readiness or transcription success.

Only keycap layers and legend opacity change. Core Animation interpolates bounded
updates without a display link. Cancellation, errors, layout changes and dismissal
clear feedback immediately; release restores legends over 120 ms with no polish loop.
Reduce Motion uses one stationary center extent while speech is above the gate.
The light/dark shades preserve the native translucent keyboard backdrop.
On the physical Duo, the light base shade was tuned to 3.5% black (dark: 4%);
9% made the keycaps blend into the system backdrop. Both full and mini holds,
legend restoration and the quiet strip were checked on the signed installed build.
The native suite passed 180 tests before that final shade-only adjustment; the
final shade was verified physically in both modes.

The Emil design-engineering guidance informs the short interruptible transitions,
restraint for a frequently used input method, and the reduced-motion alternative.
The 1Password preview mark follows the earlier prototype; see THIRD_PARTY_NOTICES.md.
