# Current proposal: Quiet Keys — study 05

Open [quiet-keys.html](quiet-keys.html) for the current pitch. The user retired the
candidate-strip animation in favor of subtle voice-level feedback on the keycaps.
The page compares center-out and left-to-right meters, including full/mini and
light/dark. [QUIET_KEYS.md](QUIET_KEYS.md) records the motion rules and boundaries.

The candidate-strip effect has been removed in native source. The proposed key
meter is HTML-only; the existing native mini-key effect is unchanged until the
replacement is chosen. Older molecule prototypes below are historical references.

# Historical: Updraft — molecule motion study 04

Open `dictation-strip.html` directly or serve this directory with a local HTTP
server. It is a self-contained, offline HTML study. Its approved choreography is
now implemented by `Keyboard/DictationMoleculeView.swift` and
`Shared/DictationMolecules.swift` (paths relative to `ios/`). The HTML itself requests
no microphone, clipboard, account, telemetry, or external asset access.

**Native follow-up (2026-11-18):** the device version has since been refined to
four particles per visible Han character and one per other letter/digit, with no
time multiplier. Its listening cloud is vertically narrower, and release flies
directly from the live cloud in 330 ms without gathering. This HTML remains the
approved study 04 reference; its choreography below describes that earlier draft.

## Choreography

1. **Accumulate.** Start empty. Each recognized letter, number, or Chinese
   character creates one monochrome molecule. After two seconds of simulated
   speech, a duration-based multiplier gradually increases the density. The first molecules form in a compact central cluster; new molecules spread
   farther out as density grows. Molecules remain suspended until release; silence
   stops population growth. A hard cap of
   320 keeps long holds bounded. White/silver in dark mode, graphite in light mode.
2. **Gather.** On release, the existing field briefly aligns over 140 ms. The
   formation stays within the cloud's existing width, avoiding an outward jump.
3. **Send.** At 160 ms, every molecule departs together. One shared 330 ms
   accelerating motion pulls the entire formation toward a 22-point-wide receiving
   opening at the top center. A 30-point soft rim makes the destination legible.
   Fine, tapered comet tails follow each curved path. There are no row delays;
   the complete gather-and-send choreography takes about half a second.
4. **Deliver.** The polished text replaces only the synthetic draft shown in the
   editor. A small neutral arrival glow fades and normal keyboard controls return.
   Cancelling restores the prior editor text immediately.

The effect stays inside the existing 44-point strip. There is no transcript,
status label, rainbow light, or new control inside the keyboard animation.

## Controls

- **Play the journey:** a full hold → arrange → send → delivered sequence.
- **3 s / 8 s / 15 s:** run different hold durations to compare buildup.
- **Hold to speak** or hold a letter: release starts the polishing choreography.
- **Listening:** watch accumulation until you choose another state.
- **Arrange / Send:** inspect still frames of the formation and comet paths.
- **Voice energy:** zero pauses synthetic speech and additional molecules.
- **Reduce motion:** stationary accumulating dots, then a still ordered formation;
  no comet travel. Text updates and final replacement are retained.
- **Appearance:** inspect the same neutral material on light and dark keyboards.

The left detail view magnifies the same canvas scene by 2×. Character/molecule
counts and hold duration are prototype review aids outside the phone, not product
UI. The page stops its animation and text timers when hidden.

## Implementation and limits

One Canvas 2D scene feeds both views. DPR is capped at 2, particle count at 320,
light uses a cached neutral sprite, and movement uses elapsed time. There are no
animation frames while idle, inspecting a still frame, or under Reduce Motion.
During reduced-motion listening, new recognized characters redraw the still field.

Polishing duration is simulated for the HTML study. The native version consumes
weighted visible ASR character counts, without adding an audio-level IPC
stream. Actual final text is inserted immediately, shortening the visual sequence
when necessary. Once the direct 330 ms send finishes, a still receiving rim waits
for a slower result, without a looping progress animation.

In full mode the native canvas occupies the candidate strip. Mini mode clips the
same scene inside the Dictate key, with a narrower receiving rim and a lower
particle cap. Shift, Delete, Return, hit targets and gestures remain separate.
Cancellation, dismissal and layout changes clear the scene; stale replies cannot
restart it. Reduce Motion uses stationary dots without travel.
Physical dictation, perceived smoothness and device power use require device review.

## Continuity and references

- `archive/dictation-strip-v3.html`: the first monochrome formation and staggered comets.
- `archive/dictation-strip-v2.html`: the colored Updraft particle exploration.
- `archive/dictation-strip-v1.html`: the earlier Signal / Halo exploration.

The earlier reference review covered [Siri's current luminous material](https://www.apple.com/apple-intelligence/)
and [its earlier screen-edge light](https://www.apple.com/newsroom/2024/06/introducing-apple-intelligence-for-iphone-ipad-and-mac/).
This revision follows the user's specific direction: monochrome molecules,
cumulative buildup, formal arrangement, and comet-like delivery to the top center.
No Apple artwork or animation assets are bundled.

The Emil design-engineering skill informs state continuity, short control
responses, immediate cancellation, and the reduced-motion alternative. The brief
material choreography is confined to the simulated processing state. The existing
1Password SVG attribution remains in `../../THIRD_PARTY_NOTICES.md`.
