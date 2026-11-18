# Capability matrix (issue #25, phase 1: offline inventory)

Reconciled 2026-11-16 at `origin/main` `ff1dcb7` against current source, tests, the committed captures, the
app's undecoded-history archive and the app database (both analysed as **copies**). **No strap interaction**:
nothing was sent, read or subscribed for this document. Labels as in [README.md](README.md). Hardware claims are
scoped to the unit last read in E01/E02: WHOOP 5.0, fw `50.43.1.0`, hw `WG50_r52`. The app’s cached Device Information read corroborates that firmware as of 2026-11-16; no additional probe contact was made.

Private inputs (stay local, never committed): a SQLite-backup copy of the app DB (events 2026-11-02 → 11-16)
and a copy of `undecoded-history/*.jsonl` (15 day files, 41,237 frames). Only aggregate structure is recorded
here: no biometric values, identifiers, bodies of identity responses or timestamps of personal activity.

## 1 · Characteristics

| Characteristic | Current evidence | Label | Open question | Next step (tier) |
|---|---|---|---|---|
| 180A DIS 2A24/2A26/2A27 | model `5.0`, fw `50.43.1.0`, hw `WG50_r52`: E01/E02, and the app's own cached read (`noop.deviceInfo`, read 2026-11-16 13:46 local) | CONFIRMED, current as of 2026-11-16 | — | C01 closed without probe contact |
| 2A19 Battery | % equals cmd 26 | CONFIRMED | — | — |
| 2A37 HR | only while cmd 14 on | CONFIRMED | — | — |
| fd4b0002 | command input | CONFIRMED | — | — |
| fd4b0003 | command responses | CONFIRMED | — | — |
| fd4b0004 | **live events in real time** (H02b–H07, 2026-11-02); the same events replay on fd4b0005 in the next pull | CONFIRMED (supersedes "silent") | Does every event go live here, or only some kinds? | Passive capture during ordinary use (approval) |
| fd4b0005 | history 47, events 48, metadata 49, console 50, realtime 40 | CONFIRMED | — | — |
| fd4b0007 | 244-byte fragments at connect, before hello | SUPPORTED (Memfault/debug name external only) | Framing, build id, reset reasons | Offline review of existing captures first; then passive capture at connect (approval). No debug writes. |

## 2 · Commands

Tier = [SAFETY_MATRIX.md](SAFETY_MATRIX.md). "Probe" = `Tools/ble_probe` allowlists; "App" = `BLEManager.whoop5Allowed`.

