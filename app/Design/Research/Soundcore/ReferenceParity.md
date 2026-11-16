# Soundcore reference parity

Reference checkout: tacshi/Soundcore, commit d296a1c5c0645797ff7cd3b55e93477a99820857.
Pinned source: https://github.com/tacshi/Soundcore/tree/d296a1c5c0645797ff7cd3b55e93477a99820857

| Reference | Native implementation |
| --- | --- |
| lib/ble/advertisement.dart | Name fallback, localized/truncated names, service UUID variants, 7-bit manufacturer marks and manufacturer service hints; discovery hints only, GATT and handshake still required |
| ble_service.dart startScan/_stopScanAndWait | Open 30-second scan, no early connectable filter, stop-scan/200 ms settle before GATT; aggregate scan diagnostics omit nearby identities |
| lib/protocol/frame.dart | SoundcoreProtocol.Parser and command framing; additive checksum, rejected payload FF |
| lib/crypto/device_crypto.dart | P-256 ECDH, HKDF salt/info 010203, 14-byte soundcored3200 magic, AES CTR with seq*10 |
| lib/ble/realtime_stream.dart header branch | Reject packet-level rejection; unwrap valid key; do not reject on trailing errorCode alone |
| realtime_stream.dart 1A06 | Retarget to newly announced current live ID |
| commands.dart startRecord/pauseRecord | 18/82 payload 01 to begin, 02 to pause |
| recorder_controller.dart _maybeStartAutoRealtime | Query current live ID after start confirmation |
| realtime_stream.dart finalize | No unsolicited 1A/11 transport-close commands |
| realtime_stream.dart active-stream guard | Preserve a verified device transfer across microphone pauses; do not reopen the same active transfer per hold |
| ble_file_pull.dart offset-zero request | Buffered transfer of the current hold only; pre-hold sequence boundary discards older speech; no historical-file fallback |
| recorder_controller.dart paged file list | Query subsequent metadata pages when the current recording is absent from a full ten-entry page |

Intentional voice-input scope differences: no file sink, offline browser, export,
delete, bind/unbind, OTA or vendor transcription. Per-hold audio is memory-only.
Do not fall back to the newest historical recording when current ID is absent.
Validate matching header ID and key magic; never fall back to raw ciphertext as
Opus when decryption fails. Existing-frame boundary prevents past speech replay.

Upstream trailing header metadata named errorCode is not interpreted as a fatal
error by its BLE realtime handler. The earlier Swift-only zero check incorrectly
rejected device headers with 4 before trying their wrapped key. Regression test
now checks valid-key metadata=4 acceptance and corrupted-key rejection separately.

The full Flutter application has not been run here (Flutter is not installed).
This is source parity plus native hardware validation, not an upstream app test.

## Discovery validation (2026-11-16)

The earlier native filter accepted only a narrower name/service/manufacturer set and
silently discarded non-connectable advertisements. It now follows the reference's
candidate matching, including empty local-name fallback and 7-bit manufacturer marks.
A discovery match is not a verified device: the D3200 service, characteristics,
device-info response and ECDH handshake still gate readiness.

The first installed diagnostic build found the physical device three seconds after
scan start. A 30-second scan received 1,586 advertisements, matched six advertisements
and produced one Soundcore candidate. GATT, device info (04.92, battery 100%) and the
secure handshake succeeded. None of those six matches was non-connectable. Because
older builds had no scan counters, this does not isolate which filter difference or
Bluetooth-session refresh resolved the earlier failed scans.

Connection now follows the reference's stop-scan wait plus 200 ms settle, with a
25-second connection timeout. Cancel/disconnect invalidates the pending connection
start so it cannot reconnect after the user cancels. Twelve Soundcore tests and the
strict-concurrency build pass. Scan diagnostics log aggregate counts and matched
signal strength/reason, without unrelated names, addresses or advertisement payloads.

The final signed build rediscovered the device ten seconds after scan start and
connected successfully after the stop-scan settle. Settings again showed Connected,
100% device/case batteries and firmware 04.92. The app was left connected.

## Stream lifetime correction (2026-11-16)

Microphone capture lifetime is not device-transfer lifetime. The previous native
code cleared its transfer ID/header readiness at every release even though firmware
left the transfer open. Each next hold sent another 1A/07 while that transfer was
active. The reference explicitly avoids duplicate active-stream requests; its file
sink lifetime is not suitable as the native per-dictation lifetime.

Controlled hardware observations:
- Delaying an initial offset-zero, buffered (flag 0) request by two seconds still
  delivered sequence 0 and continued delivering live microphone audio.
- A duplicate request at boundary 289 with offset 289*166 returned header metadata 4;
  the first accepted sequence was 385 (96 frames after the boundary).
- A duplicate at boundary 581 with offset 581*160 also returned metadata 4; first
  accepted sequence was 677 (again 96 frames later). The host had disabled audio
  acceptance pending that redundant header. This comparison does NOT establish
  which byte unit is correct for seeks: both requests ran against an active stream.
- A rapid-hold regression exposed an independent metadata-pagination bug once the
  device held more than ten recordings: the current ID was not on page zero.

The corrected native manager retains its verified transfer and key across microphone
pauses, prepares each hold's sequence boundary before resume, and requests a transfer
only for a new/current file or after actual transfer completion/disconnection. New
transfers use offset zero in buffered mode so startup audio is available, rather than
requesting a speculative nonzero seek into the active stream. It never falls back to
an older recording. The current pre-hold boundary is located across metadata pages.

The spontaneous original stall has not been reproduced deterministically; the host
lifetime/duplicate-request and page-zero-only defects are directly established by
source and controlled hardware observations. Post-fix stress results are recorded
in Microphone.md. Do not describe a complete sentence guarantee for power loss or
unrecoverable Bluetooth loss based on these tests.
