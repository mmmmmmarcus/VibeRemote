# Performance update — 2026-10-22

Baseline source: `75c6178`. Same Apple Silicon Mac, macOS 27.0.1.
This is an implementation/verification report, not physical-remote acceptance.

## Changes and preserved behavior

- Capture reader: filesystem notifications with a fixed 20 ms batching window; 1 s safety polling when open, 100 ms retry when missing/denied. Parsing on a serial worker, bounded ordered delivery mailbox on main. Only the explicit NX `pollNow` flush waits for the worker. Original timestamps, source filtering, all touch frames, reset order and replay rejection retained. Busy Bluetooth traffic may still trigger 50 reads/s; the idle benefit does not remove Apple's PacketLogger cost.
- Caret: serial background read-only geometry queries for tracking/watchdog. One active plus latest pending request, epoch/session cancellation, separate marker caches with queued cleanup. Results target the latest aim. Entry, lift settlement and final commit retain synchronous fresh editor checks. No mouse or selection writes in the worker.
- Preview: direct MCP reply is sent before optional presentation refresh. Reuse exact-target observation screenshots; omit duplicate AX-only same-target refreshes. Failures/end clear stale frames. Driver transport remains serial: a following call can still wait behind a capture already in progress. Nested Jev replies remain internal.

## Repeatable tests

Full strict-concurrency SwiftPM build succeeded. 191 tests executed, zero failures, one final-bundle test initially skipped and separately run against the signed app. Existing unrelated Swift concurrency warnings remain in voice output/input handling; none were introduced by these changed paths.

New coverage includes original button order/time, NX flush/no duplicate edges, both-generation touch freshness, missing-file reopen, split lines, source/replay filtering, atomic replacement/truncation, callback stop/restart, caret cancel/re-entry/full-entry/commit, queued cache cleanup, preview target/error/reuse/end-session and reply ordering.

Measured fixture output (not real AX timings):
- 21 requests with a 40 ms slow provider: synchronous UI work 969.3 ms; optimized submission 0.015 ms with two background reads. Intermediate requests are deliberately coalesced; final request is retained.
- Empty capture file: 0 reads during a 250 ms observation after initial open (old timer would schedule about 12–13 checks). Safety check remains once a second.
- Ordered button notification delivery 22.5 ms; aluminum/glass touch age about 17.0 ms, within unchanged 180 ms freshness bound.

`preview_protocol_benchmark.py` runs each real VibeRemote proxy executable against the same fake Driver (60 ms screenshot + 20 ms cursor delay), with eight alternating read/click calls separated by 450 ms. It performs no actual computer input, network request or account access. JSON records reply latency, extra RPC counts and preview cleanup. Compare installed release baseline `preview-before.json` to final release `preview-after-release.json`; debug exploratory results are separately labeled.

## Live measurement limits

`measure_processes.py` records 30 s CPU time deltas, RSS and capture-file growth without reading packet contents. Before/after live windows use the same script, but Bluetooth traffic and human activity are uncontrolled; do not claim a percentage speedup from unequal traffic. RSS excludes compressed memory and is not a leak metric. Samples are in `before-live*.json` and `after-live.json`.

Physical remote testing still needs the user: caret preparation/travel/lift/confirm, directional keys, Advanced Menu without system mute/play, Siri hold and audio tail. Real model task speed and arbitrary editor compatibility cannot be established by synthetic fixtures.

Final release protocol result: mean direct reply 92.20 ms → 4.47 ms; extra preview RPC 16 → 10. Both created preview and removed it at end_session. Release-build fixture includes host scheduling noise; not a real model/desktop benchmark.

Live follow-up: app CPU 2.062% → 0.732% of one core, but capture volume 16502.8 → 5068.4 bytes/s. Traffic decreased substantially: this is not a controlled estimate of CPU savings.

## Installed build and desktop smoke checks

The Developer ID-signed arm64 bundle was installed in `/Applications/VibeRemote.app` and relaunched. Its executable hash matches the completed bundle, deep/strict signature verification passed, the existing aluminum remote reconnected, and Settings retained its Siri/backend/idle preferences. Build caches were removed after all tests and builds finished.

Two commands submitted through the installed command bubble completed without a tool call (12.884 s and 17.204 s). They are **not successful task samples**. Initialization/tool discovery succeeded, but neither Driver actions nor preview refresh ran. Their final responses were not retained, so the reason is unresolved; do not attribute them to preview latency or claim the app's entire task flow passed.

A subsequent bounded diagnostic using the same hybrid CLI configuration and installed proxy, with explicit Calculator context, completed in 67.514 s. It reported 6 × 7 = 42; an independent live accessibility inspection confirmed Calculator's expression `6 × 7` and result `42`. This verifies one real operation through the updated proxy, not comparative model speed or picture-in-picture rendering in the app. Diagnostic stdout was inspected in memory and the temporary task directory was removed.