| # | Name | Tier | Probe | App | Evidence | Open question / next |
|---:|---|---|---|---|---|---|
| 1 | LINK_VALID | auto | yes | — | SUCCESS, ASCII body (E02) | — |
| 2 / 7 / 80 / 98 | version / ext. battery / haptic patterns | auto | yes | 7 allowed, not sent | UNSUPPORTED (E02) | Do not resend without a reason (firmware change) |
| 3 | TOGGLE_REALTIME_HR | reversible | `--toggle 3` | yes | E04 | R-R slots never populated |
| 11 | GET_CLOCK | auto | yes | yes (every connect + every history pull) | CONFIRMED | Drift rate: derive offline from app logs before any new read |
| 14 | TOGGLE_GENERIC_HR_PROFILE | reversible | — | yes (opt-in) | CONFIRMED | — |
| 19 / 122 | haptic buzz / stop | restricted (approved fixed forms) | `--alarm-script buzz` | yes, fixed forms | H07 | Patterns beyond the notify buzz UNKNOWN |
| 22 / 23 | history pull / ack (trim) | reversible / data-affecting | never | yes, ack only after durable save | CONFIRMED | Whether trim erases: UNKNOWN |
| 26 | GET_BATTERY_LEVEL | auto | yes | yes | CONFIRMED | — |
| 34 | GET_DATA_RANGE | auto | yes | yes | partly CONFIRMED ([PACKET_TYPES.md](PACKET_TYPES.md)) | Words +1/+9/+21/+25: more samples from app logs (offline) |
| 66–69 | alarm set/get/run/disable | restricted (approved fixed forms) | `--alarm-script` (ids 0/1) | yes, id 1 only | H02b–H07, H04 | See §5 (rewrite cadence) |
| 67 (probe default) | GET_ALARM_TIME | auto in probe | `READ_ONLY_PAYLOADS` reads id 1 (was id 0 until 2026-11-16) | id 1 | id 0 is invalid (H02) | Fixed in probe source; compiled, not run |
| 84 | GET_BODY_LOCATION_AND_STATUS | auto | yes | — | FAILURE `01 00…` (E02) | Goose debug list: no payload, "render-only status command" (E02 already sent that). Cause of FAILURE UNKNOWN; don't resend without a new reason |
| 141 | GET_ADVERTISING_NAME | auto | yes | — | never sent; response redacted by the probe | Low value (identifier); keep unsent |
| 145 | GET_HELLO | auto | static hello | yes | CONFIRMED; body redacted | Not required for other commands (E06) |
| 151 | GET_BATTERY_PACK_INFO | auto | yes | yes (connect + poll) | E02 shape = `unavailable`, **not** "no pack"; SUCCESS = `answeredUndecoded` (`Whoop5Charging.packInfo`) | C06a: probe `--pack-rev1` sends `[01]`, SUCCESS with pack off (`01` + zeros). App still sends `[]`; C06b pack-on capture pending before app decoding |
| 35, 76 | Harvard hello / name | registry "auto" | **no** | — | none | Identity data; no reason to send |
| 40, 42, 44 | GET LED drive / TIA gain / bias | probe read-only | **yes** | — | C07: all UNSUPPORTED | Empty payload, one approved read each on fw 50.43.1.0. SET pairs (39/41/43) hard-blocked; do not repeat without a new reason |
| 121, 128 | GET_DEVICE_CONFIG_VALUE / GET_FF_VALUE | registry "auto" | **no** (probe `--c08` only) | **C08 2026-11-18** | 4 named reads | **Layout CONFIRMED on fw 50.43.1.0 by C08 (2026-11-18):** all four fixed reads answered SUCCESS, 84-byte frames, 67-byte decoded body = 65 semantic bytes + 2 zero alignment bytes, revision 1, key echoed exactly, NUL-terminated decimal text (`sigproc_wear_detect` 0, `cont_collection_mode` 0, `max_collection_backlog` 8.3, flag `disable_pip_r26_packets` 2). Value *meanings* still come only from the reference below (e.g. flag 2 = R26 permitted, matching the R26 records already archived; collection mode 0 = no continuous optical/IMU collection); effects and defaults are not verified. **Blocker revised 2026-11-17.** ryanbr `PROTOCOL_CONFIGURATION.md` (fw **50.42.1.0**; ours 50.43.1.0): request = revision `01` + a 32-byte field holding a **NUL-terminated ASCII name** (≤ 31 bytes, NUL-padded) — not a binary/hashed key. Response 65 bytes: revision, 32-byte key echo, 32-byte NUL-terminated decimal text value; unknown key → result 0 + zero value; slot-read failure → result 1 + zeros (a zero can be a fallback). Names listed there: 8 device keys (e.g. `sigproc_wear_detect`, `cont_collection_mode`, `max_collection_backlog`) and 25 flags (20 named-lookup eligible, e.g. `enable_r22_v4_packets`, `disable_pip_r26_packets`, `wear_detect_fast_event`). **No capture, APK or parser evidence is cited for the 121/128 layout itself** (ATTRIBUTION validates the SET 0x78 opcode and flag names against a decrypted HCI capture, not these reads); dofek has no 121 entry and labels opcodes inconsistently. Status: layout **documented (one source, unverified)**; requests constructed offline in §7 C08; padding-aware classifier + gated probe mode prepared 2026-11-18 (#40, synthetic tests only); nothing sent |
| 132 | GET_RESEARCH_PACKET | registry "auto" | **no** | — | none | Goose debug list: no payload, "read". Response undocumented. Its SET (131) is prohibited. Low priority |
| 10, 16, 20, 33, 63, 77, 79, 81/82, 96/97, 105–108, 123–125, 139, 140 | state-changing | restricted | no | no | SUPPORTED (Goose) only | Each needs a written procedure + approval; none proposed in this phase |
| 25, 29, 32, 36–39, 41, 43, 45, 52/53, 83, 99, 115–120, 131, 142–144, 153/154 | trim / reboot / firmware / DFU / optical writes / config writes / persistent toggles | **prohibited** | no | no | — | Never sent. Firmware ops say nothing about a dump path |

Mismatch to keep in mind: the registry labels 35, 40, 42, 44, 76, 121, 128, 132 "auto (read-only)" from Goose's R
gate, but the probe cannot send them and SAFETY_MATRIX's auto tier does not list them. The probe allowlist is
authoritative; a new read needs exact arguments and approval first.

## 3 · Events (from the app DB copy, 2026-11-02 → 11-16)

Counts are kept coarse. "Name" is NOOP's 4.0-derived label; both `NAME` and `EVENT_n` rows exist for some numbers
because older builds stored unnamed kinds.

| Event | Seen | Body | Pattern (aggregate) | Label / note |
|---:|---|---:|---|---|
| 3 BATTERY_LEVEL | ~1k | 20 | soc @1, mV @5, charging = byte 9 bit 0 | CONFIRMED (charging bit on 500 stored events) |
| 7 / 8 CHARGING_ON/OFF | ~15 each | — | around charging | CONFIRMED |
| 9 / 10 | 2 each (DB); 1 each (C02a) | 0 | **10 = wrist off, 9 = wrist on**: C02a, strap removed 14:58 → event 10 live on fd4b0004 at 14:58:12; replaced 15:00 → event 9 at 15:00:15 (wearer-timed). Rare in the DB because the strap is seldom taken off | **CONFIRMED** (one timed off/on, fw 50.43.1.0) |
| 11 / 12 connection up/down | ~680 each | 0 | | CONFIRMED |
| 14 (labelled DOUBLE_TAP) | ~780 | 0 | almost only during waking hours, often clustered (gaps ≤ 60 s); also after alarm dismissal (H04/H06b) | Dismissal use CONFIRMED; that every 14 is a deliberate double tap is **HYPOTHESIS**; 2026-11-17: **none** fired during ~1.6 h of stored step data that included two walks and a run, so it is not a step/motion detector firing while moving |
| 21 / 22 pack connected/removed | few | — | | CONFIRMED |
| 25 HR profile disabled | ~430 | — | near connects (NOOP keeps broadcast off) | CONFIRMED |
| 29 STRAP_CONDITION_REPORT | ~2k | 12 | every 10 min, same second as 110. **Body u16 @6 = battery state of charge × 10** (0.1 %): equals event 3's soc within 2 min in 128/248 pairs, the rest off by a few tenths as the battery moved; correlation 1.0 (2026-11-16). Byte 0 / u16 @0, bytes 1, 4 unrelated to battery | soc field **locally CONFIRMED**; rest UNKNOWN |
| 33 / 34 realtime on/off | ~400 / ~30 | 0 | | CONFIRMED |
| 43 | 18 | 0 | always with a connection down/up and 123 | UNKNOWN (connection-related) |
| 56 STRAP_DRIVEN_ALARM_SET | ~610 | 24 | median gap 15 min; ~50/day | CONFIRMED meaning; cadence = §5 finding |
| 57 / 58 / 60 / 100 | few | | alarm execution / haptics | CONFIRMED |
| 63 EXTENDED_BATTERY_INFORMATION | ~1k | | same second as 3 | name SUPPORTED, body UNKNOWN |
| 109 | 66 | 28 | only while charging, 10-min spacing; only u16 @23 varies: ≈ 994 flat to ~34 % soc, then tapering to ≈ 300 by ~95 % (correlation with soc −0.95) | **HYPOTHESIS: charge current** (constant-current then constant-voltage taper); units unknown |
| 110 | ~2k | 8 | every 10 min with 29. Body `01 01 00 00 00 00 00 00` at rest; changes only around charging (4 sessions): byte 2 = 1 and byte 3 = 2 (`01 01 01 02 00 03 00 00`) alternating with `01 01 00 00 0c 00 08 00` while on the pack, byte 3 = 3 near the end, byte 3 = 4 after CHARGING_OFF, back to 0 hours later (one byte-3 = 4 interlude on 11-07 without charging). 2026-11-17 offline | **HYPOTHESIS (strong): periodic charger-status report**; byte 3 follows the 0/2/3/4 stages of event 117, corroborating them |
| 117 | 88 | 4 | byte 1: 2 at every CHARGING_ON, 0 at every CHARGING_OFF, 3 only at 88–92 % soc (alternating with 2), 4 only at 100 % just before the pack is removed | **HYPOTHESIS (strong): charger state** — 0 idle, 2 charging, 3 top-off, 4 full |
| 120 | ~180 | 32 | every 2 h exactly; bytes 1/2/26 in 1–3; no battery correlation (abs r < 0.23); u16 @8 and bytes 21–25 correlate with mean HR over the preceding 2 h (r ≈ 0.45–0.50, 196 reports). **Re-checked 2026-11-17** (`event120_check.py`): u16 @8 follows prior-2-h movement more (r −0.77) than HR (−0.50); after removing time of day −0.41 / −0.16; equal against the following 2 h; nothing passes split-half Bonferroni | UNKNOWN periodic summary (inverse-activity candidate); not an HR measure on current evidence |
| 121 | 6 | 4 | with alarm set / double tap / haptics terminated | UNKNOWN (alarm/haptics-related) |
| 123 | ~2.1k | 8 | at connects/disconnects | HYPOTHESIS connection state |
| 1 | 1 | 12 | isolated | UNKNOWN |

Wrist on/off: events 10/9 (C02a, CONFIRMED once). The live stream also carried event 29 (soc field 994 = 99.4 %, matching 2A19 = 99).

## 4 · Stored history

| Record | Volume | Decoded | Structure found offline | Label |
|---|---|---|---|---|
| 47 v0x12 "R18" (frame 124, payload 112) | continuous 1 Hz | HR @14, R-R @15/16, gravity floats @37/41/45 | **Skin temperature u16 @65 ÷ 100 °C** (ryanbr R18 frame 73; Asherlc payload 65): 544/544 local raw frames (Oct 13–22 manual pulls) in 5–45 °C, median ≈ 35 °C, matching the firmware console's `skin_temp`. Aux thermal i16 @61/@63 ÷ 10 °C also plausible. Further R18 fields (payload = ryanbr frame − 8), checked on the same 544 seconds: step counter u16 @49 increments only within 5 s of activity code @55 = 1 (walk; 7/7); dynamic acceleration f32 @33 median 0.139 g on walk seconds vs 0.010 g still. Band-state bits @73 and optical bytes @98–101 present but too little data to interpret | HR/R-R/gravity CONFIRMED; skin-temperature word **SUPPORTED + locally consistent** (no reference thermometer); app decodes/stores temperature with explicit units and computes a causal nightly change; step/activity change points stored in schema v19; step counter **SUPPORTED** (W01–W03: tracks walking and running to the second; hand counts unreliable, so no error figure); activity code **2 = running CONFIRMED** on two runs, 1 = walk / 0 = still SUPPORTED |
| 47 v0x1a "R26" (frame 88, **payload 76**) | 41,237 frames archived (40,754 unique seconds; duplicates = re-sent un-acked chunks) | time @7 only | Bursts of 40 consecutive seconds, median ~19–20 min apart (all 15 days). Constant: @0 type, @1 0x1a, @2 0x80, @6, @10, @75. @3 u32 counter +1 per record. @19–66: 24 × i16 LE per record with lag-1 correlation 0.79 decaying to ~0 by lag 6 and 0.48 across record boundaries → a sampled waveform at ~24 samples/s. @70 a slowly varying byte in a narrow range. @11–18, @67–74 mostly constant within a burst. ryanbr's R26 layout (payload = frame − 8): @11 u16 time word, @13 u16 burst counter, @15 u32 absolute first optical code, @19+2i 24 × i16 **deltas** (25-sample window), @67 f32 motion summary, @71 u16 status, @73 on-wrist byte, @74 acceptance byte. Checked locally: burst counter constant inside every run and +1 between runs (1,031/1,033); delta-reconstructed last sample meets the next record's first sample ~8× closer than raw first-to-first (median 624 vs 5,122) | Layout **SUPPORTED + locally consistent**. 2026-11-17: 25 samples/s (base + 24 deltas per record), one stream. **Corrected later the same day** ([EVIDENCE_MATRIX.md](EVIDENCE_MATRIX.md) §3): the first-pass "161/279 vs ≈ 6 % chance" used a uniform chance rate; with shuffled/shifted/HR-stratified controls the record-mean method shows no HR tracking (peaks sit at 40–70 bpm). Using the stored deltas, 67 % match vs 63 % HR-decile control overall and 28 % vs 9 % in bursts with HR ≥ 80: pulse content present but weak. Byte 14 takes 0–3 (five transitions in 16 days), not 0/1. No second channel → **no SpO₂**; wavelength UNKNOWN |
| 52 IMU | none archived in this window | — | — | UNKNOWN |

R18 leads and conflicts (ryanbr `PROTOCOL_SENSORS.md` gives **frame** offsets; NOOP uses payload offsets = frame − 8; re-read 2026-11-17, nothing verified locally yet):

| Payload (frame) | ryanbr says | Conflict / NOOP status |
|---|---|---|
| 16 + 2i (24) R-R words | **1/1024-s ticks**, rounded ms = (t·1000 + 512) // 1024; evidence pointer only "R-R conversion on 50.41.1.0" | **ms CONFIRMED on fw 50.43.1.0** (2026-11-17, `rr_unit_audit.py` on a DB copy): 1,924 complete-beat 5-min windows, sum(words)/(1000·W) median 0.9998 (p10–p90 0.997–1.002; ticks would give ~1.024); strap HR − RR-implied HR median +0.02 bpm as ms vs −1.36 bpm as ticks; 120-s windows agree (6,670). The external ticks claim does not apply to this firmware's history (live packet 40 not tested separately) |
| 28 (36) | HR/R-R quality flags; bits 4–5 step-source selection (bit 5 lingers ≤ 9 updates) | Undecoded |
| 29 (37) | alternate HR (bpm), validity unresolved | dofek: "smoothed HR". Undecoded |
| 33 (41) f32 | dynamic acceleration (g) | dofek: payload 33–48 = **unit quaternion**. NOOP reads 37/41/45 as gravity (norm 0.7–1.3 gate) — consistent with either reading of 37–48; the 33 word's walk/still split (§4) favours acceleration. Open |
| 49 (57) u16 | **selected** step counter: hardware pedometer normally, software count under override | NOOP stores it as the counter. A source switch can look like a jump — see 53/56 |
| 53 (61) u16 | hardware counter retained while override is active (else 0) | Undecoded |
| 56 (64) | 0x10 while software override is active | Undecoded; NOOP should not count a delta across a change of this byte (not implemented) |
| 73 (81) bits 4–5 | band state 0 wake / 1 still / 2 sleep / 3 up ("not sleep stages") | Undecoded; candidate motion/rest input, needs timed checks |
| 74 (82) | "sleep-adjacent raw byte"; 0x80/0xA0 candidate sentinels | ryanbr's ATTRIBUTION keeps an older decompile-sourced `spo2_candidate_82` as a **candidate only** (evidence split). **Not SpO₂** here; don't scan bytes for 95–100 |

Full R18 frames are now kept on request (`ResearchCapture`, Settings ▸ Research capture, ≤ 7 days, flushed before ack), so these can be tested on raw bytes from live pulls.

The periodic 40-s windows are optical sample windows (R26). What they are used for (SpO₂ spot checks or other) is
not established; no published source documents the ~20-min cadence.

## 5 · Findings that suggest improvements (ranked)

Finding 1 describes the pre-fix behavior: PR #29 now verifies the stored slot before rewriting it. Fake-link tests pass; the reduction in real strap writes remains unmeasured.

| # | Finding | Evidence | Where the fix belongs | Risk / metric |
|---|---|---|---|---|
| 1 | **The alarm slot is rewritten ~every 15 min.** `AppModel` calls `AlarmController.syncDeviceAlarm()` on every new clock measurement (each connect and each ~15-min history pull, which starts with GET_CLOCK); it sends SET + GET even when `armedKey` already equals the next occurrence and was read back. | ~610 event-56 rows, median 15 min apart | NOOP only: skip SET when the confirmed key matches, verify with GET (read-only) instead, re-SET only on mismatch/empty | Fewer persistent strap writes (flash/battery effect UNKNOWN). Metric: event-56 count/day → ~1–2 |
| 2 | Probe `--commands 67` read alarm id 0, which is invalid on this firmware | H02, probe source | Probe code — **fixed 2026-11-16** (reads id 1) | None (read-only either way) |
| 3 | ~~v0x1a burst content undecoded~~ | §4 | **Done 2026-11-17 (offline)**: 25 Hz single-channel PPG bursts (HR-matched). Possible NOOP use: an independent pulse check every ~20 min; not SpO₂ | Not built; needs a use worth the decoding cost |
| 4 | Event 14 frequency vs "double tap" label | §3 | Docs + any future gesture feature | Don't build on it until meaning is settled |
| 5 | Periodic 29/110/120 reports | §3 | 29 soc done (app); **110 = charger status** (hypothesis, corroborates 117); 120 tracks prior-2-h HR, meaning open | — |
| 6 | ~~Skin temperature in every v0x12 record ignored~~ | §4 | **Implemented** in PR #33: decoded + stored (schema v18), nightly change `skin-temp-night-v2` (off-wrist time excluded) | Not yet seen in a live pull |
| 7 | **Charger state and battery are in events NOOP doesn't use**: 117 (charger state incl. *full*), 29 (soc every 10 min), 109 (charge-current-like taper) | §3 | NOOP: event 117 = 4 as a "fully charged" signal; 29 as a passive soc source between polls (could replace some 15-min pack/battery polls) | Offline decode only; metric: fewer battery commands/day, earlier full-charge notice |
| 9 | **Wrist on/off events (9/10) are ignored by NOOP** | §3 | NOOP: route 9/10 to an off-wrist interval stream; use it to keep off-wrist time out of skin temperature, coverage captions and sleep (AGENTS says NOOP never claims the strap was off — this would be the first evidence for it) | Offline decode; needs more than one timed off/on before relying on it |
| 10 | **Decoded R18 records lose their undecoded fields at ack** (only selected fields are stored; only unknown record versions were archived) | `BLEManager.captureWhoop5HistoryFrame` | **Implemented 2026-11-17**: opt-in `ResearchCapture` keeps complete decoded-record frames with firmware/hardware, strap time and capture id in `OpenWhoop/research-history`, flushed before ack (failure → no ack); ≤ 7 days / 400 MB | Archive + bounds unit-tested; the ack path is not (CoreBluetooth); not yet run on a live pull |
| 11 | ~~R-R unit may be 1/1024 s~~ | R18 table | **Closed 2026-11-17: ms** on stored history (audit above); no decoder change | Live packet 40 unit not separately audited |
| 8 | Steps and activity are in every v0x12 record | §4 | NOOP decoder (R18 @49 step counter, @55 activity code) | W01–W03 done. S01: no reset at midnight; one reset at waking (08:15, with an alarm dismissal). Still needed: a no-alarm morning to tell wake from alarm; an accuracy figure needs a reliable count (e.g. a phone pedometer or tally counter) |

## 6 · Firmware acquisition (status after desk research, 2026-11-16)

| Question | Status |
|---|---|
| Readback/dump command in any reviewed source | **None found** (registry, Goose table + Swift client, Asherlc, ryanbr, probe, app). ryanbr documents 143 chunk read-back only inside an update load, which is prohibited and is not a dump of the installed image. |
| Official update artifact | **No public source found.** WHOOP updates are pushed through its app (community guide). ryanbr documents an image container (512-byte header with CRC32s, type 5 = gzip payload) and a WHOOP 4 outer package (Maxim ZBIN + Nordic DFU zip); the 5.0/MG package, download source and signing are undocumented. Do not trigger an update to obtain one. |
| Hardware readout | MCU: **Ambiq Cortex-M4 with BLE** per the TechInsights WG50 teardown summary (paywalled full report; part number not seen). Consistent with the firmware console's `DM_PHY_UPDATE_IND` line (ARM Cordio BLE host naming, which Ambiq's SDK ships) — supporting, not proof. Other parts per ryanbr: MAX86176 optical AFE, ICM-45686 IMU, DRV2625 haptics, LC709205F fuel gauge, AS6221 skin temperature. Debug-port exposure, readout protection and secure boot: **unknown**. Any attempt is spare-unit-only and out of this issue's scope. |
| Custom firmware | **No-go for now.** ryanbr lists certificate/authorisation commands 155–159 and "no validated or authorized flashing path"; signing, boot verification, rollback and recovery are unknown; no recovery route exists even on a spare. Revisit only with a spare unit and evidence on boot security. |
| Decision | **Firmware acquisition: no legitimate path found yet** (no read path, no public package) — not proof that none exists; the staged ladder with closing conditions is in [EVIDENCE_MATRIX.md](EVIDENCE_MATRIX.md) §5. **Improvements belong in NOOP** (decoding, fewer writes/polls), not firmware. |

