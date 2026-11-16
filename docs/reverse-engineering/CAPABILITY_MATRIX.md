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
| 151 | GET_BATTERY_PACK_INFO | auto | yes | yes (connect + poll) | E02 shape = `unavailable`, **not** "no pack"; SUCCESS = `answeredUndecoded` (`Whoop5Charging.packInfo`) | **Lead (C06):** Goose's APK-derived default payload is `01` ("revision 01"); NOOP and the probe send `[]`. The FAILURE may be a missing revision byte. Test `[01]` once (read-only per Goose) only with approval |
| 35, 76 | Harvard hello / name | registry "auto" | **no** | — | none | Identity data; no reason to send |
| 40, 42, 44 | GET LED drive / TIA gain / bias | registry "auto" | **no** | — | none | Goose debug list: no payload, "read". Response layout undocumented anywhere. Their SET pairs (39/41/43) stay prohibited. Candidate C07 (approval) |
| 121, 128 | GET device config / feature flag | registry "auto" | **no** | — | none | Goose: "keyed read", payload `01` + 32-byte key. No key values are published; Asherlc lists 17 config key **names** (e.g. `enable_r22_v4_packets`), not their 32-byte form. Without a documented key: **not testable** (no sweep, no guessed hashing) |
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
| 9 / 10 | 2 each | 0 | always together, ~26 s apart, beside 120 and 123 | UNKNOWN |
| 11 / 12 connection up/down | ~680 each | 0 | | CONFIRMED |
| 14 (labelled DOUBLE_TAP) | ~780 | 0 | almost only during waking hours, often clustered (gaps ≤ 60 s); also after alarm dismissal (H04/H06b) | Dismissal use CONFIRMED; that every 14 is a deliberate double tap is **HYPOTHESIS** (daytime clustering suggests a motion/gesture detector firing in activity) |
| 21 / 22 pack connected/removed | few | — | | CONFIRMED |
| 25 HR profile disabled | ~430 | — | near connects (NOOP keeps broadcast off) | CONFIRMED |
| 29 STRAP_CONDITION_REPORT | ~2k | 12 | every 10 min, same second as 110; bytes 0, 6 vary widely, 1/4 moderately | name SUPPORTED, fields UNKNOWN |
| 33 / 34 realtime on/off | ~400 / ~30 | 0 | | CONFIRMED |
| 43 | 18 | 0 | always with a connection down/up and 123 | UNKNOWN (connection-related) |
| 56 STRAP_DRIVEN_ALARM_SET | ~610 | 24 | median gap 15 min; ~50/day | CONFIRMED meaning; cadence = §5 finding |
| 57 / 58 / 60 / 100 | few | | alarm execution / haptics | CONFIRMED |
| 63 EXTENDED_BATTERY_INFORMATION | ~1k | | same second as 3 | name SUPPORTED, body UNKNOWN |
| 109 | 66 | 28 | 10-min spacing during charging sessions; only bytes 23–24 vary | UNKNOWN (charging-related HYPOTHESIS) |
| 110 | ~2k | 8 | every 10 min with 29; nearly constant body | UNKNOWN |
| 117 | 88 | 4 | seconds apart, around charging on/off and battery events; byte 1 takes 4 values | UNKNOWN (charging-state HYPOTHESIS) |
| 120 | ~180 | 32 | ~every 2 h; every body distinct | UNKNOWN (periodic report) |
| 121 | 6 | 4 | with alarm set / double tap / haptics terminated | UNKNOWN (alarm/haptics-related) |
| 123 | ~2.1k | 8 | at connects/disconnects | HYPOTHESIS connection state |
| 1 | 1 | 12 | isolated | UNKNOWN |

Not seen: wrist on/off events (UNKNOWN on 5.0).

## 4 · Stored history

