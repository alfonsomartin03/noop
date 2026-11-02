# Packet types and decoded structures (WHOOP 5.0)

Offsets are **payload** offsets (payload = frame[8 ..< len-4], payload[0] = packet type). Frame offset =
payload offset + 8. Names for type numbers come from NOOP's `whoop_protocol.json` / Goose.

## Type inventory on this strap

| Type | Name | Seen? | Characteristic | Lengths (frame bytes) | Label |
|---:|---|---|---|---|---|
| 35 | COMMAND | sent by app | fd4b0002 | 16+ | CONFIRMED |
| 36 | COMMAND_RESPONSE | yes | fd4b0003 | 20, 24, 28, 32, 48, 84, 124 | CONFIRMED |
| 38 | PUFFIN_COMMAND_RESPONSE | never | — | — | UNKNOWN on this unit |
| 40 | REALTIME_DATA | yes (42, E04), only while cmd 3 is on | fd4b0005 | 32 | CONFIRMED |
| 43 | REALTIME_RAW_DATA | not captured | — | — | UNKNOWN on 5.0 |
| 47 | HISTORICAL_DATA | yes (634 records) | fd4b0005 | 124 | CONFIRMED |
| 48 | EVENT | yes (26) | fd4b0005 | 24, 32, 36, 44, 56 | CONFIRMED |
| 49 | METADATA | yes (51) | fd4b0005 | 36 (END), 52 (START), COMPLETE | CONFIRMED |
| 50 | CONSOLE_LOGS | yes (180) | fd4b0005 | 76 | CONFIRMED |
| 52, 53, 54, 55, 56 | puffin / IMU variants | never | — | — | UNKNOWN on this unit |

All captured history traffic (types 47–50) arrives on fd4b0005, including events: the "events"
characteristic fd4b0004 was silent.

## 36 COMMAND_RESPONSE

`[36][strap seq][cmd][app seq][result][body…]`. Result 0 FAILURE, 1 SUCCESS, 2 PENDING, 3 UNSUPPORTED.
An UNSUPPORTED or PENDING response has a 3-byte zero body (20-byte frame). CONFIRMED (E02).

| Cmd | Body layout | Label |
|---|---|---|
| 1 LINK_VALID | ASCII `There it is.` then zeros | CONFIRMED |
| 11 GET_CLOCK | `[unix sec u32][subsec u32][00 00 00]`; subsec unit 1/32768 s is from Goose | CONFIRMED (sec), SUPPORTED (subsec unit) |
| 26 GET_BATTERY_LEVEL | `[pct u8][00 ×6]`; matched 2A19 = 20 | CONFIRMED (one sample; width u8 vs u16 UNKNOWN) |
| 34 GET_DATA_RANGE | see below | partly CONFIRMED |
| 84, 151 | result 0 with body starting `01` | CONFIRMED (failure), meaning UNKNOWN |
| 145 GET_HELLO | 124-byte body, identity data | redacted, not analysed |

### GET_DATA_RANGE (34) body, 67 bytes

E02 sample (wall 11:15 EST), annotated:

```
+0   01                 revision/status (Goose)                                       SUPPORTED
+1   c0960100  104128   page counter (highest; Goose: words[0])                       HYPOTHESIS: write page
+5   66960100  104038   = last acked trim page                                        CONFIRMED (E02)
+9   af960100  104111   Goose: "page_current"                                         UNKNOWN meaning
+13  66960100  104038   = last acked trim page (Goose: "page_oldest")                 CONFIRMED (E02)
+17  0f000000  15       = second word of every ack's end_data                         CONFIRMED
+21  00000200  131072   Goose: "page_end" (ring size?)                                HYPOTHESIS
+25  1f040000 b9fb1d00  unknown                                                       UNKNOWN
+33  unix u32 + u32     oldest record time (2026-10-11 16:12)                         SUPPORTED
+41  unix u32 + u32     2026-11-02 10:57:11 = time of the last acked chunk            CONFIRMED (E02, also 2026-11-01 log)
+49  unix u32 + u32     same as +41 in E02                                            UNKNOWN
+57  unix u32 + u32     2026-11-02 11:14:45 = newest record (≈ strap clock now)       CONFIRMED (E02)
+65  00 00
```

The trim pointer in the range response is the last ack NOOP sent at 10:57:40 (`[01] 66960100 0f000000`).
**Bug in NOOP:** `BLEManager.logWhoop5DataRange` treats +41 as "newest stored". It is the last-synced time;
the newest record is at +57.

Second sample (E04, 11:29): trim page 104162 / block 15, +41 = +49 = 11:26:39 (last record of the 11:27
pull), +57 = 11:28:38 (≈ strap clock), oldest advanced from 10-11 16:12:39 to 10-11 16:27:45 in 15 min:
the oldest record moves with a rolling ~3-week buffer, independently of acks. CONFIRMED on two samples.

## 47 HISTORICAL_DATA, version 0x1a (payload 80 bytes, frame 88) — E08

Seen live 2026-11-02 (80 records). Strap unix u32 at payload 7 (80/80 plausible), consecutive 1-s records in runs
about 20 minutes apart. Nothing else is decoded. NOOP archives these frames verbatim before acking their chunk.