## 7 · Experiments (completed evidence and remaining approval-gated work)

| ID | What | Touches strap | Why |
|---|---|---|---|
| C01 | ~~Read DIS once~~ | — | **Closed** from the app's own cached read (2026-11-16) |
| C02 | Passive capture (owner-approved 2026-11-16) | Notifications + standard reads only | **(a) done**: wrist off/on = events 10/9, live on fd4b0004; probe wrote 0 frames; fresh probe-only connect (NOOP was not connected) produced **no** fd4b0007 data. **(b) charging: deferred** (no pack at hand) |
| C03 | ~~Offline fd4b0007 review~~ | No | **Closed, no data**: committed captures hold only fd4b0007 descriptors and one redacted empty fragment; no local file kept its payload. Needs C02. Firmware console text (type 50, 124 local frames) summarised instead: hello/fuel-gauge, history trim/PullStats, bond, PHY update, AFE reconfiguration, wear-detect state lines; no build id or crash record seen |
| C04 | ~~Desk research: arguments~~ | No | **Done** (§2) |
| C05 | ~~Desk research: firmware/MCU~~ | No | **Done** (§6): no-go |
| C06 | 151 GET_BATTERY_PACK_INFO with payload `[01]`, once, pack off and on | One read-only command (Goose gate R), new payload form | **(a) pack off, run 2026-11-17: SUCCESS** (result 1), body `01` + 30 zero bytes: the FAILURE with `[]` was the missing revision byte. **(b) pack on: deferred** (no pack at hand) |
| C08 | 121 / 128 named reads (**run 2026-11-18, owner-approved**) | 4 read-only commands, once each | **All four SUCCESS** with the predicted padded shape and exact key echo; values `0`, `0`, `8.3`, `2`. Layout confirmed on fw 50.43.1.0; no console lines or events; NOOP kept its link. Closed. Capture `captures/C08-config-reads.jsonl` |
| C07 | 40 / 42 / 44 with empty payload, once each | Three read-only commands (Goose gate R), never sent before | **Run 2026-11-17: all three UNSUPPORTED** (result 3, 3-byte zero body) on fw 50.43.1.0; no console lines, link unaffected. Closed: AFE settings are not readable this way |

