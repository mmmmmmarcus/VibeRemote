# B439 v0118 CLI transport follow-up — 2026-10-13

## Scope and result

Offline static analysis only, on the exact B439 v0118 hw000A production AFU
SHA-256 `9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc`.
The official archive was downloaded again and the repository's hash-pinned
`inspect_b439_firmware.py` accepted it. No device API, application lifecycle,
configuration, button mapping, pairing, reset or firmware operation was performed.
This is not evidence about the currently connected 0314/hw0021 device.

**The CLI input object is now resolved to a UART backend, port selector 1,
initialized at 115200 baud. It is not merely an unresolved virtual I/O object.**
This advances the previous transport gap, but does not establish an accessible
Mac/BLE/Lightning channel. Physical routing, connector/pad availability and any
external bridge remain unverified. A UART implementation does not prove that its
pins are exposed or that standard Lightning USB enumerations carry this stream.

## Reproducible static chain

1. Reset calls startup `08028ACC`. At `08028AF8..08028B02`, a copy table drives
   source/destination/length copies. The table is `0805D390`, count 5 at `+80`;
   its first record is source `08074E80`, destination `20000800`, length `248`.
   Thus RAM object `20000898` has its initializer at flash `08074F18`.
2. That initializer's first word is `08074E68`; its `+18` word is 1 and its
   `+1C` word is `0001C200` (115200). Vtable words at `08074E68` and `08074E6C`
   are Thumb pointers `0804DC99` and `0804DD09` respectively. This resolves the
   indirection without guessing the object's type from a filename.
3. CLI byte collection `08026B7C..08026B8C` calls vtable slot `+4` with operation
   1, buffer and length pointer. At `0804DD08`, op bit 1 selects
   `0804DBB8`, passing the object's `+18` port selector. Operation 2 instead
   selects `0804DA1C` for output. These are the concrete implementation addresses.
4. Reader `0804DBB8` selects per-port state (`200020E4`, stride `6C`), uses the
   hardware descriptor table `08069130` (stride `18`) and obtains data from a
   receive ring. Port selector 1 maps to index 0. Descriptor 0 starts with the
   MMIO base `40011000`; descriptor 1 starts with `40004400`.
5. Writer `0804DA1C` maps the same port and writes a character to the peripheral
   data register at base `+4` (`0804DAC4..0804DACA`). This is a peripheral serial
   backend, not a call to the HID report or BLE notification dispatcher.
6. Initialization slot `0804DC98` takes port `+18` and baud `+1C`, then calls
   `0804D704` at `0804DCF6`. System construction also invokes that initializer
   on `20000898` at `0804F6F8..0804F700`. Separately, `0804F6CA..0804F6D6`
   configures selector 1 with baud 115200 before enabling GPIO mux configuration
   through `08028D1C(1)`.
7. GPIO setup `08028D1C` passes `(0,10,...,8)` and `(0,9,...,8)` to the
   pin configuration helper. These are firmware port/pin/mux numbers, **not a
   verified board pinout**. Do not derive cable wiring from them.
8. The CLI baud adjustment at `08025C4E..08025C6E` writes the same object's
   `+1C` field and invokes its initialization operation. The associated command
   text is `UART baudrate` at `0806CAB7`. Together with the peripheral code,
   this supports calling the backend UART without relying on inferred class names.

Data words, mapping and excerpt checksum are in
[cli-transport-followup.json](cli-transport-followup.json). Small disassembly
excerpts are in [b439-cli-uart-followup.txt](disassembly/b439-cli-uart-followup.txt).
Literal-pool lines shown as instructions by objdump must be read as data.
These are local static evidence, not REA engine trace IDs or hardware results.

## Implications for `ds set` relocking

The earlier `ds set` handler and factory-store LOCK-write branch remain valid
static evidence. This follow-up identifies the primary CLI byte source as UART;
it does not turn the handler into a host-accessible BLE Feature command.

The safe conclusion is therefore **a static relock implementation exists behind
an identified UART CLI, but no usable, verified host relock transport has been
established**. The analysis follows the object's shipped initialization and direct
virtual calls; it does not prove the absence of every possible alternate injector,
service/debug bridge or later object mutation.

Before an unlock experiment could be considered recoverable, missing evidence
still includes: actual transport availability and electrical/bridge routing;
command parser access in the relevant locked/unlocked lifecycle; verified write
completion rather than a success-intent log; readback before and after reboot;
and an independent recovery method for damaged factory storage. The CLI path does
not supply a demonstrated factory-bank backup/restore facility by itself.

No relock command was executed. Nothing here authorizes opening the remote,
probing pins, sending CLI text, or modifying persistent data.
