# Command latency and model evaluation

These are opt-in developer benchmarks, not background telemetry. The live benchmark
uses the installed VibeRemote MCP proxy and never approves foreground requests.
Keep the Mac unlocked and Calculator available; do not interact with Calculator
while a batch runs. An explicitly locked desktop aborts the batch. An unresolved target alone does
not prove a locked desktop and must not be excluded automatically.

## Live Codex / Cua comparison

```sh
python3 scripts/benchmark-command.py --models baseline,gpt-6.1-sol,gpt-6-luna \
  --tasks read --repeats 3 --output /tmp/viberemote-read.jsonl
python3 scripts/benchmark-command.py --models baseline,gpt-6.1-sol,gpt-6-luna \
  --tasks calculate --repeats 3 --output /tmp/viberemote-calculate.jsonl
```

`baseline` leaves model/effort unspecified, matching the original app. Named models
use `low` reasoning. The read fixture expects Calculator to display 4,608. The
calculation fixture clears and computes 128 × 36, and requires an observed result
after a successful action. Do not compare `read` and `calculate` as one workload.
Record inference access failures, rejected actions and slow samples, not just wins.

The harness retains only timing, tool names, boolean outcomes and the synthetic
Calculator result. It does not retain command output, screenshots, arbitrary AX
text, or credentials. Task directories are removed after each run. Runtime app
logging likewise records only numeric stage totals; waiting for human foreground
consent is separate from driver execution.

`first_event_seconds` includes CLI startup and readiness, `first_tool_seconds`
includes startup plus waiting for the first tool request. `tool_seconds` measures
actual proxy round trips. `other_seconds` is the remainder: it includes model,
network, automatic review, and scheduling. It is **not** pure inference time.
`--prewarm N` is an experimental exec-process warmup before delivering stdin; its
cost is explicitly included in `launch_to_finish_seconds` and reported separately.
It must not be described as MCP connection reuse.

## Connection-only warmup

```sh
python3 scripts/benchmark-cua-connection.py
```

Five fresh-process `initialize` + `tools/list` samples versus a subsequent
`tools/list` on the same live connection. This measures local connection/schema
overhead with the existing daemon running. It does not measure a cold machine,
a cold daemon, model inference, or end-to-end task latency. Never stop the user's
shared daemon to manufacture a cold start.

## Jev through OpenRouter

Jev is a typed decision model, not a drop-in replacement for the Codex CLI tool
loop. This entry point evaluates ten synthetic next-action fixtures. It never
reads or operates the desktop, and does not participate in foreground approval.
It is intentionally not enabled as the app's executor until end-to-end evaluation.

```sh
# Validate payloads without a key, network request, or billable inference:
python3 scripts/benchmark-jev.py --dry-run

# Supply an existing OpenRouter key via the environment, or a private local file.
# Never put a real key in command arguments, Git, documentation, or chat.
python3 scripts/benchmark-jev.py --key-file /absolute/private/path/openrouter-key \
  --repeats 3 --output /tmp/viberemote-jev.jsonl
```

Alternatively, the script reads `OPENROUTER_API_KEY`. It calls only
`https://openrouter.ai/api/alpha/decisions` with `typesafe/jev-1.13`. It does not
substitute `typesafe/jev-router` (a router to other models) or silently fall back.
Unknown choices/models are rejected; authentication, billing, availability and
rate-limit errors stop the run. Confidence is recorded but never treated as proof
of correctness. Candidate order is deterministically shuffled. No real Jev score
exists until an authenticated run is completed.

Primary interface references, verified 2026-10-10:
- https://openrouter.ai/blog/insights/what-is-jev/
- https://docs.typesafe.ai/introduction/quickstart

## Live Jev versus current Codex (Calculator pilot)

```sh
python3 scripts/benchmark-desktop-jev.py \
  --key-file /absolute/private/path/openrouter-key \
  --repeats 2 --output /tmp/viberemote-desktop-comparison.jsonl
```

Keep Calculator open in Basic mode, Mac unlocked, and leave Calculator untouched.
This opt-in test controls real Calculator buttons through the installed VibeRemote
foreground-consent proxy; it never approves foreground access. Three goals cover
addition, multiplication and correcting a mistyped digit. Both systems receive the
same task, get a verified zero-state reset outside the timed portion, and must use
visible keypad buttons. Each task includes final UI read-back in elapsed time.
Jev gets candidate controls derived from fresh AX state and a bounded history;
no expected answer or click plan is sent. The adapter automatically discovers the
Calculator window and refreshes after every click. Codex uses the existing isolated
CLI configuration and performs its own discovery/observation. This compares two
execution systems, not identical model harnesses. It does not establish general
browser, text entry, document editing or cross-app performance.

The `correct` flag is strict: requested Clear/Equals (and Delete in correction)
must be present as well as the expected observed final value and normal completion.
Report achieved end state separately from this instruction-compliance check,
including redundant Clear omissions when a fixture already starts at zero.
Keep interrupted/setup-invalid runs separate; never silently drop completed failures.
The test adds no production executor and stores only synthetic Calculator data.


## Codex + Jev cooperation

The selectable hybrid uses Codex for planning, text, navigation and verification,
and `jev_click_sequence` for bounded runs of explicitly allowed controls in one
window. Standalone Jev is no longer a product option. Configure the OpenRouter
key in Settings; it stays in macOS Keychain, never in benchmark output.

Run `benchmark-command.py --models baseline,hybrid --tasks calculate --repeats 2
--output <path>` against the installed signed build. Both versions use visible
Calculator buttons and the same task; hybrid may delegate the sequence. This
comparison includes Codex planning/review/verification and Jev's decision latency,
unlike the earlier standalone actor comparison. The benchmark never approves
foreground requests. `jev_clicks` counts attempted actions returned by the batch.
Completion requires the expected result in Driver evidence captured after the
actions, either returned by a finished ordered batch with its observation timestamp
or from a later Codex UI read. Jev's completion opinion alone never counts.
`driver_metrics` includes numeric Jev decision count/time and nested Driver work;
do not add those durations to the outer batch duration, which already includes them.
New runs also store the synthetic `action_sequence` and `steps_verified`: the
calculation must start with Clear/All Clear and perform the requested keypad sequence.
Older files without these fields predate this additional instruction-compliance check.
Keep the Mac unlocked, leave Calculator idle, and treat small samples as pilot
evidence, not a general speed/accuracy guarantee.
