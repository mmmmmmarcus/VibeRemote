# B439 v0118 / hw000A: read-only LOCK evidence

Firmware AFU SHA256: 9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc. Entire file mapped at 0x08008000, Thumbv7em.

## Direct Feature GET E1

- PMM report table at 0x08064F20, count 12. E1 entry at 0x08064F98 is bytes `03 E1 01 00 00000000 01000000`: Feature type 3, report E1, GET enabled, SET disabled, min 0, max 1.
- PMM initialization 0x08022FBC passes group 0 to constructor 0x0805D1C8 and stores table in PMM+0xD4. Table initialization is outside the preceding conditional LOCK gates on CLI command registration.
- PMM initialization 0x08022EF0 obtains shared DSM via 0x08033538; 0x08022EF6 stores DSM pointer in PMM+0x140.
- GET dispatcher 0x0802493C reads request+3 report ID; 0x08024992 compares E1, 0x08024994 branches to 0x08024B40.
- At 0x08024B40: r3=request+8 (output capacity), r2=request+0x10 (output buffer), r0=PMM+0x140 (DSM), r1=0 (entry ID), fifth arg=&request+0xC (actual output length). Calls DSM read 0x08033482. Nonzero return is an error; success sets request status 0 at 0x08024C00.
- DSM entry descriptor 0x0806927C: `00000000 01000000 6E2D0708 00000100`. Its ID is 0, max size 1; name pointer 0x08072D6E is NUL-terminated `LOCK`.
- DSM reader 0x08033482 looks up descriptor via 0x08033508, locates persistent record, copies at most caller capacity using memcpy 0x0800AA58, and returns actual size. It does not transform the byte or synthesize a status byte as data.
- Boot at 0x080502FA..0x08050306 reads same DSM ID 0, capacity 1, into global 0x200027F0. Read failure defaults global to 1 at 0x0805030C. Main command 0x31 rejects if this global is nonzero.

Interpretation rule: a successful HID Feature E1 response `E1 01` (two bytes, report ID followed by data) means persisted LOCK equals 1. Reading does not alter LOCK. Firmware boot copies this value to its runtime gate; barring separate post-boot modification (not observed), report 31 is blocked. This is not evidence of an immutable hardware fuse: the value is in DSM, but changing it is outside this read-only investigation.

## Bluetooth completion and status

BT handler radio event 0x72 receives internal characteristic handle index 1 or 2. At 0x0802CB2A group lookup table 0x080669C4 maps indexes to `{FF,00,01,FC,FF,FF,FF}`. PMM group 0 corresponds index 1. GET uses current selected report ID at BT object+0x246 (0x0802CB32); places ID at output byte 0, data starts byte 1; group, report ID, type 3 and direction 0 are sent to registry.

Completion at 0x0802A3F4 reads request+6 status, zeroes data length on error, maps internal group to radio handle index, and maps status via TBB at 0x0802A42E:

| internal status | radio status |
|---|---|
| 0 | 0x0000 |
| 1,10 | 0x0A35 |
| 2,4,9 | 0x0A06 |
| 3 | 0x0A11 |
| 5,6,7 | 0x0A0A |
| 8 | 0x0A0D |

GET at 0x0802A522..0x0802A54A sends radio command 0x52 with `{handleIndex:u16LE,status:u16LE,reportID:u8,data...}`, total data length includes report ID.
SET at 0x0802A562..0x0802A576 sends radio command 0x57 with `{handleIndex:u16LE,status:u16LE}` (4 bytes). Nearby literal strings identify these as character read/write response functions.

Important boundary: this is the main-MCU to radio protocol. Mapping 0x0A06 to an actual host ATT error needs capture/radio confirmation; do not equate successful macOS API queueing with a successful firmware command. An ATT write success vs error may expose report31 rejection, but no report31 is needed if E1 reads LOCK directly.

