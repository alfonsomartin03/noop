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

## K01 — one-shot SET_CLOCK (2026-11-18 13:57–14:05 EST, owner-approved)

- **Setup:** NOOP connected, right after a completed pull; no alarm within hours. `ble_probe --k01 --k01-approved`
  attached to NOOP's link. DIS fw 50.43.1.0 / WG50_r52.
- **Run 1 (13:57): no write.** The first GET_CLOCK after subscribing answered ~1 s after the probe's 7-s timeout, so no
  "before" clock existed and the guard skipped SET_CLOCK (as designed). The probe now reads the clock twice first.
  (Run 2 at 13:59 never reached Bluetooth: the rebuilt probe app awaited a new macOS permission; nothing sent.)
- **Run 3 (14:05): PASS.** Before: strap − Mac = **−40.47 s**. `10 [f4f6fd6a 56790000]` → **SUCCESS** (92 ms, body
  `000000`). Read-back: **−0.07 s**. GET_DATA_RANGE still SUCCESS (newest record 45 s before the Mac's time = written
  under the old clock). Capture `captures/K01-set-clock.jsonl` (redacted like C08).
- **After:** NOOP's 14:19 pull logged "strap clock jumped (offset 40.4 s → −0.0 s)", the strap reported its newest
  record at the Mac's time, and history completed normally (17 chunks). Alarm slot: the 14:19 check read the slot with the stale estimate (alarm sync ran on `$clock` willSet; fixed in this change) and only verified; the **14:34** measurement (strap 0.2 s behind) re-SET the next occurrence at exactly its deadline (stored offset 40 s → 0) and read it back SUCCESS. History completed again (17 chunks).
- **Conclusion:** SET_CLOCK `[sec u32][subsec u32]` latches on fw 50.43.1.0 and does not disturb history serving.
  NOOP now re-syncs at most daily (`ClockResyncPolicy`). Stored timestamps before 14:05 keep their old offset
  (option A not done).

## L01 — live R-R unit (2026-11-18 17:2x–17:49 EST, #39; no new strap commands)

- **Setup:** NOOP rebuilt from main (`Whoop5RealtimeTally` + `OpenWhoop/live-rr`), live strap sheet open ~25 min (NOOP's
  own TOGGLE_REALTIME_HR). Strap clock corrected by K01 earlier; both streams are strap-stamped anyway.
- **Tally:** 1,535 live frames over 1,535 s, all 32 bytes, **650 with intervals** (738 words, 0–3 per frame), 0
  truncated. E04's 42 frames at rest had none; intervals do appear in ordinary streaming.
- **Frozen beat-sum method** (history audit bands): **inconclusive** — 4 windows, 0 complete: live frames carry ~0.5
  interval per frame, a subset of beats, so the completeness gate cannot pass.
- **Paired method** (frozen in `live_rr_audit.py` before any live value was examined): per live second, mean live
  words / mean stored history R-R within ±2 s. **650 paired seconds, median 1.0029 (p10–p90 0.82–1.23) → ms.**
  Secondary: **738/738 live words exactly equal a stored history word** in the same span (ticks would sit ~2.4 % off).
- **Conclusion:** live packet-40 R-R words are **milliseconds** on fw 50.43.1.0, the same values as history, sparse.
  No decoder or scoring change (the app does not use live R-R).

## A01 — research capture acceptance (2026-11-18 17:22–17:49 EST, #38; no new strap commands)

- **Setup:** owner started "Capture for 7 days" in Settings ▸ General; NOOP's ordinary pulls at 17:34 and 17:49
  (complete, 18 chunks at 17:49; ordinary acks continued). Checked on copies with `research_archive_check.py`.
- **Research archive:** 1,831 lines, all type 47 v0x12 full 124-byte frames, CRC16/CRC32 valid, provenance
  (capture id, fw 50.43.1.0, hw WG50_r52, strap time) on every line, stored time = decoded time, 0 repeats.
- **Survival:** 1,831/1,831 records present in the SQLite-backup copy's `hrSample` with the same heart rate, and the
  archive span (17:18:34–17:49:04) holds exactly 1,831 stored seconds: nothing saved was missed.
- **Replay:** inserting the archive twice into an `hrSample`-keyed table added 1,831 then **0** rows (idempotent;
  WhoopStore uses the same ON CONFLICT DO NOTHING).
