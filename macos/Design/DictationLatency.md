# Dictation latency — 2026-11-28

All three platforms send audio to Seed live and nostream refinement concurrently.
The final polish still requires complete JSON, and insertion retains each platform's
existing document ownership and cancellation checks.

## Completion policy

- macOS streaming: allow refinement 1.5 seconds after capture ends, then use live
  text. Only an utterance without usable text falls back to flash (6-second hard
  budget). Non-Seed provider recognition is unchanged. Non-streaming Seed still
  uses refinement then bounded flash because there is no live transcript.
- iOS: preserve its 1.5-second refinement, 5-second no-text wait, and one 6-second
  retry. Results now notify the keyboard on the next main turn; the 80 ms polling
  watchdog remains for document validation, deadlines and deferred editor writes.
- Android: allow refinement 1.5 seconds after release, then use live text. If no
  text is available, allow up to 5 seconds, keeping the best available text then.
  No full-audio retry is added. Android system speech fallback retains its outer timeout.
- All: ordinary polishing gets 3 seconds; mobile explicit translation gets 8.
  On timeout keep recognized text; never apply a later replacement.
- All: skip ordinary polishing at <=6 weighted units (Han scalar=1, Latin/digit
  word=1.5); translation is exempt. Apply final punctuation even on bypass/fallback.
- After release, at most one live final can start speculative polishing. Reuse
  only if the cleaned selected transcript matches exactly, including punctuation,
  and mobile translation mode matches. Otherwise cancel and start for the chosen
  source. A completed speculative result never commits before recognition selection.
  It can cost one extra Ark request per hold; no speculation while recording.

## Capture and measurement

Packets default to 100 ms (3,200 bytes of 16 kHz mono PCM16). Set the internal
`dictationAudioPacketMilliseconds` integer to 200 to compare with 200 ms.
Apple uses standard defaults; Android uses the existing `keyboard` preferences.
Apple packet size is captured when the session is constructed. No provider VAD or
punctuation flags changed. Every final packet flushes the remaining PCM.

Siri and Soundcore release buffer durations are unchanged. macOS records physical
release before the buffer and captureStopped afterwards. Soundcore re-press clears
that release timestamp; the next release owns the metric. These fields distinguish
intentional capture tail from recognition latency. No idle microphone or new capture
prewarming is introduced. iOS already loads its bundled capture page on attach;
micLive measures on-demand capture startup separately. iOS captureStopped measures
the native stop request, not a WebKit hardware acknowledgement.

Timing records contain durations and fixed labels only, never text, audio, keys,
provider bodies, or editor data. Keep the latest 200 records:
- macOS: ~/Library/Application Support/VibeRemote/DictationTiming.json (0600).
- iOS: existing App Group DictationTiming.json and Dictation Timing export. Includes p95.
- Android: no-backup files/DictationTiming.json, app-private; a debuggable private build
  can export with adb exec-out run-as app.vvhisper.keyboard cat no_backup/DictationTiming.json.

Use `python3 macos/scripts/summarize-dictation-timing.py <export.json> ...` to compare
median/p95 by input and packet duration. Missing stages are not counted as zero.
Polishing may overlap recognition, so these durations must not be added together.
macOS polishDuration measures the remaining blocking wait; mobile polishDuration
measures request completion, including speculative requests. Compare release-to-committed for
end-to-end results. Android committed means the InputConnection accepted the write,
not a rendering acknowledgement. macOS one-shot committed means events were posted.

## Verification and limits

Automated cases exercise deadlines, late callbacks, cancellation, short-text rules,
matching/mismatching speculation and stalled refinement. No real-device latency or
accuracy gain is claimed from those tests. Run the same short/long English, Chinese,
mixed-language and named-entity phrases with 100/200 ms packets on each device,
including cold starts, repeated holds, slow networks, and typing during polish.
Measure firstText and release-to-committed median/p95; separately compare final words,
punctuation, clipped endings and speculative reuse rate. Keep private binaries local.

Validation completed for this change: macOS 454 tests (one skipped), strict-concurrency
build, script syntax and entitlement checks; Android 25 unit tests, debug APK,
instrumentation-test APK compilation and lint; iOS signed device build and 53 focused
dictation tests. The first full iOS run executed 380 tests and found one timing-accounting
failure; that was corrected and its suite passed in the focused rerun. Instrumented
Android tests were compiled, not run on hardware. No installed app was replaced.

Before pushing, the isolated dictation changes were applied to current main and Android
build, lint, instrumentation APK compilation and all 23 unit tests passed again.
Unrelated local keyboard changes were excluded.
