# Soundcore Work voice input

Scope: Chinese D3200 as live voice input for vvhisper Dictation and Auto Computer Use.
The user reports firmware **4.92.3.06**, also listed in the reference protocol notes:
https://github.com/tacshi/Soundcore/blob/main/PROTOCOL.md

## Transport

Native CoreBluetooth discovery and GATT control, P-256 ECDH/HKDF session setup,
AES-CTR decryption and native 16 kHz mono Opus decoding. Audio stays in memory in
vvhisper. Existing dictation streaming, refinement, dictionary and focus handling
are reused. No recorder library, export, deletion, binding, firmware update, vendor
cloud or system microphone driver is added. Firmware may retain audio on the unit.

Connect once in Settings > Soundcore Work after disconnecting the phone Bluetooth link;
keep the official app pairing intact. After the secure handshake, vvhisper remembers the
peripheral UUID and advertised device address. It reconnects to that verified device on
app launch or when the device advertises again after a dropped connection. Mac system
Bluetooth pairing is unnecessary. Manual Disconnect/Stop Searching pauses reconnect for
the current app session; Reconnect or reopening vvhisper resumes it. No capture starts
until the user triggers voice input.

Background discovery uses 30-second open BLE scans with duplicates disabled and a
three-second pause between scans. Connection failures back off 3/6/12/24/30 seconds.
Only fresh advertisements or system-connected peripherals can trigger a reconnect;
cached disconnected IDs are never treated as evidence of proximity. Unknown devices
still require manual selection. The secure handshake remains mandatory on each connection.
The international 03.58 blue-light Dictation Mode instructions are not established
for this Chinese firmware and are not part of this integration.

Start snapshots existing frame counts before enabling capture. Only the current
live ID is requested; earlier frames and duplicates are discarded. The verified
transfer/key survives microphone pauses, and each new hold arms its boundary before
resuming. A new transfer uses buffered offset zero to recover audio captured during
startup. The first eligible packet anchors the sequence; subsequent gaps fail closed.
The former realtime mode was observed starting at sequence 24 despite zero offset;
buffered mode delivered sequence zero in the controlled startup tests below.
Release pauses capture, with a bounded tail drain. Missing audio times out after
eight seconds; sessions are limited to 115 seconds. The eight-second local test
measures decoded audio without transcription or saving an audio file.

## Evidence (2026-11-16, reference-aligned build)

Reference commit d296a1c5c0645797ff7cd3b55e93477a99820857; see ReferenceParity.md.
The earlier repeated-capture failure came from a Swift-only fatal check on trailing
header metadata 4. Upstream realtime_stream.dart does not reject this byte; the
native port now follows that handling while retaining packet rejection, matching
ID and cryptographic key-magic validation. Extra transfer-close commands removed.
The initial port used received payload-byte offsets as upstream does. This was later
superseded by retaining the active transfer across holds and using buffered offset-zero
requests only when opening a transfer; see ReferenceParity.md for the controlled tests.

- 381 automated tests, one existing skip, zero failures. Strict concurrency build
  passed without warnings. Personal signed build installed at /Applications/vvhisper.app.
- Fresh-discovery reconnection succeeded; removed cached disconnected picker rows
  that had produced repeated connection timeouts. Nearby RSSI is visible.
- Hardware local capture: 7.24 seconds, RMS 0.0062427577.
- Consecutive resumed capture: 7.68 seconds, RMS 0.045344975. Header metadata 4,
  valid wrapped key, contiguous live audio beginning at sequence 386.
- Cancel Voice Input returned to Connected. Subsequent local capture: 7.88 seconds,
  RMS 0.044738363; metadata 4, live sequence 1164, baseline 1164.
- Dictation pane confirms Soundcore Work selected for Right Option. An earlier real
  user hold reached Seed streaming/refinement and produced 47 characters.
- Local test audio is memory-only. No archive export, deletion, binding or firmware
  commands were used. Firmware may retain recordings on the device.
