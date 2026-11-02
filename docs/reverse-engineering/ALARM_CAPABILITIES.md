# WHOOP 5.0 haptics and alarms — investigation and capability matrix

Device: fw 50.43.1.0, hw WG50_r52. Labels as in [README.md](README.md).

## Evidence so far

| Source | Finding |
|---|---|
| Goose Swift client (`GooseBLEClient.swift`, `AlarmCommandKind`) | 5.0 alarm payloads: SET 66 `[4, id] + sec u32 LE + subsec u16 LE (1/32768) + pattern(12)`; GET 67 `[4, id]`; RUN 68 `[2, id]`; DISABLE-ALL 69 `[2, 0xFF]`. Default pattern `[47,152,0,0,0,0,0,0] + loopControl u16 0 + overallLoop 7 + duration 30 s`. Seq 64–255. Response status at body[1]: 0 UNKNOWN, 1 VALID_PATTERN, 2 INVALID_EFFECT, 3 INVALID_LOOPS, 4 INVALID_DURATION, 5 SUCCESSFUL_PLAY, 6 HAPTICS_FAILURE, 7 HAPTICS_TIMEOUT, 8 HAPTICS_BUSY, 9 HAPTICS_STOPPED, 10 INVALID_ALARM_TIME, 11 INVALID_ALARM_ID. Events 56 SET (rev, id, sec, subsec), 57 STRAP_DRIVEN_ALARM_EXECUTED, 58 APP_DRIVEN_ALARM_EXECUTED, 59 DISABLED, 60 HAPTICS_FIRED, 100 HAPTICS_TERMINATED (body[1]: 0 expired, 1 error, 2 user terminated). SUPPORTED. |
| Goose command table | 19 RUN_HAPTIC_PATTERN_MAVERICK, 79, 80, 122 STOP_HAPTICS exist as metadata only — **no payload anywhere in Goose**. |
| NOOP E02 (live) | 80 GET_ALL_HAPTICS_PATTERN → UNSUPPORTED. Says nothing about the motor itself. |
| **H01 (live, 2026-11-02, read-only)** | GET_ALARM_TIME 67 `[4, 0]` (`aa010c000001e74123c943040000000086be1237`) → **FAILURE**, 23-byte body `04 00 … 00`, 32 ms. Unsupported commands answer UNSUPPORTED with a 3-byte body, so 67 is **implemented** on this firmware. HYPOTHESIS: FAILURE = slot 0 holds no alarm. Capture: `captures/H01-get-alarm.jsonl`. |
| Saved console logs (9 kB) + stored events | No alarm or haptic lines; no events 56–60 / 100. Nothing passive to learn from. |
| NOOP's 4.0 alarm code (`armStrapAlarm`, `testAlarmBuzz`) | Uses 4.0 payloads (`[0x01]+epoch…`, cmd 79). Correctly blocked on 5.0 by the 5.0 allowlist. |

## H02–H06 results (approved, 2026-11-02 13:07–13:12)

| Test | Bytes sent | Response | Meaning |
|---|---|---|---|
| H02 SET slot 0, +120 s (strap time) | `aa011c000001e38123ca420400b4d1e86a00002f980000000000000000071e000e8b6f4e` | FAILURE, body `04 0b 00` → status 11 **INVALID_ALARM_ID**, 39 ms | The 5.0 alarm format is parsed; slot **0 is not a valid alarm id**. Nothing stored. |
| H03 GET slot 0 (before/after) | `…cb43 0400…` | FAILURE, 23-byte body `04 00…` | Consistent with "no alarm in slot 0". |
| H06 RUN slot 0 | `aa010c000001e74123cc44020000000039546ff7` | FAILURE, body `02 0b 00` → INVALID_ALARM_ID | No vibration expected. |
| H05 SET slot 0 then DISABLE-ALL | 69 `aa010c000001e74123cb4502ff000000e3bf9127` | **SUCCESS**, body `02 00 00` | Cancel-all CONFIRMED accepted on fw 50.43.1.0. |
| H04 (autonomous) | not run | — | Needs a successfully stored alarm first. |