## 40 REALTIME_DATA (payload 20 bytes) — E04

Enabled by `TOGGLE_REALTIME_HR` (3) `[1]`, stopped by `[0]`; 1 frame per second on fd4b0005.

| Off | Field | Label |
|---:|---|---|
| 0 | type 40 | CONFIRMED |
| 1 | constant `0x02` (not a sequence; Goose's "K"/kind for compact live records) | CONFIRMED value, meaning SUPPORTED |
| 2 | strap unix seconds u32, +1 every frame (42/42) | CONFIRMED |
| 6 | subseconds u16, constant within the session | CONFIRMED value |
| 8 | heart rate u8 bpm (69 → 59 over 42 s, resting) | CONFIRMED (NOOP decoded the same values; history cross-check below) |
| 9 | R-R count u8 (0 in all 42 frames) | HYPOTHESIS: count; Asherlc calls it a "valid flag" |
| 10–17 | zeros (R-R slots?) | UNKNOWN: never non-zero |
| 18 | `0x01` constant | UNKNOWN |
| 19 | `0x00` | UNKNOWN |

NOOP's `decodeWhoop5Realtime` (frame offsets 10/14/16/17/18) matches for timestamp, subseconds and HR.
No R-R ever arrived on this stream; use 2A37 or type-47 for R-R.

## 47 HISTORICAL_DATA, version 0x12 (payload 112 bytes)

| Off | Field | Label |
|---:|---|---|
| 0 | type 47 | CONFIRMED |
| 1 | record version 0x12 (all 634 captured records) | CONFIRMED |
| 3 | counter u32 | SUPPORTED (existing decoder) |
| 7 | unix seconds u32: consecutive records step exactly 1 s (628/628) | CONFIRMED |
| 14 | heart rate u8 bpm; median \|HR − 60000/mean R-R\| = 3.5 bpm over 425 records | CONFIRMED |
| 15 | R-R count u8 (≤ 4 seen) | CONFIRMED |
| 16 | R-R u16 ms × count | CONFIRMED |
| 37, 41, 45 | gravity x, y, z float32 (g); \|g\| within 0.9–1.1 for 634/634 | CONFIRMED |
| others | optical, temperature, SpO2 candidates | UNKNOWN (not decoded; do not guess) |

## 48 EVENT

`[48][seq][event u16][unix u32][subsec u16][body_len u16][body…]`. body_len matches the remaining bytes in
all 26 captured events. CONFIRMED (matches ryanbr/noop's "length at frame[18]").

| Event | Name (4.0 enum) | Body bytes seen | Label |
|---:|---|---|---|
| 3 | BATTERY_LEVEL | 20 | soc u16/10 @1 and mV u16 @5 CONFIRMED (20.0 %, 3706 mV = 0x2A19); charging @10 unproven |
| 33 / 34 | BLE_REALTIME_HR_ON / OFF | 0 | CONFIRMED (E04, E08) |
| 63 | EXTENDED_BATTERY_INFORMATION | — | name SUPPORTED; same second as event 3 |
| 11 / 12 | BLE_CONNECTION_UP / DOWN | 0 | CONFIRMED (appear around connects) |
| 25 | BLE_HR_PROFILE_DISABLED | — | CONFIRMED (2026-10-31, after cmd 14 [0]) |
| 29 | STRAP_CONDITION_REPORT | 12 | name SUPPORTED, body UNKNOWN |
| 110 | — | 8, constant `0101000000000000` | UNKNOWN; every 10 min |
| 120 | — | 32 | UNKNOWN |
| 123 | — | 8; byte 4 = 01 at disconnect, 02 at reconnect | HYPOTHESIS: connection state |

The NOOP app logs 5.0 events as "undecoded" and never routes them, because `parseFrame` reads 4.0
offsets. Wrist on/off and double-tap event numbers have not been observed on 5.0.

## 49 METADATA

`[49][seq][kind u8][unix u32 @3]…`; kind 1 HISTORY_START, 2 HISTORY_END, 3 HISTORY_COMPLETE. CONFIRMED.

- START (52-byte frame): `[49][seq][01][unix u32 @3][…]`, rest constant within a session
  except a byte that changed between firmware sessions (`0x2b` → `0x2a`). Meaning UNKNOWN.
- END (36-byte frame): `[49][seq][02][unix u32 @3][u32 @7][00 00][trim_page u32 @13][trim_block u32 @17][00 ×4]`.
  `end_data` = payload[13..21] is echoed in the ack. CONFIRMED.

## 50 CONSOLE_LOGS

`[50][seq u16][unix u32][4 bytes][ASCII text…]`; text is a continuous stream split across frames
(lines look like `28, 105029239: BLE: History burst success. Trim: 0x0000000f:00009a6d (15:39533)`).
CONFIRMED. The text includes Bluetooth addresses, so it must be redacted before sharing. Useful lines seen:
`History burst success. Trim`, `Historical Dump Complete`, `PullStats`, `BLE_CMD: HELLO`,
`SIGPROC-WEAR-DETECT V5` (with `skin_temp`, `hrc`), `BLE Bond failure`, `mtu = 247`.
