# B439 v0118 LOCK: storage, relock candidate and recovery limits

Scope: offline static analysis only. No device access, unlock, persistent write,
nonzero-duration button simulation or mapping changes were performed for this analysis.
The exact reference AFU is `B439-remote-v0118-hw000A-prod-signed.afu`, SHA256
`9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc`.
Addresses below map the complete AFU at `0x08008000`, Thumbv7em.

## Findings supported directly by disassembly

### Unlock changes persistent data; it is not a transient microphone setting

`0x08023160` places a zero byte on its stack. At `0x08023192..0x080231A4`
it obtains the global factory-store object at global+0x2C and calls
`0x080461D8(store, entryID=0, buffer=&zero, length=1, commit=1)`.
That function is the raw store writer; it is not the guarded generic DSM setter.
The callback returns immediately after the raw writer call (`0x080231A8`) without
checking the returned status or performing read-back; successful unlock must not be
inferred merely from reaching this callback. It does not assign runtime LOCK at
`0x200027F0`. Its callers/transport are analyzed separately: this function has not
been established as a directly registered CLI `unlock` command.
Boot `0x080502FA..0x08050306` reads persistent entry 0 into that runtime byte.
Thus persisted and currently enforced values can differ until the reboot/reload path.

### A static path exists to put LOCK back to 1

The CLI descriptor at `0x08064FB4` names the `ds` command group. Its `set`
subcommand descriptor at `0x08064FC8` points to `0x08024D6D`, with help text
`Set persistent memory entry`. The handler:

1. Resolves an entry by name (`0x08024D80..0x08024D88`, DSM lookup
   `0x08033580`) or by parsed numeric ID (`0x08024D8E..0x08024D98`).
2. Gets entry data format/maximum length. LOCK's descriptor at `0x0806927C`
   is ID 0, length 1, numeric format 0, factory category 0.
3. Parses a numeric argument and copies its low byte to the local payload
   (`0x08024DD4..0x08024DF4`). Therefore value 1 is representable exactly.
4. Determines factory/user category via `0x080336C6` at `0x08024E60`.
   Factory entries take `0x08024E82`, which rejects if runtime LOCK is nonzero;
   the literal message is `Device locked, factory entries cannot be modified`.
5. When runtime LOCK is zero, `0x08024EE6..0x08024EEC` loads global+0x2C,
   then `0x08024E72..0x08024E7C` calls raw store write with the selected
   entry ID, parsed payload and `commit=1`.

Consequently the function-level relock candidate is the CLI persistent-data setter
selecting LOCK/entry 0 and numeric value 1, **after runtime unlock is active**.
This is static command-handler semantics, not a tested recovery procedure or proof
that the CLI is reachable over the user's Mac transport. No command was executed.
There is no evidence here that relocking updates the runtime byte immediately;
boot-time enforcement is the established path.

The normal API `DSM.set` at `0x080335C0` explicitly requires descriptor category 1
(`0x080335D6..0x080335DA`). It cannot be assumed to relock category-0 LOCK.
Feature E1 is GET-only and cannot be used as the inverse write operation.

### Writer checks and scope

`0x080461D8` serializes access using a lock and invokes `0x080460FE`.
The latter locates an existing record, checks record restrictions and capacity,
compares current data/length and checksum, copies changed bytes into the RAM bank,
updates the entry checksum through `0x08046038`, marks the bank dirty, and with
commit=1 calls `0x08045C9C`.

Although the logical operation changes only one byte of one entry, its physical
commit operates on the **whole store bank**, not only that byte.

### Two bank copies and checksums

`BankWrite` at `0x08045C9C`:

- increments the bank generation counter at RAM header+0x10;
- recalculates the 0x1C-byte header checksum into header+0x1C;
- chooses the alternate bank address from store+8/+0xC using current index+0x18;
- calls backend vtable+0x20 and then +0x14 for the bank's full configured size
  (`0x08045D28..0x08045D42`; these are consistent with prepare/erase then write);
- only after successful backend returns clears dirty and toggles current index
  (`0x08045D5E..0x08045D6C`). Backend failure reaches the assertion handler
  `0x08028E7C`, rather than a caller-visible rollback result.

Constructor `0x08046A1C` reads both bank headers, validates them, compares generation
counters including wraparound cases (`0x08046B16..0x08046B7A`), and tries the preferred
copy using `0x08045F34`. On validation failure it tries the other copy
(`0x08046B8A..0x08046B98`). The loader checks the header, each entry descriptor's
checksum, and each entry payload's checksum (`0x08045F7E..0x08045FE0`).
If neither copy validates, `0x08046BB6..0x08046C2A` constructs and commits a blank
store header. This is recovery to a valid empty store, not restoration of lost data.

