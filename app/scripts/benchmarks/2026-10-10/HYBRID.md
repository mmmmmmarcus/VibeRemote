# Codex + Jev cooperation pilot — 2026-10-10

The production option is now Codex + Jev, not a standalone Calculator-only Jev
backend. Codex owns planning, writing, navigation and final verification. Jev can
choose successive exact-label controls in a single delegated window. The proxy
refreshes tokens, enforces the target/label/step limits and preserves the existing
foreground consent gate. Every batch returns a handoff, not overall task success.

## Initial end-to-end comparison

Same prompt: clear Calculator, calculate 128 × 36 by visible buttons, then read
back 4608. No prewarming, same Codex configuration, no foreground approvals.
Order: hybrid, baseline, baseline, hybrid. These are small exploratory samples;
independent TextEdit tests ran during portions of the pilot, so this is not an
isolated performance experiment.

| Backend | Seconds | Result |
|---|---:|---|
| Hybrid | 70.132 | Completed and independently verified; 8 Jev clicks |
| Codex | 73.037 | Completed and independently verified |
| Codex | 71.307 | Completed and independently verified |
| Hybrid | 120.041 | Benchmark deadline; Jev returned after 5 clicks, Codex continued and observed 4608, but the turn had not completed |

Do not omit the timeout or claim an overall speed/accuracy improvement. The app's
execution budget is longer than this benchmark, but that does not make the timed
sample a success. Default remains Codex; hybrid is explicitly experimental.

## Cross-application checks

- Through the installed command box in hybrid mode, Codex entered the exact Chinese
  test sentence into a newly created TextEdit document in 43.077 seconds. CUA read
  it back independently. This task correctly required no Jev batch.
- A natural-language full-document formatting request did not leave the four
  toolbar controls enabled. It is not counted as a successful end-to-end task.
- An isolated real Jev formatting batch exposed an inadequate state representation:
  it clicked bold, italic, underline, center, then bold again. This was a failure.
- Fixed the executor to include explicit control values/selection in decisions and
  prevent the same checkbox/radio label from being toggled twice in one batch.
- On the final installed build, the same isolated batch completed in 22.077 seconds,
  clicking each of the four controls once. All four values were 1 in a fresh driver
  read and a separate CUA read. Jev decisions took 10.656 seconds (5 requests).
  This verifies the generic batch in TextEdit; it does not establish general task
  accuracy or that all natural-language formatting requests work.

`hybrid-format.json` contains the final bounded-batch measurements.
`hybrid-final.jsonl` records the final post-fix end-to-end Calculator rerun.
No credential, prompt transcript, screenshot or real document body is stored here.

## Final installed-build rerun

The post-fix full hybrid run completed and verified 4608 in 85.728 seconds,
without foreground access. It first returned a zero-action handoff, then a driver
refusal after two Jev clicks. Codex re-read the current state and continued with
8, Multiply, 3, 6, Equals instead of replaying the two completed digit clicks.
This validates recovery, but is slower than both baseline pilot runs. It is not
evidence that hybrid should replace Codex as the default.

Final delivery: 168 tests, one resource test initially skipped and subsequently
passed against the final signed bundle; strict-concurrency build succeeded with
existing unrelated warnings. Installed arm64 bundle signature and file manifest
verified. No physical remote/dictation regression test in this change.
