# B439 v0118 unlock notification entry (static evidence, 2026-10-13)

Scope: only local firmware bytes/disassembly were read. No HID/Bluetooth device was
opened, no command was sent, and no unlock, reset, pairing or mapping change was made.
Addresses refer to the hash-pinned production AFU mapped at `0x08008000` used by the
parent investigation. This is local static evidence, not an REA-engine trace or a
hardware result.

## Confirmed internal notification chain

1. `PMM::NotificationProcess` at `0x08024C98` compares its argument `r1` with
   `*(this + 0x88)` at `0x08024CA0–0x08024CA8`.
2. The generic filter constructor `0x08059628` initializes `this + 0x88` to `this`
   at `0x080596D4`. It is a notification subscription identifier, not a physical
   GPIO/UART device pointer. The notification sender copies a subscriber's stored
   identifier into the notification record at `0x08059BC6–0x08059BD6`.
3. System construction builds a `REMOTE` filter (`0x08050900`, name pointer
   `0x08050C54 -> 0x0807302D`) and a `PMM` filter (`0x08050A6A`, name pointer
   `0x08050DEC -> 0x08073034`). At `0x08050BDA–0x08050C06` they register and enable
   bidirectional notifications using each subscriber's `+0x88` identifier.
4. In the PMM processor, event IDs 5–10 use a byte jump table at `0x08024CEA`.
   Entry 5 is `0x03`, targeting `0x08024CF0`; that path branches directly to
   `0x08023160` at `0x08024CF4`. This is the already-identified persistent LOCK=0
   function, whose text says it takes effect after reset.
5. The REMOTE notification processor `0x0802228C` recognizes source `0xC80F`
   at `0x080222E0–0x080222E6`; the diagnostic string is explicitly
   `Notif from BIR: id = 0x%08x` (`0x080225F8 -> 0x0806C0C4`). Its event-1 table
   entry at `0x08022462` is `0x0120`, targeting `0x080226A0` from table base
   `0x08022460`.
6. `0x080226A0–0x080226A8` emits generic notification event 5 with no payload.
   Its diagnostic string is explicitly `Unlock` (`0x080229F8 -> 0x0806C0ED`).
   Combined with the subscriptions above, this provides a static BIR-event-1 →
   REMOTE-event-5 → PMM → unlock chain.

## Unresolved origin: do not claim a physical unlock gesture

The upstream generator of **BIR event 1** has not been established. The bounded
scan of direct calls to generic notification emission in the BIR button-processing
region found event 0 and event 3 (`0x0802F492–0x0802F4B4`), event 2
(`0x0802FB16–0x0802FB28`), and Siri event 4
(`0x0802FB8C–0x0802FB9C`). No corresponding direct event-1 producer was found in
that scan. Indirect dispatch, another variant, or a disabled production path remain
possible. This is not proof of absence and is not a usable sequence of buttons.

A handler retained in production firmware does not prove a supported live trigger.
No button combination should be tried as an unlock test from this evidence.

## CLI transport observations and remaining gap

The firmware contains `src/app/cli/AppCli_main.cpp` and
`src/app/cli/hid_cli.cpp` strings. `0x08026A8A–0x08026A8E` registers the command
table at `0x0806548C`; that table's command name is `hid`, followed by options
including `type`, `feature`, and `size`. Therefore the filename `hid_cli.cpp`
alone does **not** establish that a host can send CLI text over the exposed HID
Feature interface: it can also represent a CLI command that operates on HID.

The CLI input path at `0x08026B6A–0x08026BC8` reads bytes through an abstract I/O
object at `0x20000898` (virtual operation 1), then enqueues them into its character
buffer using `0x0802730C`. Its physical transport and accessibility over the
currently exposed BLE/Lightning interface have not been resolved. There is no
confirmed host-accessible transport for the proposed `ds set` relock command.

## Risk / reversibility implication

This chain strengthens the evidence that unlock logic is deliberately present in
the firmware. It does not demonstrate a remotely reachable unlock interface, a safe
physical trigger, or a reliable recovery path. Persistent LOCK writes plus a later
reset remain state-changing operations; a static relock CLI implementation is not
an end-to-end recovery guarantee until its actual transport and successful write/
readback/reboot behavior have been verified independently.
