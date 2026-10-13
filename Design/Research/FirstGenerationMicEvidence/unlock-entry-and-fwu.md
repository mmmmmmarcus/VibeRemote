# B439 v0118 / hw000A: unlock entry and firmware-update boundary

Date: 2026-10-13. Static analysis only. SHA-256 of the complete AFU: `9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc`; complete file offset zero maps to `0x08008000`. No device API calls, reset, pairing changes or writes in this phase.

## Correcting the earlier label

`08023160` is an internal unlock routine, not an established CLI command handler. A full aligned/unaligned little-endian pointer search found no `08023161` pointer in this image. Direct control-flow references in the disassembly were `08024504`, `0802450E` and `08024CF4`. This bounded search does not exclude all computed callers.

The routine places byte zero on the stack (`08023164..66`), prints `FW UNLOCKER` and the after-reset message, then obtains the shared global object (`08053E0C`), takes its `+2C` store, and calls `080461D8` with entry ID 0, one byte, and commit enabled (`08023192..A4`). It returns immediately after that call. The printed message precedes the write and cannot prove successful storage. It does not directly clear the runtime global `200027F0` here.

## Firmware updater caller

`08024468` is an updater finalize/commit action. Relevant checks before the internal unlock call:

1. Current update descriptor `updater+BC`, first word, equals `D0` (`080244A6..AE`).
2. The descriptor's bit index has its bit set in the accumulated update map (`080244B0..BE`).
3. Candidate version halfword `updater+36` matches the result of the current application version getter `08053E96(...,1)` (`080244C0..D2`). A mismatch logs `Unlocker doesn't match application version. Cannot unlock.` and skips the call.
4. Only a true result reaches `08023160` at `08024504` or `0802450E` (duplicate log-level paths).

The table at `08064A6C` routes `FWU_PAYLOAD --EVT_FWU_COMMIT--> FWU_SIGNATURE_CHECK`, `EVT_FWU_SIGN_GOOD --> FWU_UPDATE_READY`, and then `EVT_FWU_UBER_COMMIT --> FWU_FINALIZE`, with the last action pointer `08024469` at `08064D6C`. The failure transition for `EVT_FWU_SIGN_BAD` goes to `FWU_ERROR`. Extracted, hash-pinned transition records are in [unlock-fwu-transitions.json](unlock-fwu-transitions.json).

The signature-stage action `080241C8` checks download/CRC state and conditionally starts worker `0802361C`; that worker selects validation key material and performs the signature work. There are format-dependent branches, so merely citing the state name is not proof every possible input needs the same signature. This investigation has not produced an accepted unlocker image or demonstrated the full host update sequence. Do not treat this as a ready-to-send unlock command.

The already downloaded official OTA has eight `.afu` files (main, Bluetooth, touch, plus development variants/bootloader/BT diagnostics). There is no standalone unlocker file in that archive's AssetData directory. The development images have `hw000D` in their names, unlike the matched production `hw000A`; their presence is not evidence of a compatible restore image or permission to flash them.

## Internal notification caller

PMM `08024C98` validates the notification source against its registered `+88` source. Event 5 dispatches to `08023160` at `08024CF4`. It is an internal notification value, not HID report 5. Source provenance and transport limitations are described separately in [unlock-notification-entry.md](unlock-notification-entry.md).

## What this establishes

There is intentional unlock behavior in the matched production image; it is more than a leftover string. It writes persistent configuration and needs reset to update the boot-derived gate. It is not yet an established reversible operation available over this Mac's Bluetooth connection. Storage/relock findings are in [unlock-storage-risk.md](unlock-storage-risk.md). No actual unlock was attempted.
