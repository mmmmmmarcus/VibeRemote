# VibeRemote latency study — 2026-10-10

Status: read-only comparison and MCP connection tests completed. Live action
qualification encountered both a locked Mac and later target-observation failures. No accuracy-preserving replacement
has been accepted on the basis of these samples alone.

Environment: Apple Silicon macOS 27, native Codex CLI 0.161.0, Cua Driver 0.28.2,
existing local Codex login, foreground-consent proxy enabled. Baseline CLI selected
`gpt-6.1-sol`; model and effort were not explicitly pinned. Candidates explicitly
used low reasoning. No Fast/Priority service-tier upgrade was requested.

## Same live task: read Calculator's existing result

Three runs each. All returned the independently pre-observed 4,608. Each model used
fresh observed targets. Samples were interleaved; network/server variance is not
controlled. This small sample does not establish general computer-use accuracy.

| Configuration | Median elapsed | Range | Correct reads |
| --- | ---: | ---: | ---: |
| Original CLI defaults | 25.406 s | 18.060–25.933 s | 3/3 |
| GPT-6.1 Sol, low | 21.253 s | 20.138–26.304 s | 3/3 |
| GPT-6 Luna, low | 17.879 s | 15.426–80.154 s | 3/3 |
| GPT-5.6 Luna, low | 17.931 s | 13.833–71.049 s | 3/3 |

Luna's median is about 30% lower, but its first samples have substantially worse
tails. Sol-low's small median improvement overlaps the baseline range; do not call
that a statistically established speedup. Startup-to-MCP-ready ranged 0.184–3.754 s.
Most elapsed time is outside driver execution; this remainder includes model,
network and approval/scheduling time, not just inference.

## Connection warmup (five samples)

With the shared driver daemon already running:
- New proxy/connection + initialize + tools/list: median 0.0449 s.
- Tools/list on that initialized connection: median 0.0050 s.
- Difference: about 40 ms, under 0.2% of the baseline task median.

Do not add a persistent connection or switch harness architectures merely to save
this measured overhead. A cold daemon/system was not tested. An app-server spike
also confirmed that this installed CLI's app-server lacks exec's
`--ignore-user-config`; replacing the isolated exec path would require separately
validated configuration isolation and consent lifecycle handling.

## Live action qualification

The planned test clears Calculator, enters 128 × 36, and verifies the result from
the UI after the action. The Mac locked during these runs; Cua's independent
interactive check reported a locked Mac, and driver observations degraded to empty
AX trees. The affected samples are preserved in `calculate-excluded.jsonl`, excluded
from model accuracy claims. A fresh unlocked run is required before selection.

## Jev

OpenRouter documents `typesafe/jev-1.13` via its Decisions API. The separate
`typesafe/jev-router` found in the chat-model catalog is not Jev itself. The
synthetic fixture entry point is ready; request generation and rejection of
unexpected models/choices have been tested with local responses. No API key was
available, so no live Jev inference, latency or accuracy result is claimed.

## Verification harness correction

After unlock, the Calculator display was confirmed to be a non-actionable static
text row in `tree_markdown`, absent from the driver's indexed `elements`. The
verifier now recognizes that exact fixture row. Earlier `display_verified=false`
is not evidence of an incorrect calculation. One unlocked baseline finished in
81.551 s, but its verification parser was incomplete and compilation overlapped;
exclude it from speed/accuracy comparison. A later 64.822 s sample was aborted
when a target became degraded. The Mac was still accessible in an independent
check, so this must not be attributed to locking. Degraded target state alone no
longer invalidates the entire environment; recovery failures count against the run.

## Final unlocked action samples and decision

With the corrected display verifier, GPT-6 Luna low terminated after a failed
click (24.250 s, 0/1 completed tasks). GPT-6.1 Sol low performed the calculation
and independently read the expected 4,608 after its actions (80.805 s, 1/1).
This is too small and variable a sample to establish equal accuracy or a speedup.
Keep the original model/effort selection for this installed version. Do not enable
persistent prewarming for the measured 40 ms saving. The delivered improvement is
numeric stage diagnostics and reproducible opt-in evaluation, not a claimed runtime
speedup. Jev remains untested without an OpenRouter credential.

Validation: strict-concurrency build completed (existing warnings remain), 160
unit tests with zero failures and one bundled-resource test initially skipped;
the skipped resource test then passed separately against the signed app bundle.
The arm64 Developer-ID bundle was built for local installation.

Installed and relaunched successfully; installed file manifest matches the signed
bundle and signature verification passed. Post-install read-only command completed
and its capsule disappeared. Runtime timing: total 26.589 s, first event 5.533 s,
first tool 18.422 s, connection 0.066 s, driver 0.364 s over two calls, consent wait
0 s. Settings reported the aluminum remote connected. No physical button/dictation
retest was performed. Build caches were removed.

## Jev authenticated follow-up

The later authenticated run completed: 30/30 synthetic choices correct, median
1.384 s. See `JEV-RESULTS.md` and `jev-live.jsonl`; earlier statements that no key
was available describe the initial setup phase only. No executor change was made.