### Procedures for the approval-gated tests (C06a/C07 completed; C06b pending)

Common rules: NOOP running and connected, not mid-pull (no `History:` lines), no alarm within 30 min; the probe attaches to NOOP's
link (`Tools/ble_probe`, rebuilt with the change below); one attempt per command, ≥ 0.3 s apart, 7 s timeout, 25 s after
PENDING; seq 200–255; responses for 141/145/76 stay redacted; stop at the first unexpected result (no retries); captures
redacted before commit.

| ID | Probe change needed | Exact request | Expected | Stop / restore |
|---|---|---|---|---|
| C06 | Allow payload `[01]` for 151 behind a new `--pack-rev1` flag (read-only allowlist entry already exists) | `151 [01]` with the pack **off**, then again with the pack **on** and charging | SUCCESS with a body (then decode offline), or the same FAILURE (then the revision byte is not the cause) | Read-only; nothing to restore. If anything other than a 36 response arrives, stop |
| C07 | Add 40, 42, 44 to `READ_ONLY_ALLOWLIST` with empty payloads | `40 []`, `42 []`, `44 []` once each | SUCCESS + body, or UNSUPPORTED (3-byte body) | Read-only per Goose; their SET twins (39/41/43) stay prohibited and are not added. Stop on any AFE console line other than the usual |
| C08 | **Prepared and run 2026-11-18 (#40, owner-approved):** `ble_probe --c08 --c08-approved` sends only `Whoop5ConfigRead.c08Keys` (121/128 stay out of `READ_ONLY_ALLOWLIST`; `--commands 121/128` refused; `--c08` refuses every other command option); payloads from the unit-tested `Whoop5ConfigRead.requestPayload` | `121 01 "sigproc_wear_detect"`, `121 01 "cont_collection_mode"`, `121 01 "max_collection_backlog"`, `128 01 "disable_pip_r26_packets"` — each name ASCII, NUL-padded to 32 bytes (payload 33 bytes; full frame 48 bytes, no alignment padding). First request data hex: `01 73696770726f635f776561725f646574656374` + 13 × `00` | Classified by `Whoop5ConfigRead.classify`: 65-byte semantic body arrives as **67** decoded bytes (2 zero alignment bytes; only those are removed, value field untouched). Outcomes: `value` (result 1, key echoed, decimal text `0`/`1`/`2`/integer/one fractional digit), `zeroFallback` (result 1, all-zero value = storage-slot fallback, **not** a reading of 0), `keyUnknownOrUnreadable` (result 0, key echoed, zero value), `revisionRejected` (result 0, `01` + 64 zeros), `unsupported` (result 3) — all valid outcomes | Read-only per the reference; nothing to restore. Enforced in the probe: stop at the first `unexpected` (body not 65/67 bytes, non-zero padding, revision ≠ 1, different key echo, unterminated/non-decimal value, bytes after the NUL, FAILURE with a value, other result codes) or timeout; UNSUPPORTED skips the rest of that command; no retries, no other names. Raw bodies logged to the private capture |
| C02 | `ble_probe --passive` (added 2026-11-16; refuses every command option, `write` guarded; fd4b0007 fragments logged raw, private) | Capture 10 min each: (a) wear → remove strap → replace; (b) pack attach → charge → remove; wearer notes times by hand | Live events on fd4b0004 for 14/43/117/123; fd4b0007 fragments at connect | Passive; no restoration |

## 8 · Sources (desk research, 2026-11-16)

Treated as leads until checked against this strap; nothing below was sent to the strap.

- [b-nnett/goose](https://github.com/b-nnett/goose): `Rust/core/src/commands.rs` (risk gates, no payloads), `GooseSwift/GooseBLEClient.swift` (`debugResearchCommandDefinitions`: payload hints for 40/42/44/84/121/128/132/151).
- [Asherlc/dofek WHOOP BLE protocol](https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md): config key names, R18 thermal word.
- [ryanbr/noop PROTOCOL_SENSORS.md](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_SENSORS.md) and sibling `PROTOCOL_UPDATES.md` / `PROTOCOL_WHOOP5.md`: R18/R20/R21/R26 layouts, image container, parts list.
- ryanbr/noop (re-read 2026-11-17, fw 50.42.1.0 baseline): [`PROTOCOL_CONFIGURATION.md`](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_CONFIGURATION.md) (121/128 named reads, key/flag inventories), `PROTOCOL_COMMANDS.md`, `PROTOCOL_UPDATES.md` (5.0 container: 512-byte header, CRC32s, type 5 gzip; 83/142–144 transfer; "no validated or authorized flashing path"; signature/rollback unspecified), `WHOOP5_DEEP_DATA.md` and root `ATTRIBUTION.md` (older decompile-sourced `spo2_candidate_82` kept as a candidate only).
- [TechInsights WHOOP 5.0 (WG50) teardown summary](https://www.techinsights.com/ko/node/60374) and [GlobalSpec summary](https://electronics360.globalspec.com/article/23159/techinsights-teardown-whoop-5-0): Ambiq Cortex-M4 MCU.
- [WHOOP community: firmware updates](https://www.community.whoop.com/t/how-do-i-update-the-firmware-on-my-whoop-strap/244): updates are app-initiated.
