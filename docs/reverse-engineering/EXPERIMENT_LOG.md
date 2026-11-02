# Experiment log

Chronological. All times America/New_York. Captures under `captures/` are redacted (see README).

## P0 — Existing evidence (passive, 2026-10-13 → 2026-11-02)

- **Source:** NOOP's manual-pull capture files (`~/Library/Containers/com.noopapp.noop/Data/Documents/whoop5-history-*.jsonl`,
  6 files, 890 frames) and NOOP's unified log (`log show --predicate 'subsystem == "com.noopapp.noop"'`, 3 days).
- **Sent by tooling:** nothing (read-only analysis).
- **Results:** 0 CRC failures. Types seen: 47 (634), 50 (180), 49 (51), 48 (26), all on fd4b0005.
  Firmware console text decodes as ASCII and records `History burst success. Trim: <block>:<page>` after
  every ack, `Historical Dump Complete`, and `PullStats: Data: 2553, Events: 320, Bytes: 342276, Seconds: 55.04`.
  Event frame layout (`body_len` at payload[10]) checked on all 26 events. Type-47 v0x12 layout checked:
  1-s steps 628/628, unit gravity 634/634, HR vs R-R median diff 3.5 bpm.
  NOOP logs show REPORT_VERSION_INFO → result 3 on every connect, hello → 145 PENDING then SUCCESS,
  fd4b0007 traffic before the hello.

## E01 — Passive GATT enumeration (2026-11-02 11:13)

- **Pre-state:** strap connected to NOOP, idle (no pull for 10 min), battery 20 %.
- **Sent:** no commands. Descriptor reads, reads of 180A and 180F, CCCD subscriptions on fd4b0003–0007.
- **Results:** DIS: `WHOOP Inc.`, model `5.0`, fw `50.43.1.0`, hw `WG50_r52`, serial (redacted).
  Battery 20 %. GATT map in GATT_MAP.md. No vendor frames in 20 s.
- **Independent check:** battery 20 % from 2A19. Firmware string matches the WHOOP 5.0 `50.x` family.
- **Blocker hit and fixed:** a bare CLI is attributed to Claude Code by TCC and killed for missing
  `NSBluetoothAlwaysUsageDescription`; wrapped the probe in an `.app`. The owner granted Bluetooth access.
- **Capture:** `captures/E01-passive-gatt.jsonl`.

## E02 — Read-only command matrix (2026-11-02 11:15)

- **Pre-state:** as E01; NOOP idle, last ack at 10:57:40 = `[01] 66960100 0f000000`.
- **Sent (exact bytes):** commands 11, 34, 7, 26, 98, 2, 1, 84, 80, 151, each once, empty data, seq 201–210,
  e.g. GET_CLOCK `aa0108000001e67123c90b00c8ab49ee`. All are gate R in Goose's 5.0 table.

| Cmd | Result | Bytes | Latency | Decoded |
|---:|---|---:|---:|---|
| 11 GET_CLOCK | SUCCESS | 28 | 5723 ms | 1793636096 (11:14:56) vs wall 11:15:09–11:15:14 → strap 13–18 s slow |
| 34 GET_DATA_RANGE | PENDING, SUCCESS | 20, 84 | 2581 ms | trim page 104038 + block 15 = last ack; newest record 11:14:45 |
| 7 REPORT_VERSION_INFO | UNSUPPORTED | 20 | 30 ms | — |
| 26 GET_BATTERY_LEVEL | SUCCESS | 24 | 30 ms | 20 % (= 2A19) |
| 98 GET_EXTENDED_BATTERY_INFO | UNSUPPORTED | 20 | 33 ms | — |
| 2 GET_MAX_PROTOCOL_VERSION | UNSUPPORTED | 20 | 31 ms | — |
| 1 LINK_VALID | SUCCESS | 32 | 62 ms | ASCII `There it is.` |
| 84 GET_BODY_LOCATION_AND_STATUS | FAILURE | 24 | 33 ms | body `01…` |
| 80 GET_ALL_HAPTICS_PATTERN | UNSUPPORTED | 20 | 38 ms | — |
| 151 GET_BATTERY_PACK_INFO | FAILURE | 48 | 32 ms | body `01` + zeros |

- **Side effects:** none expected (all read-only). NOOP stayed connected (no disconnect in its log).
- **Not repeated:** one attempt each, to avoid hammering. Repeat GET_CLOCK and GET_DATA_RANGE in E03 to
  check the clock offset and the +41/+57 interpretation on a second sample.
- **Probe bug found:** write-after-close crash on shutdown (after all data was saved); fixed.
- **Capture:** `captures/E02-readonly-matrix.jsonl`.

## E04 — Realtime HR on/off (2026-11-02 11:29, approved by owner)

- **Pre-state:** NOOP idle (pull ended 11:27:01), no type-40 frames in E01/E02 (realtime off), battery 20 %,
  strap worn, owner at rest.
