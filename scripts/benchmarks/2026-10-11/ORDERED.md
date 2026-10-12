# Ordered cooperation pilot — 2026-10-11

Signed arm64 app installed and its full file manifest/signature verified. Settings
startup confirmed the new description, the user's selected hybrid backend and the
existing Keychain key. Build with strict concurrency passed (existing unrelated
warnings); 171 tests ran with one bundle-resource skip, and that resource test
subsequently passed against the final signed bundle.

## First comparison

Same Calculator task and prompt for both: clear, click 128 × 36, read back 4608.
No foreground approval, no connection prewarm. No concurrent Calculator test.

| System | Seconds | Outcome | Codex tool calls | Jev decisions |
|---|---:|---|---:|---:|
| Ordered hybrid | 66.956 | Completed; Driver observed 4608 | 4 | 6 |
| Codex baseline | 77.983 | Completed; Driver observed 4608 | 19 | 0 |

Hybrid's first malformed tool call failed without action; its second call ran the
eight-click sequence. Unique-label steps need no decision, but ambiguous matches
still required Jev, so this live run used six decisions, not the ideal single
final check. Nested Driver work took 22.456 s, Jev decisions 10.320 s; these are
already inside the outer tool duration, not additional time to add to the total.
The one successful pair is about 14% faster, not a general speed or accuracy claim.

## Interrupted reverse-order comparison

The next baseline sample completed without achieving the task in 105.302 s, with
two tool errors and no verified result. The following hybrid sample stopped after
26.083 s when an independent CUA observation explicitly reported the Mac locked.
Its environment-invalid flag is true. The exact lock onset is unknown: do not
retroactively call the preceding failed baseline a proven model failure or a
proven lock-only failure. Keep both raw samples, and rerun an unlocked pair before
making a reverse-order comparison. Do not include these as successful timings.

Raw data: `ordered-comparison.jsonl`. The harness stores numeric timings, tool
names and synthetic Calculator outcomes; no key, screenshot or unrelated app text.

See `JEV-DIRECTION.md` for the official Cua thread's implications and a proposed
typed/adaptive expansion. That broader capability is not implemented in this build.
Physical remote/dictation regression has not been tested during this update.

## Unlocked follow-up and hidden-candidate correction

The user unlocked the Mac. A read-only Driver inspection found each Calculator
digit twice: an AXButton with a 48 × 48 frame, and a hidden AXMenuItem without
any frame. These five false ambiguities account for the five extra decisions.
Candidates now require finite positive width/height and cannot be explicitly
hidden. Visible menu items remain eligible; the code does not blindly prefer the
first match. Missing geometry hands back instead of guessing.

Installed a new signed arm64 build with this filter. All 172 tests passed (the
bundle-resource skip passed separately against the final bundle). Signature and
complete installed manifest matched; Settings retained hybrid/key. No foreground
approval or extra Calculator interaction occurred during the sequential pair.

| System | Seconds | Outcome | Codex tool calls | Jev decisions |
|---|---:|---|---:|---:|
| Codex baseline | 71.331 | Complete, correct sequence and read-back | 18 | 0 |
| Filtered ordered hybrid | 55.806 | Complete, correct sequence and read-back | 3 | 1 |

Both performed All Clear, 1, 2, 8, Multiply, 3, 6, Equals in that order. A separate
CUA read after the pair showed expression `128 × 36` and result `4,608`. Hybrid
used one batch and one final Jev decision (1.935 s); there were no tool errors.
Nested Driver work took 22.172 s. The reduction versus this baseline is 21.8%;
this is one matched pair, not a broad accuracy or speed guarantee. The previous
unfiltered pair and locked samples above remain intact, not pooled with this build.

Raw data: `visible-comparison.jsonl`. This version additionally records the full
synthetic action sequence and `steps_verified`, so a pre-existing matching display
cannot pass without the required actions. Build caches were removed after testing.