- **Undecoded archive (today's UTC file, 2,880 v0x1a lines):** CRC valid; 200 lines without provenance are from
  Nov 17 19:00–19:44 EST (a build before provenance); 39 byte-identical repeats = chunks the strap re-sent; replay
  idempotent.
- **Inventory (sizes only):** DB 384 MB + WAL; research-history 0.7 MB; live-rr 0.3 MB; undecoded-history 11 MB;
  preferences in the app domain (85 keys). Restore/replay: `RESEARCH_CAPTURE.md`.
- **Fail-before-ack:** unit-tested (archive write failure → problem; `HistoryAckGate` refuses the chunk and any
  repeat END); the CoreBluetooth path itself is code-reviewed. Cap/expiry ends capture without blocking sync
  (unit-tested). Capture left running (ends by itself after 7 days) to gather full frames for #44.

## M01 — ordinary-use operating metrics (offline, 2026-11-18, #46)

- **Inputs:** SQLite-backup copy of the app DB (events from 11-02; HR coverage ≥ 97 % on every full day 11-03 → 11-17)
  and the app's unified log (retained only 11-18 04:23 → 13:41). `Tools/whoop_re/ops_metrics.py`; aggregates only.
  No strap commands.
- **Alarm-slot writes (#29):** STRAP_DRIVEN_ALARM_SET (event 56, one per slot write, deduplicated by event identity):
  median **49/day** over 14 complete days before 11-17 (range 10–64) → **2/day** on 11-17 and 3 on the partial 11-18.
  Today's log: 3 SET_ALARM_TIME vs 26 GET_ALARM_TIME (read-before-write verifies). Reduction CONFIRMED on this strap.
- **Battery level reads (#32):** today's log has 6 GET_BATTERY_LEVEL commands and 25 "level pushed … not asking" skips
  in 9.3 h (≈ 31 polls would have asked before #32). No pre-#32 log is retained, so the baseline is the code's
  one-per-15-min poll, not a measured count. Pack info (151) is still asked each poll (31).
- **Connections:** 15–51 BLE_CONNECTION_UP per complete day except 11-09/11-10 (67/282: the idle-silence reconnect bug
  fixed 11-10). Today's 70 app "Connected" lines include a 09:41–10:17 run driven by the **Mac's Bluetooth powering
  off/on** (67 poweredOff lines) — a host confound, not a NOOP reconnect loop.
- **Battery drain, 99 → 85 % per pass:** 11-03 → 11-04 **10.7 %/day**; 11-09 → 11-10 **15.7 %/day** (spans the
  reconnect storm); 11-16 → 11-18 **6.0 %/day** (after #29; #32 from 11-17). Three passes, wearer activity, realtime-HR
  use and connection time uncontrolled: consistent with fewer strap writes, **not** an attributed saving.
- **Clock:** strap behind the Mac by 31.6 s (11-12) → 40.1 s (11-18); drift **+1.40 s/day** (16 ppm) from live
  alarm-history events, matching the log's GET_CLOCK readings (40.1–40.4 s today). Corrected at 14:05 by K01 (above).
- **Retention:** across 28 pulls today the strap's oldest record advanced with wall time (Oct 27 07:48 → 16:49 while
  the clock went 04:23 → 13:41): a ~22-day rolling buffer independent of acks, as before. Trim/erase semantics remain
  UNKNOWN (no pointer experiments).
- **Not measured:** per-type command counts before 11-18 (log not retained), transfer bytes/duration per pull, a
  controlled multi-day battery comparison.

## C08 — named configuration reads 121/128 (2026-11-18 13:23–13:25 EST, owner-approved)

- **Setup:** NOOP running and connected, 2.5 min after a completed history pull; next alarm the following morning.
  `ble_probe --c08 --c08-approved --seconds 90` attached to NOOP's shared link; one attempt per read, seq 201–204, payloads
  from `Whoop5ConfigRead.requestPayload` (48-byte frames). DIS: fw 50.43.1.0, hw WG50_r52; 2A19 85 %.
- **Results (all result 1 = SUCCESS, 84-byte frames, decoded body 67 = 65 semantic + 2 zero alignment bytes, revision 1,
  key echoed exactly):** `121 sigproc_wear_detect` → `0` (5.8 s); `121 cont_collection_mode` → `0` (2.6 s);
  `121 max_collection_backlog` → `8.3` (62 ms); `128 disable_pip_r26_packets` → `2` (31 ms). No stop condition fired.
- **Reading (reference semantics, fw 50.42.1.0, not verified here):** R26 publication permitted (consistent with the R26
  records already archived); continuous optical/IMU collection mode off; backlog threshold 8.3 (% of capacity, tenths);
  wear-detect tri-state value 0 (meaning unresolved). Nothing was written; no setting changed.
- **After:** no console lines or events during the run; the probe dropped only its own claim and NOOP stayed connected.
- Capture: `captures/C08-config-reads.jsonl` (redacted like C06a/C07: serial redacted, session id dropped, no fd4b0007 bytes).

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

## S01 — step counter across midnight (2026-11-17/18, passive, no strap commands)

- **Source:** SQLite-backup copy of the app DB after normal syncing (rows 2026-11-17 14:07 → 2026-11-18 10:10 local EST,
  9,171 change points, HR at 1 Hz through the night). Aggregates only.
- **Midnight:** **no reset.** The counter ran 19,238 → 19,290 across local 00:00 (and across 19:00 = UTC midnight) and
  stayed flat overnight.
- **Reset:** one drop only, **19,362 → 0 at 08:15:29** local — 1 s after an alarm rang (events 58 + 60 at 08:15:28),
  2 s before the double-tap dismissal (14 + 100 reason 2 at 08:15:31) and ~2.5 min after NOOP's main sleep ended
  (08:12:59). Counting resumed at 08:15:48.
- **Conclusion:** the counter is **not a calendar-day count**; it reset at waking (HYPOTHESIS: the strap's own
  wake/cycle boundary, or the alarm dismissal — one morning cannot separate them). NOOP's tile is unaffected: it adds
  increases over the local day and never subtracts a drop (3,465 steps from 00:00 to 10:11, 1 reset). The pre-reset
  value (19,362) is probably the previous wake-to-wake total, but the prior reset was not stored.
- **Next:** a morning without an alarm (natural wake) and a nap/late-wake day to tell the triggers apart.


## S01 night 2 — no-alarm morning (2026-11-18/19, passive, no strap commands)

- **Source:** SQLite-backup copy at 2026-11-19 13:31 EST (16,644 step change points, 11-17 14:07 → 11-19 13:25 strap
  time); NOOP's unified log for the same 24 h. Aggregates only. The alarm is Mon/Wed/Fri: Thursday had **no alarm**
  (no alarm lines in the log, no event 58/60).
- **Result:** **no reset.** `step_reset_scan.py` still finds the single 11-18 08:15:29 drop only. The counter ran
  continuously across local midnight (12,457 at 00:00, second night with no midnight reset), across NOOP's main-sleep
  end at 09:20:59 (+510 in the 09:00 hour, activity code 1) and across 08:15 (24 h after the first reset), to 15,267 at
  13:25. HR coverage was complete 07:00–11:00, so the strap was worn through waking.
- **Reading:** waking alone and a fixed daily time do not reset the counter. Remaining candidate: the alarm (ring,
  haptics or dismissal) — **SUPPORTED by one event plus one negative control**, not confirmed.
- **Frozen prediction for the next alarm morning (Fri 2026-11-20, smart window 07:45–08:30):** one drop to ≈ 0 within
  ≤ 5 s of the alarm's ring events (58/60); none at waking if the wearer wakes earlier without the alarm. A drop
  elsewhere, or none at all, falsifies the alarm trigger.

## M02 — log catch-up (2026-11-18 21:12 → 11-19 13:30 EST, offline, no strap commands)

- **K01 daily re-sync observed live:** 05:34:53 after a completed pull — strap 1.0 s behind → SET_CLOCK SUCCESS →
  read-back 0.1 s behind (±0.5 s). Exactly one SET in 24 h; every other clock measurement read 0.5–0.7 s.
- **Mac Bluetooth power cycling again:** 22:26–22:58 and 12:00–12:50 (53 + 67 poweredOff states, typically every
  25–45 s; 108 connects). Same pattern as 11-18 09:41–10:17, and bluetoothd itself reports the power state (not NOOP).
  NOOP's pulls stayed at 4/h through both storms (`BackfillPolicy`); each reconnect still does hello + setup.
- **Ordinary pulls:** 61 pulls, all ended HISTORY_COMPLETE; pack info answered FAILURE (unavailable) 61×; battery level
  read skipped 55× because the strap had pushed one. Undecoded records archived on 49 pulls.
- Log retention this time was ~24 h, still short of multi-day counts → in-app daily counters (#46, `OpsCounterStore`).

## R26 + event 120 rerun (2026-11-19, offline, #45, copies only)

- **R26 optical bursts** (`ppg_burst_check.py`, 18 archive files, 1,220 bursts ≥ 30 s with stored HR):
  - Default mode: 67 % within 5 bpm, but 334 peaks sit at 57–63 bpm (the 1 Hz record rate), and the within-HR-decile
    control already reaches 63 %.
  - With the artifact masked (`--mask-1hz`): 55 % vs 51 % within-decile, ~40 % with HR shifted ±10 min, and 19 %
    shuffled; 28 % at HR ≥ 80.
  - **Decision: no product use** — weak burst-specific pulse content, no SpO₂ path, nothing better than existing HR.
- **Event 120** (`event120_check.py`, 219 reports): nothing passes the exploratory per-half Bonferroni. Three
  candidates clear the overall threshold with same-sign halves. They are **frozen** in the script (`FROZEN`) with their
  predicted sign, for a hold-out on reports from **2026-11-20** onward (≥ 80 reports, ~2026-11-27):
  - u16@18 ~ hr_prev (+)
  - u16@21 ~ hr_next (−)
  - u8@9 ~ move_prev (−)
- No re-selection after seeing hold-out data. A SUPPORTED result is a correlation with NOOP's own streams, not a decode.

## R18 field inventory (2026-11-19, offline, #44; research-capture copies only)

- **Input:** `r18_field_inventory.py` on copies of `OpenWhoop/research-history`. 74,444 R18 lines, 0 bad CRC, 61
  same-second repeats; 74,383 unique records (20.7 h of seconds, 2026-11-18/19). Aggregates only.
- **Inventory:** 112-byte payload — 46 constant, 17 few-valued (≤ 8 values), 49 varying. The only clean f32 fields
  are the known 33/37/41/45, plus **@105**.
- **float@33:** never negative; median 0.008 still, 0.164 walk, 0.731 run; r +0.39 with per-second |Δgravity|.
  The three gravity floats form a unit vector (95.8 % within 1 ± 0.05); adding @33 does not (p99 1.24).
  → **dynamic-acceleration magnitude SUPPORTED, quaternion REJECTED.** Scale is unassigned.
- **u8 @29:** r +1.00 with HR @14, equal in 77 %, > 3 bpm apart in 1.1 % → a second HR value; meaning unresolved.
- **f32 @105:** around −5.2 at rest, −3.0 walking, −2.0 running → activity-linked; meaning unknown.
- **Few-valued unlabelled bytes:** ≤ 0.023 bits of mutual information with activity code. No motion/rest flag found.
- **Frozen for hold-out** (EVIDENCE_MATRIX §2 rows "#44"): re-run `--since 2026-11-20` on later copies with the same
  pass/fail rules. Research capture ends 2026-11-25 (7-day limit), so the hold-out covers ~11-20 → 11-25.

## T02 — nightly skin temperature on ordinary nights (2026-11-19, offline, #43; SQLite-backup copy, no strap commands)

- **Samples:** 255,907 `centi_celsius` rows from 2026-11-16 14:40, at ~1 Hz all day (86,399 on Nov 17, 86,094 on
  Nov 18).
- **Pipeline (`skin-temp-night-v2`):** nightly value stored for the nights ending Nov 17, 18 and 19, each with
  coverage 1.0 of asleep seconds. Nov 15/16: "no skin-temperature samples" (before storage began).
- **Change vs baseline:** `skinTempDevC` is unavailable on all three nights with reason "no usable reference" —
  correct, since it needs ≥ 5 earlier nights. **Prediction:** the first provisional change appears for the night
  ending 2026-11-22, if every night stays usable.
- **Off-wrist:** the only strap-reported off/on pair since storage began (as of T02) is the 2-min C02a test (11-16 14:57/14:59); see T03 for a timed removal.
  None fell in a night, so off-wrist exclusion is still unexercised on real nights; that needs a wearer-timed
  longer removal.
- **UI:**
  - Health tile caption while waiting changed from "none stored yet" (wrong once nights exist) to "Change appears
    after 5 nights of NOOP skin temperature".
  - Overview HR card render with strap-reported off-wrist time (synthetic) looked at, 760 dark and 420 light: the
    caption names it ("Strap reported off the wrist for 1 h 18 min"), and the warning stays for the unexplained 2 h 42 min.
- **Reference accuracy:** unknown; no reference thermometer.

## T03 — wearer-timed removal (2026-11-19 evening, #43; passive, SQLite-backup copy, no strap commands)

- **Wearer's times:** off 18:29, back on ~18:52 (EST), reported in chat as they happened.
- **Strap events (synced by the ordinary pulls):** WRIST_OFF (10) at 18:29:03, WRIST_ON (9) at 18:52:37 — both
  within a minute of the wearer's times; strap clock re-synced the day before (K01), so no offset to correct.
- **History while off:** no HR and no skin-temperature rows between the two events (HR gap 18:29:02 → 18:52:37, the
  only gap > 60 s in 18:28–19:10); the strap does not record history off the wrist, at least for this ~24 min.
- **Skin temperature:** 30.0 °C mean in the 10 min before removal; the first ~30 s after re-wear read 26.7–29.1 °C
  (strap cooled off the wrist). Observation only: `skin-temp-night-v2` excludes the off interval but not this
  re-warming tail; it matters only for a removal inside a night and is not changed here.
- **Result:** wrist-wear pairing (`WristWear`) gets a 23 min 34 s interval, above the 1-min caption threshold, so the
  Overview HR card should say "Strap reported off the wrist for 23 min" for today. **Not seen in the app** (wearer
  to check); the caption logic itself is unit-tested and the render was checked in T02.
- Still open: a removal inside a night (off-wrist exclusion in the nightly skin value), VoiceOver.
