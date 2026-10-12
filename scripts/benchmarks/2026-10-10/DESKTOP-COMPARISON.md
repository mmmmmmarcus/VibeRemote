# Live desktop pilot: Jev adapter vs current Codex — 2026-10-10

Both systems operated the real macOS Calculator through the installed VibeRemote
foreground-consent proxy. No foreground consent was approved, and no production
executor setting was changed. Three tasks, two runs per backend (12 completed
samples). First round Jev first; second round Codex first. Initial zero-state reset
is outside timing for both. End-to-end time includes setup/discovery, inference,
actions, normal completion and final read-back. Expected results are checked by
code after execution, never supplied to Jev. No click sequence is pre-programmed
into its actor. Post-hoc action audit confirms every arithmetic/correction sequence.

| Task | Jev mean (individual runs) | Current Codex mean (individual runs) | Goal success |
| --- | --- | --- | --- |
| add | 28.74 s (26.87, 30.61) | 72.59 s (75.02, 70.16) | 2/2 each |
| multiply | 27.01 s (29.51, 24.50) | 68.28 s (69.56, 67.00) | 2/2 each |
| correct | 38.62 s (38.86, 38.39) | 71.75 s (74.38, 69.12) | 2/2 each |

Overall Jev mean 31.46 s versus Codex
70.87 s: 55.6% less elapsed time in
this small pilot. Both achieved the actual task goal in 6/6 completed runs.
Strict requested-step compliance: Jev 2/6; Codex 6/6. Jev omitted the redundant
initial Clear in all four addition/multiplication runs (the fixture already showed
zero), but performed Clear in both correction runs. This distinction must accompany
any success-rate statement. Correction was verified as 1,2,9,Delete,8,Add,7,Equals,
not merely an observed 135.

## Scope and interpretation

This is a comparison of execution systems, not a controlled model-only benchmark.
Jev 1.13-20260917 receives text-only observed display, fresh keypad candidates and
ordered action history. Its custom adapter discovers the Calculator window and
refreshes observations automatically. Codex retains VibeRemote's native CLI defaults,
isolated configuration, automatic review and own tool-planning loop. Both use the
same driver and foreground gate, but harness, modalities and review overhead differ.
The Jev adapter is intentionally restricted to Calculator keypad actions. The tests
do not measure novel text generation, browsers, document editing, window navigation,
complex recovery, or generalized safety. Two trials per task are too few to establish
population success rates or statistical significance. The local daemon was warm.
No cost comparison was captured.

## Interruptions and driver issues

One initial Codex addition attempt was interrupted by a Mac lock independently
confirmed by CUA. It is excluded from model scoring and preserved in
`desktop-pilot-interrupted.jsonl`. Two second-round reset attempts encountered
`degraded_target` before timing; independent CUA checks could still read Calculator.
They were retried and must not be attributed to a lock. One completed Codex addition
run recovered from a tool error. No completed failure was dropped. Setup failures
and the interrupted run mean these results do not establish unattended reliability.

## Artifacts and delivery

`desktop-comparison.jsonl` contains all 12 completed runs, numeric timings, selected
synthetic buttons and verification flags. The key remains outside the repository.
Scripts passed Python syntax validation and repository whitespace checks. No native
build or installation was needed; VibeRemote remains on its current Codex backend.

Jev's decision interface reference:
https://openrouter.ai/blog/insights/what-is-jev/