- Subsequent user test confirmed correct visible text insertion using Right Option and
  Soundcore through Seed ASR. Logs recorded 2.5 seconds of audio and final text settling
  0.54 seconds after release. Computer Use routing and long-duration reliability remain
  separate validation items.

## Automatic reconnect validation (2026-11-16)

Fourteen Soundcore tests pass, including remembered identity serialization, address
matching across transient CoreBluetooth UUIDs, rejection of other devices, manual pause,
and capped retry backoff. The strict-concurrency build passed without warnings.

The signed installed build remembered the physical device after a fresh handshake.
Manual Disconnect stayed disconnected. Restarting vvhisper at 15:07:17 CST automatically
found the remembered device at 15:07:18 and completed its handshake at 15:07:21, without
Find/Connect interaction. Settings showed Connected and 100% device/case batteries.
Physical sleep/wake recovery is a separate pending hardware check.

## Audio stall investigation (2026-11-16)

After several successful resumed holds (the last captured 17.8 seconds), the next
request returned a valid matching header but no audio slices. Repeated requests
still received control acknowledgements and zero frames. The initial eight-second
local reproduction also received zero frames. This was upstream of transcription;
BLE connectivity alone did not establish microphone health. A fresh BLE connection
and secure handshake restored 7.22 seconds of decoded audio. The precise trigger
inside the repeated transfer session remains unconfirmed.

Missing-packet timeouts, decoding/transport errors, and a normal-length hold ending
with zero packets now invalidate audio readiness and recover the Bluetooth session.
Recovery pauses capture, waits for its acknowledgement (bounded to one second),
then reconnects via the verified-device policy. It never reopens capture or replays
speech automatically. Brief taps are exempt from zero-frame recovery; quiet but
valid audio packets are not a transport failure. Fifteen Soundcore tests and the
strict-concurrency build pass. Hardware repeat/recovery checks follow separately.

The installed recovery build completed eight consecutive local captures without a
stall: 7.24, 7.68, 7.68, 7.90, 7.88, 7.92, 7.90 and 7.68 seconds, all with nonzero
signal. A subsequent user hotkey hold delivered 9.2 seconds to Seed ASR, producing
112 characters and settling 0.87 seconds after release. The automatic recovery
branch did not trigger in this run, so it is code/test verified, not yet verified
against a second spontaneous hardware stall. The original stall was reproduced
and manual session reset was hardware verified before applying the recovery change.

## Transfer lifetime fix validation (2026-11-16)

The signed installed build completed twelve sequential captures at 16:22–16:24 CST:
18/3/3/18/3/3/18/3/3/3/3/3 seconds, with 250 ms between completed captures. All had
decoded audio. Only one transfer-open request was sent; its header metadata was zero.
Every subsequent hold reused the verified transfer, including metadata-page-one lookup.
There were no audio recoveries or reconnects within the run. Late pre-hold frames were
discarded, and each hold's first accepted frame matched its current boundary.

A second installed-build run at 16:28 CST deliberately delayed the initial transfer
request by two seconds. Audio still began at sequence zero: 289 frames (5.78 seconds).
Two resumed holds delivered 287 and 289 frames, starting at boundaries 289 and 576.
Only one transfer-open request was sent across these three holds. No audio was saved
or sent to ASR by either diagnostic run. Normal launch was restored afterward.

The full suite passes: 388 tests, one existing skip, zero failures, including sixteen
Soundcore tests covering transfer lifetime and paged boundaries.
The strict-concurrency build succeeds; it reports an existing SwiftUI Binding callback
Sendable-conversion warning in SettingsPanes.swift, unrelated to Soundcore transport.
The exact spontaneous firmware stall trigger remains unconfirmed; the corrected
duplicate-transfer and inventory defects are established, with fifteen successful
post-fix hardware captures. Actual radio/power loss is not proven lossless by this run.

User acceptance after the transfer-lifetime fix: both separate Right Option sentences
appeared completely, including opening words. The user confirmed the original stall
occurred using Right Option alone, without the device button or case transition.