Response body layout (CONFIRMED on these frames): `[revision][status][00]` for 66/68/69 (revision 4 for 66/67, 2 for 68/69,
matching the request's first byte); status values follow Goose's haptics/alarm enum.
Captures: `captures/H02-H03-H06-slot0.jsonl`, `captures/H05-disable.jsonl`.

## H07, H02b, H03b, H06b, H04 results (approved, 2026-11-02 13:14–13:27)

| Test | Result | Evidence |
|---|---|---|
| H07 haptic 19 one loop | **CONFIRMED (strap-reported)**: PENDING/VALID_PATTERN → SUCCESS/SUCCESSFUL_PLAY; event 60 HAPTICS_FIRED; event 100 reason 0 (expired). STOP 122 afterwards: PENDING → FAILURE (nothing to stop) | `captures/H07.jsonl` |
| H02b SET id 1 (+120 s) | **CONFIRMED**: SUCCESS, status VALID_PATTERN; event 56 echoes rev 3, id 1, time, pattern | `captures/H02b.jsonl` |
| H03b GET id 1 | **CONFIRMED read-back**: SUCCESS, body = stored time + pattern | same |
| H06b RUN id 1 | **CONFIRMED**: SUCCESS/SUCCESSFUL_PLAY; events 58 APP_DRIVEN_ALARM_EXECUTED + 60. Then event 14 DOUBLE_TAP and 100 reason 2 (user terminated) 16 s later. The run consumed the slot (later GET: time 0), so the +120 s alarm did not ring | same |
| **H04 autonomous** (+300 s, NOOP and probe quit) | **CONFIRMED (strap-reported)**: event 57 STRAP_DRIVEN_ALARM_EXECUTED + 60 at strap 1793643904 = the stored time exactly, between BLE_CONNECTION_DOWN 13:20:37 and UP 13:26:51; event 14 DOUBLE_TAP + 100 (user terminated) 6 s later | event table after reconnect |

Other findings: live events arrive in real time on **fd4b0004** (first traffic ever seen there); the same events are
replayed on fd4b0005 in the next history pull. The probe connected fresh, sent **no hello**, and every command worked
(E06: hello not required, at least for these). **Physical vibration CONFIRMED by the wearer** (2026-11-02): all three buzzes were felt — H07 (~13:15), H06b
(~13:17) and the autonomous H04 alarm (~13:25 Mac time) — matching the strap's HAPTICS_FIRED events.

## Proposed next (needs approval — different bytes from the approved set) — DONE above

| # | Command | Source | Exact frame |
|---|---|---|---|
| H02b | SET_ALARM_TIME **id 1**, now + 2 min, Goose default pattern | Goose UI defaults `alarmID: Int = 1` | `aa011c000001e38123 <seq> 42 04 01 <sec u32> 0000 2f98000000000000 0000 07 1e <crc32>` (example `aa011c000001e38123ce420401a0b0e96a00002f980000000000000000071e00c192415e`) |
| H03b / H06b | GET `[4,1]` / RUN `[2,1]` | Goose | `aa010c000001e74123cf430401000000d9ec7eec` / `aa010c000001e74123d0440201000000e6c5adef` |
| H04 | H02b at + 5 min with NOOP quit | — | — |
| H07 | RUN_HAPTIC_PATTERN_MAVERICK 19 `[01, 47, 152, 0,0,0,0,0,0, 0,0, 1, 0]` (one loop), then STOP_HAPTICS 122 `[01]` | Asherlc `WhoopBleConstants.maverickBuzzParameters` ("notify pattern used by the official app") | `aa0114000001e1e123ce13012f980000000000000000010082b26c6c`, then `aa0108000001e67123cf7a015bafe7ab` |

H07 is the shortest documented vibration (a single notify buzz) and needs no stored alarm: if it works, NOOP gets a
verified immediate vibration for host-driven alarms. Recovery for all: DISABLE-ALL (confirmed) / STOP_HAPTICS.

## Capability matrix

| Capability | Status | Basis |
|---|---|---|
| Immediate vibration (command from NOOP) | **CONFIRMED** (strap-reported and felt by the wearer): 19 notify buzz; or SET id 1 + RUN_ALARM 68 `[2,1]` (alarm pattern) | H07, H06b |
| Scheduled vibration (set a time) | **CONFIRMED**: id 1 accepted; id 0 → INVALID_ALARM_ID | H02, H02b |
| Persistent on-strap alarm firing with NOOP disconnected | **CONFIRMED** (strap-reported, on time to the second of strap clock, and felt by the wearer) | H04 |
| Recurring alarms | **UNSUPPORTED by protocol as far as known**: one absolute time per slot; NOOP must re-arm daily | Goose |
| Cancellation | **CONFIRMED** (accepted): DISABLE-ALL 69 `[2, 0xFF]` → SUCCESS | H05 |
| Status read-back | **CONFIRMED present** (67 answered with a structured body); content UNKNOWN | H01 |
| Dismissal by strap gesture (double tap) | **CONFIRMED** (strap-reported): event 14 then 100 reason 2, twice | H06b, H04 |
| Vibration patterns | **UNKNOWN** beyond Goose's single default; 80 unsupported → NOOP offers no pattern choice | E02 |
| Immediate haptic 19 + stop 122 | **SUPPORTED** (Asherlc payload, one loop); proposed H07 | — |

**Conclusion (after H04):** the strap stores one alarm (id 1) and rings it by itself, on its own clock, with nothing
connected; the wearer stops it with a double tap. NOOP stores the next deadline on the strap (converted to strap time)
and verifies it by read-back before showing "on strap". Smart-wake / sleep-goal early rings are host-driven
(RUN_ALARM needs NOOP connected); the strap's stored alarm remains the deadline. The Mac notification still sounds
as a backup. Recurrence is NOOP's job: the slot holds one time and is consumed when it rings.

## Proposed supervised experiments (need explicit approval)

All frames: type 35 command, header `aa01…0001`, CRC-16/CRC-32 as in PROTOCOL_SPEC.md, written to fd4b0002, seq 64+.
Alarm times are converted to **strap time** first (strap ≈ 17.8 s behind the Mac), otherwise the alarm is late.

| # | Command (bytes for an example time) | Expected | Side effects | Reversal | Timeout |
|---|---|---|---|---|---|
| H02 | SET_ALARM_TIME 66 slot 0, now + 2 min, Goose default pattern: `aa011c000001e3812340420400 <sec u32> 0000 2f98000000000000 0000 07 1e <crc32>` (example `aa011c000001e3812340420400a0b0e96a00002f980000000000000000071e00bbaac1dd`) | SUCCESS + body[1] VALID_PATTERN; event 56 with the time | Strap stores an alarm; up to 30 s of vibration (7 loops) at the time | DISABLE-ALL before it fires; else it ends after ≤ 30 s | 8 s |
| H03 | GET_ALARM_TIME 67 `[4,0]` `aa010c000001e7412341430400000000131aeb8c` | SUCCESS, body = the time set | none (read) | — | 8 s |
| H04 | H02 with now + 5 min, then quit NOOP so nothing is connected; you note whether/when it buzzes; reconnect and read events 57 / 60 / 100 | buzz at the time with the Mac disconnected → on-device alarm CONFIRMED | as H02 | — | — |
| H05 | H02 with now + 10 min, then DISABLE-ALL 69 `aa010c000001e74123434502ff000000761b689c` | SUCCESS; event 59; GET → FAILURE; no buzz | clears every alarm slot (none are in use) | — | 8 s |
| H06 | RUN_ALARM 68 `[2,0]` `aa010c000001e741234244020000000096c5462f` right after H02 | event 58; immediate buzz of slot 0's pattern | ≤ 30 s vibration | ends by itself | 8 s |

Recovery for any of them: DISABLE-ALL (69). Nothing here touches firmware, clock, calibration or stored history.
Not proposed: 19 / 79 / 122 (no documented payload), any other command number.

## Alarm state machine (implemented: `AlarmStateMachine`, AlarmEngine.swift)

`draft → pendingSync → confirmedOnDevice → active/triggered → dismissed`, with `failed`, `canceled`, `unknown`.
`confirmedOnDevice` is reachable only from `pendingSync` (a verified strap write and read-back); a host-driven alarm
goes `draft → active → triggered → active (next occurrence)`. Duplicate rings are blocked by a persisted
occurrence key (`alarmId@deadline`), so a restart inside the window can't ring twice.

## Safety and fallback

- The deadline always rings (exact, smart and sleep-goal modes). Early rings need 3 consecutive minutes judged
  awake/light (smart) or the sleep goal plus a lighter minute or 10 minutes' grace (sleep goal).
- Missing heart-rate data never causes an early ring; the deadline still holds.
- Warnings shown with an active alarm: strap vibration unverified (keep the Mac awake and a conventional alarm),
  strap battery < 20 %, strap disconnected.
- When an on-strap alarm is verified, it becomes the deadline; host-driven early waking stays an add-on and the strap
  alarm is never cancelled until a replacement is confirmed on the strap.