| Record | Volume | Decoded | Structure found offline | Label |
|---|---|---|---|---|
| 47 v0x12 "R18" (frame 124, payload 112) | continuous 1 Hz | HR @14, R-R @15/16, gravity floats @37/41/45 | **Skin temperature u16 @65 ÷ 100 °C** (ryanbr R18 frame 73; Asherlc payload 65): 544/544 local raw frames (Oct 13–22 manual pulls) in 5–45 °C, median ≈ 35 °C, matching the firmware console's `skin_temp`. Aux thermal i16 @61/@63 ÷ 10 °C also plausible. Other R18 fields per ryanbr (step counter, activity, wear/motion bitfield, optical amplitude) not yet checked | HR/R-R/gravity CONFIRMED; skin-temperature word **SUPPORTED + locally consistent** (no reference thermometer); app does not decode it |
| 47 v0x1a "R26" (frame 88, **payload 76**) | 41,237 frames archived (40,754 unique seconds; duplicates = re-sent un-acked chunks) | time @7 only | Bursts of 40 consecutive seconds, median ~19–20 min apart (all 15 days). Constant: @0 type, @1 0x1a, @2 0x80, @6, @10, @75. @3 u32 counter +1 per record. @19–66: 24 × i16 LE per record with lag-1 correlation 0.79 decaying to ~0 by lag 6 and 0.48 across record boundaries → a sampled waveform at ~24 samples/s. @70 a slowly varying byte in a narrow range. @11–18, @67–74 mostly constant within a burst. ryanbr's R26 layout (payload = frame − 8): @11 u16 time word, @13 u16 burst counter, @15 u32 absolute first optical code, @19+2i 24 × i16 **deltas** (25-sample window), @67 f32 motion summary, @71 u16 status, @73 on-wrist byte, @74 acceptance byte. Checked locally: burst counter constant inside every run and +1 between runs (1,031/1,033); delta-reconstructed last sample meets the next record's first sample ~8× closer than raw first-to-first (median 624 vs 5,122) | Layout **SUPPORTED + locally consistent**; an optical sample window. Wavelength/channel and SpO₂ meaning **not established** (ryanbr: do not derive SpO₂) |
| 52 IMU | none archived in this window | — | — | UNKNOWN |

The periodic 40-s windows are optical sample windows (R26). What they are used for (SpO₂ spot checks or other) is
not established; no published source documents the ~20-min cadence.

## 5 · Findings that suggest improvements (ranked)

Finding 1 describes the pre-fix behavior: PR #29 now verifies the stored slot before rewriting it. Fake-link tests pass; the reduction in real strap writes remains unmeasured.

| # | Finding | Evidence | Where the fix belongs | Risk / metric |
|---|---|---|---|---|
| 1 | **The alarm slot is rewritten ~every 15 min.** `AppModel` calls `AlarmController.syncDeviceAlarm()` on every new clock measurement (each connect and each ~15-min history pull, which starts with GET_CLOCK); it sends SET + GET even when `armedKey` already equals the next occurrence and was read back. | ~610 event-56 rows, median 15 min apart | NOOP only: skip SET when the confirmed key matches, verify with GET (read-only) instead, re-SET only on mismatch/empty | Fewer persistent strap writes (flash/battery effect UNKNOWN). Metric: event-56 count/day → ~1–2 |
| 2 | Probe `--commands 67` read alarm id 0, which is invalid on this firmware | H02, probe source | Probe code — **fixed 2026-11-16** (reads id 1) | None (read-only either way) |
| 3 | v0x1a burst content undecoded | §4 | Offline decoding, then a controlled passive scenario | Decode only with reproducible evidence |
| 4 | Event 14 frequency vs "double tap" label | §3 | Docs + any future gesture feature | Don't build on it until meaning is settled |
| 5 | Periodic 29/110/120 reports undecoded | §3 | Offline correlation with battery/charging/wear | — |
| 6 | **Skin temperature is in every v0x12 record and NOOP ignores it** (`skinTempSample` is empty; Health/Trends skin-temperature change has no 5.0 source) | §4 | NOOP decoder (`Streams.swift` 5.0 historical) → `skinTempSample`; needs fixture tests and a provenance/version label | Offline only, no strap commands. Metric: nightly skin-temperature coverage on 5.0 |