- **Sent:** read-only 11, 34, 26 (second sample for E02 fields), then `TOGGLE_REALTIME_HR` `[1]`
  (`aa0108000001e67123cc0301bdd35c57`), 43 s capture, then `[0]` (`aa0108000001e67123cd03001c899921`).
- **Results:** both toggles SUCCESS in 34 ms. First type-40 frame 1.0 s after the on-response, then 42
  frames at 1.00 s ± 0.02 s, all 32 bytes, CRC valid, all on fd4b0005. Layout in PACKET_TYPES.md. HR 69 → 59.
  No R-R in any frame. NOOP (sharing the link) decoded the same HR values (`5.0 realtime decode check`).
  Strap clock 14–18 s slow again. Data range second sample confirms +41 = last pulled record, +57 = newest.
- **Restore check (E04b):** 15 s passive capture after the off command: 0 type-40 frames. Strap back to pre-state.
- **Side effect:** NOOP's live heart-rate display took the realtime values and keeps the last one (59) until
  its next reading; it does not persist type-40 to the database.
- **Independent check:** history HR for the same strap seconds is compared in E04c once NOOP pulls them.
- **Capture:** `captures/E04-realtime-hr.jsonl` (realtime frame bytes redacted, timing kept).

## Capture re-check — METADATA layout correction (2026-11-02)

New typed-decoder tests showed METADATA puts its kind in one byte at payload[2] and the time at payload[3]
(not u16 / @4 as first written). Corrected in PACKET_TYPES.md, the Python decoder and `Whoop5HistoryMeta`.

## E04c — realtime vs history HR (2026-11-02 12:15)

Realtime frames arrived 18.25–18.28 s after their strap timestamp (delivered within the same second, 30 ms
jitter, once the ~18 s clock offset is removed). After the 12:07–12:13 pulls stored the same seconds: **42/42
realtime values equal the stored type-47 HR for the same strap second** (mean |Δ| 0 at lag 0; 0.5 at ±1 s,
1.7–1.9 at ±5 s). Both streams carry the strap's per-second HR value on the same timestamps; no extra smoothing
in either. Realtime adds nothing beyond immediacy (and carries no R-R). CONFIRMED.

## E08 — live validation of the new NOOP build (2026-11-02 12:07–12:15, three connects)

| Check | Result |
|---|---|
| Connect, hello, subscribe | 3/3 connects; hello 145 PENDING → SUCCESS |
| Device Information | read once per connect; fw 50.43.1.0 (unchanged) |
| Clock correlation | 17.7–17.8 s strap behind, ±0.5 s (round trip 29–75 ms); persisted to cursors |
| Battery | GET_BATTERY_LEVEL success on every connect; event-3 body matched 0x2A19 (20.0 %, 3706 mV) |
| Data range | typed parse; last-synced → newest used as the pull's span |
| History pull 1 (old ack rule) | stopped at a chunk with type-47 **version 0x1a** records; chunk NOT acked; strap kept it |
| History pull 2 (archive rule) | re-sent chunk absorbed (52 records, 0 new); 80 v0x1a records archived before ack; 38 chunks; COMPLETE |
| History pull 3 | 4 chunks, COMPLETE, processing started 33 ms later and finished in 4 s |
| Events | decoded and stored (unknown bodies kept); live connection events seen around each reconnect |
| Reconnect | app restart ×2: reconnect, re-measure clock, resume pull from the strap's trim pointer |

New protocol facts from this run:
- **Events 33 / 34 = BLE_REALTIME_HR_ON / OFF** (CONFIRMED: strap times matched both toggles in E04 and NOOP's
  11:41 toggle after the 18 s offset).
- **BLE_HR_PROFILE_DISABLED (25) is emitted on every "off" command**, even when the broadcast was already off
  (3/3 connects). Answers the open question in HR_BROADCAST_RESEARCH.md.
- **Event 3 BATTERY_LEVEL**: soc u16/10 @ body 1 and mV u16 @ body 5 CONFIRMED on one sample; charging byte @10
  read 0 while not charging (unproven). Event 63 arrives at the same second.
- **Events 29 and 110 are periodic**: every 10 min (:x6:28 and :x6:31). Bodies UNKNOWN (29's first u32 varies).
- **Event 123** brackets connection changes: body byte 4 = 01 at BLE_CONNECTION_DOWN, 02 at UP (3 samples).
  HYPOTHESIS: a connection-state report.
- **Type-47 version 0x1a (88 bytes)** exists alongside v0x12: strap time u32 at payload 7 (80/80 plausible),
  1-s steps, runs ~20 min apart (one gap 1201 s). Meaning UNKNOWN (ryanbr/noop calls it "R26"). The previous NOOP
  build dropped these while acking their chunks, so earlier v0x1a data was trimmed without being kept.

## Next experiments (need approval or the wearer)

1. **E05** strap off-wrist for 2 min, then on: look for wrist events and the console wear-detect line.
2. **E06** probe as the only client (quit NOOP) without hello: is the hello mandatory?
3. **E07** capture fd4b0007 content at connect (needs the probe to connect before NOOP).
