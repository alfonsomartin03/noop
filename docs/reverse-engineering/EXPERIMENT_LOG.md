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

## H01 — GET_ALARM_TIME, read-only (2026-11-02 12:55)

Sent 67 `[4, 0]` (Goose's 5.0 form) `aa010c000001e74123c943040000000086be1237` → FAILURE in 32 ms with a 23-byte body
`04 00…00`. Unsupported commands answer UNSUPPORTED with a 3-byte body, so the 5.0 alarm command family is present on
fw 50.43.1.0. FAILURE most likely means slot 0 is empty (HYPOTHESIS). No side effects. See ALARM_CAPABILITIES.md.

## Sleep-session classifier on real data (2026-11-02 13:04)

After the new classifier re-scored the stored history: Oct 22 – Nov 2 = 12 primary sessions (one per night), no naps,
no interrupted nights, all at the habitual time. Nov 1 is 12 h 11 min (00:01–11:12 across the DST fall-back; HR at
sleeping level until ~11:10) — plausible lie-in, unconfirmed. No reference comparison possible: the WHOOP export ends
Oct 21 and NOOP's computed sleep starts Oct 22.

## H02–H06 — approved alarm tests, slot 0 (2026-11-02 13:07–13:12)

SET 66 and RUN 68 for alarm id 0 → FAILURE, status INVALID_ALARM_ID (body `[rev][0x0b][00]`); nothing stored, no
vibration expected. GET 67 → FAILURE (empty). DISABLE-ALL 69 `[2,0xFF]` → SUCCESS. H04 not run (no stored alarm).
Follow-ups with id 1 and haptic 19 proposed in ALARM_CAPABILITIES.md (need approval: different bytes).

## H07, H02b–H06b, H04 — approved (2026-11-02 13:14–13:27)

Haptic 19 (one loop) played (SUCCESSFUL_PLAY + HAPTICS_FIRED). Alarm id 1: SET SUCCESS, GET read-back, RUN plays and
consumes the slot. **H04: a stored alarm rang at its exact strap time with nothing connected (event 57), and was
stopped by a double tap (14 + 100 reason 2).** Live events stream on fd4b0004. A fresh connection without the hello
accepted every command. Details: ALARM_CAPABILITIES.md. **Wearer confirmed feeling all three buzzes** (H07, H06b, H04).

## C02a — passive wear off/on (2026-11-16 14:57–15:02, owner-approved)

- **Tool:** `ble_probe --passive --seconds 300` (new mode: no command option accepted, `write` refuses). Probe wrote **0** frames;
  it subscribed to fd4b0003/04/05/07 and read DIS/battery (serial redacted). NOOP was not connected at start, so the probe
  made a fresh connection (no hello).
- **Wearer actions:** strap off 14:58, back on 15:00 (times from the wearer, minute resolution).
- **Result:** fd4b0004 delivered event **10** at 14:58:12 and event **9** at 15:00:15 (empty bodies), plus event 29 at 14:58:44
  (soc field 994 = 99.4 %, 2A19 = 99). fd4b0007 sent nothing. DIS read live: fw `50.43.1.0`, hw `WG50_r52`.
- **Conclusion:** wrist off = 10, wrist on = 9 (CONFIRMED once). Capture: `captures/C02a-wear-off-on.jsonl` (redacted).
- **C02b (charging):** not run — no charging pack available; still approved in scope for later.

## W01 — counted walk vs stored step counter (2026-11-17, wearer only, no strap commands)

- **Setup:** NOOP from `main` (schema v19) connected and syncing normally; nothing else talked to the strap.
- **Wearer:** one continuous ~4-minute walk, steps counted by hand (count may be slightly low by the wearer's own account),
  start/end times to the second. The wearer was moving shortly before and after, not standing still.
- **Result** (`step_walk_check.py` on a SQLite-backup copy, after the next history pull): strap **326** vs counted **335**
  (−9, **−2.7 %**), 0 resets, 196 of 245 s at activity code 1. Edge sensitivity: the 2 min before the start held 47 strap
  steps and the 20 s before it ~17, so a few seconds of clock/timing offset moves the total by ~±20.
- **Conclusion:** the counter at payload 49 counts steps — **SUPPORTED by one walk** within a few percent; the hand count's
  own error and the moving edges are of the same size as the difference. Not validated for display.
- **Next:** see W02; still open: a ≥ 1,000-step walk with still edges, and the reset time across local midnight.

## W02 — counted walk with pace changes and a run (2026-11-17, wearer only, no strap commands)

- **Wearer:** ~700 steps counted by hand, pace changed every 100, the last 100 running; then stood still ~30 s, then walked
  indoors (not counted) before noting the end time. Edges: 29 strap steps in the 2 min before the start, none after the end.
- **Result:** over the noted window the strap gave 775 (+10.7 %), but the per-second rows separate the parts: the counted
  part ends where the run ends, at **709** strap steps (**+9, +1.3 %** vs ~700); the counter is then flat for 32 s (the
  stop) and adds 66 during the indoor walk. Time per 100 strap steps: 56, 58, 68, 49, 54, 44, 35 s — the pace changes
  fall at the strap's own 100-step marks, and the last 100 at ~170 steps/min.
- **Activity code @55:** **2 appeared only during the run** (and 6 s of the brisk indoor walk); 1 during walking; 0 at
  rest, including the stop. **HYPOTHESIS: 0 still / 1 walking / 2 running** (one run; no other 2 in the stored data).
- **Conclusion:** two walks within −2.7 % and +1.3 % of hand counts, running included; the counter's increments are
  timely to the second. Hand counts are approximate, so this bounds error at a few percent, no tighter.

## W03 — timed run, steps not counted (2026-11-17, wearer only, no strap commands)

- **Wearer:** ran for a noted ~2 min 05 s window; no step count. The wearer also judged their W01/W02 hand counts unreliable
  (likely low), so hand counts are no reference for accuracy: W01/W02 show the counter tracks steps to the second, not an
  error figure.
- **Result:** activity code **2 for 2 min 02 s** (one 2-s dip to 1), at a steady 152–164 steps/min, **320 strap steps**;
  then a few seconds of 1, then 0 (stopped), a short walk, 0. The strap's run started ~31 s before the noted start and ended
  ~34 s before the noted end: the same length, shifted. The noted times likely came from a clock about 30 s ahead of the
  Mac/strap (the edges of W01/W02 fit a similar offset).
- **Conclusion:** activity code **2 = running, CONFIRMED on two runs** (W02, W03); 1 = walking, 0 = still remain
  SUPPORTED. Note times from the Mac's clock in future checks.

## C06a, C07 — approved reads (2026-11-17 15:47–15:54, owner-approved "all")

- **Setup:** NOOP running and connected, right after a completed history pull; no alarm within 30 min. Each command in its
  own probe run (attached to NOOP's shared link), one attempt, seq 201. Each run wrote exactly **1** frame.
- **C06a** `151 [01]`, pack off: **SUCCESS**, body `01` + 30 zero bytes (latency 4.6 s). With `[]` the strap always
  answered FAILURE with the same body, so the revision byte was the cause. Pack-on run (C06b) deferred: no pack at hand.
- **C07** `40 []`, `42 []`, `44 []`: each **UNSUPPORTED** (result 3, body `000000`), 4.9–5.2 s. No console lines, no events.
- **After:** DIS/battery read normally in every run (fw 50.43.1.0, 2A19 90 %); NOOP kept its link and pulled history again.
- Capture: `captures/C06a-C07-afe-pack-reads.jsonl` (redacted; fd4b0007 fragments dropped).

## Offline analysis — v0x1a optical bursts, events 110/120/14 (2026-11-17)

- **v0x1a:** 287 bursts (Nov 14–17 archive copy); 25 samples/s reconstructed from base + cumulative deltas. In 161/279
  bursts with stored HR the strongest 40–200 bpm component is within 5 bpm of the strap's HR (median gap 2.5 bpm; ≈ 6 %
  expected by chance; never at 2 × HR) → **PPG pulse waveform**, one stream. Byte 14 is a slow 0/1 state (3 changes in
  4 days, not aligned with sleep). No second channel → no SpO₂.
- **Event 110:** changes only around the four stored charge sessions (byte 2 = 1 / byte 3 = 2–3 on the pack, 4 after
  CHARGING_OFF, 0 hours later) → charger-status report (HYPOTHESIS, strong), matching 117's stages.
- **Event 120:** every 2 h; no battery correlation; u16 @8 correlates r ≈ 0.50 with mean HR over the prior 2 h (196
  reports) → a periodic summary, meaning open.
- **Event 14:** 0 occurrences during ~1.6 h of step data with two walks and a run → not a motion/step detector.

## Offline re-check — clock, steps, optical bursts, event 120, alarm writes (2026-11-17 evening, no strap contact)

- **Strap clock:** receipt − strap time of live events (app alarm history) gives a daily minimum rising 22.2 s (Nov 5) →
  38.9 s (Nov 17), +1.41 s/day (~16 ppm); Nov 2 GET_CLOCK replies (17.9–18.9 s) match the live events in the same
  captures, so latency < ~1 s. NOOP never sends SET_CLOCK to a 5.0 (not allowlisted), so stored 5.0 times run ~40 s
  late. Re-reads C02a: 14:58:12 / 15:00:15 were Mac receipt times of events stamped 14:57:34 / 14:59:37 strap time.
- **Step resets:** only two decreases in all local data, bounded by 7- and 26-day gaps → reset timing unobservable yet.
- **Optical bursts:** the earlier "58 % vs ≈ 6 % chance" does not survive controls (EVIDENCE_MATRIX.md §3); with the
  stored deltas a weak HR relation remains (HR ≥ 80: 28 % vs 9 % shuffled).
- **Event 120:** the HR correlation is mostly time-of-day and movement; no field replicates under split-half Bonferroni.
- **Alarm writes:** 2 event-56 rows on Nov 17 (was ~50/day); app history: 1 deadline SET, 1 ring-now SET, 52 GET verifies.
- Tools: `strap_clock_offset.py`, `step_reset_scan.py`, `ppg_burst_check.py`, `event120_check.py` (copies only).

## Next experiments (need approval or the wearer)

1. **E05** strap off-wrist for 2 min, then on: look for wrist events and the console wear-detect line.
2. **E06** probe as the only client (quit NOOP) without hello: is the hello mandatory?
3. **E07** capture fd4b0007 content at connect (needs the probe to connect before NOOP).
