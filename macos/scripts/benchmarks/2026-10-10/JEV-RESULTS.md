# Jev via OpenRouter — live test, 2026-10-10

Model returned: `typesafe/jev-1.13-20260917` via Decisions API.
Ten synthetic multiple-choice next-action scenarios, three repetitions each.

- Correct choices: 30/30.
- Median client-observed response time: 1.384 s.
- Mean: 1.555 s.
- Range: 1.112–3.056 s.
- Request/validation errors: 0.

The scenarios cover background launch, observed results, stale targets, foreground
consent, cancellation, untrusted page instructions, completion verification,
ambiguous deletion and routing prose generation to a writer. The options are
hand-authored and intentionally simple. Repetitions are not independent new cases;
30/30 does not establish general accuracy or robust prompt-injection resistance.
Latency includes client/network/provider time, not pure inference. These are not
live desktop tasks and cannot be compared directly with the earlier Codex task
latencies. No Cua actions were performed and VibeRemote's executor was not changed.

Credentials were read from the private external key file; only fixed fixture IDs,
choices, model, confidence and timings are retained. Confidence is not a correctness
or authorization guarantee. No billing-cost measurement was collected.

Next useful evaluation: construct candidate actions from fresh UI state and test
multi-step completion, parameter selection, recovery and end-to-end latency through
the existing foreground-consent gate before considering integration.