## 6 · Firmware acquisition (status after desk research, 2026-11-16)

| Question | Status |
|---|---|
| Readback/dump command in any reviewed source | **None found** (registry, Goose table + Swift client, Asherlc, ryanbr, probe, app). ryanbr documents 143 chunk read-back only inside an update load, which is prohibited and is not a dump of the installed image. |
| Official update artifact | **No public source found.** WHOOP updates are pushed through its app (community guide). ryanbr documents an image container (512-byte header with CRC32s, type 5 = gzip payload) and a WHOOP 4 outer package (Maxim ZBIN + Nordic DFU zip); the 5.0/MG package, download source and signing are undocumented. Do not trigger an update to obtain one. |
| Hardware readout | MCU: **Ambiq Cortex-M4 with BLE** per the TechInsights WG50 teardown summary (paywalled full report; part number not seen). Other parts per ryanbr: MAX86176 optical AFE, ICM-45686 IMU, DRV2625 haptics, LC709205F fuel gauge, AS6221 skin temperature. Debug-port exposure, readout protection and secure boot: **unknown**. Any attempt is spare-unit-only and out of this issue's scope. |
| Custom firmware | **No-go for now.** ryanbr lists certificate/authorisation commands 155–159 and "no validated or authorized flashing path"; signing, boot verification, rollback and recovery are unknown; no recovery route exists even on a spare. Revisit only with a spare unit and evidence on boot security. |
| Decision | **Firmware acquisition: no-go** (no read path, no public package). **Improvements belong in NOOP** (decoding, fewer writes/polls), not firmware. |

## 7 · Remaining experiments (none run; each needs explicit owner approval)

| ID | What | Touches strap | Why |
|---|---|---|---|
| C01 | ~~Read DIS once~~ | — | **Closed** from the app's own cached read (2026-11-16) |
| C02 | Passive subscription capture around connect, charge on/off, wear off/on (bounded, no commands beyond the app's own) | Notifications only | fd4b0004 coverage, event 14/109/117/43 meaning, fd4b0007 framing |
| C03 | Offline: review existing fd4b0007 fragments in committed captures | No | Diagnostic framing |
| C04 | ~~Desk research: arguments~~ | No | **Done** (§2) |
| C05 | ~~Desk research: firmware/MCU~~ | No | **Done** (§6): no-go |
| C06 | 151 GET_BATTERY_PACK_INFO with payload `[01]`, once, pack off and on | One read-only command (Goose gate R), new payload form | Whether the FAILURE was a missing revision byte; pack-attached reply |
| C07 | 40 / 42 / 44 with empty payload, once each | Three read-only commands (Goose gate R), never sent before | Optical AFE configuration; response layouts undocumented |

## 8 · Sources (desk research, 2026-11-16)

Treated as leads until checked against this strap; nothing below was sent to the strap.

- [b-nnett/goose](https://github.com/b-nnett/goose): `Rust/core/src/commands.rs` (risk gates, no payloads), `GooseSwift/GooseBLEClient.swift` (`debugResearchCommandDefinitions`: payload hints for 40/42/44/84/121/128/132/151).
- [Asherlc/dofek WHOOP BLE protocol](https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md): config key names, R18 thermal word.
- [ryanbr/noop PROTOCOL_SENSORS.md](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_SENSORS.md) and sibling `PROTOCOL_UPDATES.md` / `PROTOCOL_WHOOP5.md`: R18/R20/R21/R26 layouts, image container, parts list.
- [TechInsights WHOOP 5.0 (WG50) teardown summary](https://www.techinsights.com/ko/node/60374) and [GlobalSpec summary](https://electronics360.globalspec.com/article/23159/techinsights-teardown-whoop-5-0): Ambiq Cortex-M4 MCU.
- [WHOOP community: firmware updates](https://www.community.whoop.com/t/how-do-i-update-the-firmware-on-my-whoop-strap/244): updates are app-initiated.
