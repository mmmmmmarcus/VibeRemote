# B439 v0118 / hw000A static firmware findings

Artifact: B439-remote-v0118-hw000A-prod-signed.afu; SHA256 9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc.
AFU complete-file address base 0x08008000. All addresses below are runtime addresses. This is the phase-two offline snapshot; its statements about untested LOCK/GET apply to that stage. For subsequent read-only LOCK discovery see lock-read-and-ack.md; for the 2026-10-13 live read and fixed zero-duration request see ../FirstGenerationMicrophoneControl.md E13.

## Audio FSM
Table entry 20 bytes; state header type1; transition type2 `{2, destinationState<<16 | event, actionThumbPtr, eventStringPtr, stateStringPtr}`.

| State | Table header | Event | Destination | Action |
|---|---|---|---|---|
| CONNECTED=5 | 08063A8C | 0E | 6 | 08020889 AudioEnable |
| CONNECTED=5 | 08063A8C | 0F | absent | no listed transition |
| CONNECTED=5 | 08063A8C | 11 | 5 | none |
| CONNECTED=5 | 08063A8C | 12 | 5 | none |
| CONNECTED_WITH_AUDIO=6 | 08063BCC | 0F | 7 | 08020D99 AudioEnableStreaming |
| CONNECTED_WITH_AUDIO=6 | 08063BCC | 11 / 12 | 5 | 08020039 AudioDisableAndFlush |
| CONNECTED_WITH_AUDIO_STREAMING=7 | 08063CF8 | 0F | 7 | none |
| CONNECTED_WITH_AUDIO_STREAMING=7 | 08063CF8 | 11 | 5 | 080200AD AudioDisable |
| CONNECTED_WITH_AUDIO_STREAMING=7 | 08063CF8 | 12 | 8 | 08020E45 AudioButtonUp |
| CONNECTED_WITH_AUDIO_STREAMING_TIMEOUT=8 | 08063E24 | 0E | 7 | 08020C05 AudioDisableAnEnableAgain |
| CONNECTED_WITH_AUDIO_STREAMING_TIMEOUT=8 | 08063E24 | 0F | 7 | none |
| CONNECTED_WITH_AUDIO_STREAMING_TIMEOUT=8 | 08063E24 | 11 | 5 | 080200AD AudioDisable |

Host report 0x98 at 08021696: payload[0] nonzero emits event0F; zero emits event11. Thus it does not start audio in ordinary CONNECTED, because only event0E transitions to AudioEnable. Physical Siri handler08022962 emits0E on nonzero /12 on zero.

Release timer: AudioButtonUp08020E44 schedules at08020E74..94, 1000000 ticks (scheduler units inferred microseconds; same scheduler multiplied by1000 for CLI millisecond durations), timerID0x14, callback08021EF1. Callback08021EF0 signals mainObject+0x1E0 via0800D7AC. Main event processor0801C99E recognizes that signal;0801CA5E unconditionally posts0x11. Sending0F in timeoutstate8 transitions to7 with action0, therefore does not cancel timer; the later11 still closes audio. Explicit cancellation exists in08020C04 at08020C40 (cancel timer14) and08020C48 (clear+1E0 signal), action taken by0E from8. AudioDisable also cleans the timer. Do not equate receiving0x98 with indefinite hands-free audio.

## Button simulation, host report 0x31
CLI descriptor0806307C..88: command `button`, handler0801D889, description `Button press simulation`. CLI and host use common0803105C. Host dispatcher08021556 checks global byte200027F0==0; nonzero refuses. Requires exactly5 payload bytes, mask=payload0; initial delay_ms=BE16(payload1..2); duration_ms=BE16(payload3..4). No on/off-toggle semantics or infinite-duration semantics established; zero duration is rejected downstream. Max16-bit duration is65535ms.

Leaf0803105C remaps touch bit0x80 to0x40 but retains0x10 (Siri), posts internal ButtonProcessor event0D. Handler08030752 requires nonzero mask,duration, cancels prior timer17, clears object+2E8, stores mask+2E4 and duration+2EC, schedules callback080301D1 after delay_ms*1000. Callback signals object+14C. Event0802F128 schedules duration timer, moves mask+2E4 to simulated mask+2E8 and invokes GPIO callback from table08066BB4 per setbit.08030310 checks simulated mask+2E8: if bitset it ORs the button state+2F0 and bypasses physical GPIO read. That normal state path calls0802FA10. At0802FB86, change in bit0x10 emits notification4 with payload0x10/0 via08059B88. This is same emission path as physical Siri. At duration expiry0802F838, callbacks invoked and simulated mask+2E8 is cleared. This route can also emit normal host HID reports, so it is not isolated audio-only control; preservation of app mappings needs separate future experiment design.

## Device lock gate, not assumed hardware fuse
Global byte200027F0 is read from DSM persistent entry0 in boot init080502F4..030C using08033482. Read failure sets1. Missing entry initializes0 at08050330..0344. Entry descriptor0806927C `{id=0,maxlen=1,nameptr=08072D6E('LOCK'),flags=...}`. CLI and report0x31 both refuse when nonzero. Current device's LOCK value is NOT captured by this offline image. Production filename alone does not establish value.

Internal unlock routine08023160 exists (the earlier CLI-handler label was incorrect); writes DSM record0=0 and prints `The device will be unlocked after the reset`. Its availability/authorization/remote reachability is not established. Nothing was written and no attempt was made to unlock. Treat LOCK as a bounded gap before contemplating any report0x31 hardware experiment.

## Stop and inspection bounds
`mask=0` returns -1 in08031076..10A8 before enqueuing, so it is not a release command. `duration=0` is discarded by0803075A..60. End-of-duration callback triggers signals and clears simulated mask+2E8/+2EC at0802F838..870; the per-button callback only signals a queue, so the later consumer re-reads the now-cleared mask and actual GPIO. A separate immediate safe cancel command was not established.

Main CmdProcessorReportGet08021A28..1D80 has no direct LOCK read in its inspected branches. Report84/85 read DSM IDs11/14, not0; others read peripheral state. This is not proof all firmware debug transports lack a read-lock operation. No host GET was executed.