This establishes a redundancy/checksum design. It does **not** establish reliable
power-loss atomicity on the actual hardware: backend erase geometry, brownout behavior,
physical bank independence, flash health and tested recovery access remain unknown.
The inspected high-level commit path does not itself read back the just-written bank.

### Factory versus pairing data

DSM descriptors use category 0 for factory data and category 1 for user/runtime data.
Initialization at `0x080501BE..0x08050214` installs distinct factory/user store pointers
into DSM+0x24/+0x2C and DSM+0x28/+0x30 respectively. DSM reader `0x08033482` selects
its store by the descriptor category. Examples:

| Entry | ID | Category | Implication |
|---|---:|---:|---|
| LOCK | 0 | 0 | Factory-store bank is rewritten on change. |
| SERIAL_FG / SERIAL_MS | 1 / 2 | 0 | Same logical store as LOCK. |
| BT_BD_ADDRESS | 17 | 0 | Same logical store as LOCK. |
| AUDIO_MIC_CAL | 26 | 0 | Same logical store as LOCK. |
| BT_XTAL_TRIM / BT_RSSI_CAL | 13 / 14 | 0 | Same logical store as LOCK. |
| BT_PAIRED_HOST | 20 | 1 | Separate logical user store. |
| BT_DIVERSIFIER | 19 | 1 | Separate logical user store. |
| BT_GATT_UPDATE | 18 | 1 | Separate logical user store. |

A successful entry-0 write preserves other entries in its RAM bank and contains no
explicit paired-host deletion. Therefore clearing pairing is **not an observed intended
side effect** of this specific setter. However LOCK shares the committed factory bank
with identity and calibration data. The high-level store separation does not prove
independent physical failure domains, nor does it cover the radio's complete bonding
state. No claim is made that pairing or calibration survives every failed/interrupted
write, reboot or subsequent diagnostic operation.

### Ordinary restart and FactoryReset are not relock operations

Ordinary boot reads the existing LOCK value; its missing-entry branch initializes
zero (`0x08050330..0x08050344`). Neither branch provides a normal automatic return
to LOCK=1. A read failure's runtime default of 1 is an error fallback, not persistent
relocking or restoration of data.

The function explicitly named `FactoryReset` by its diagnostic literal is
`0x0802341C`. It loads **DSM+0x30 (user store)** at `0x0802343A..0x08023440`.
It loops over nonempty records, skips records whose flag byte+1 has bit 0 set,
and clears the other records by raw write with length 0 and deferred commit
(`0x0802345E..0x0802349E`). It commits once, then signals the reset path
(`0x080234A0..0x080234BC`). It does not visit the factory store containing LOCK.

The initialization path maps descriptor+0xE to this record flag: when it is nonzero,
`0x08050284..0x0805028E` calls constructor `0x08046CCC`, which passes flag 1 to
`0x08046424`; that flag is stored at record+1 by `0x08046550`. Thus BT_PAIRED_HOST,
BT_DIVERSIFIER and BT_GATT_UPDATE (all descriptor+0xE=1) are protected from this
particular FactoryReset clearing loop. User entries with flag 0, such as DEVNAME,
CONSOLE_SETTINGS, POWER_SETTINGS, button debounce values and IR_ENTRY_DB, are
eligible for clearing. This is the function's static scope, not verification that
all user-visible factory-reset gestures or the radio's independent bond state use
only this function.

## Inferences and remaining gaps

- The byte is mutable persistent configuration, not shown to be a one-time fuse.
  The setter above provides a plausible reverse transition 0 -> 1.
- This makes relocking *possible in code*, not *reliably recoverable in practice*.
  The host-accessible CLI transport, post-unlock ability to reconnect, successful
  persistence/reboot, read-back E1=1 and normal microphone/button operation have not
  been tested.
- A byte-level backup of LOCK is insufficient to recover factory data if the full
  store becomes unusable. No verified complete backup/restore channel was established.
- Dual-bank selection reduces some partial-write risks by design; no quantitative
  failure probability or guarantee follows from this static analysis.
- Restoring LOCK would only restore this gate. It would not undo unrelated settings
  changed by diagnostic commands while unlocked. The analysis does not recommend
  invoking those commands or changing the mapping.

Conclusion: there is a concrete static relock candidate and nontrivial storage
redundancy, but no demonstrated safe unlock-and-restore workflow on this remote.
