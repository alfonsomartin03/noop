# Capability matrix (issue #25, phase 1: offline inventory)

Reconciled 2026-11-16 at `origin/main` `ff1dcb7` against current source, tests, the committed captures, the
app's undecoded-history archive and the app database (both analysed as **copies**). **No strap interaction**:
nothing was sent, read or subscribed for this document. Labels as in [README.md](README.md). Hardware claims are
scoped to the unit last read in E01/E02: WHOOP 5.0, fw `50.43.1.0`, hw `WG50_r52`. The firmware installed today
has **not been re-read** (needs a Device Information read: a strap contact, so it waits for approval).

Private inputs (stay local, never committed): a SQLite-backup copy of the app DB (events 2026-11-02 → 11-16)
and a copy of `undecoded-history/*.jsonl` (15 day files, 41,237 frames). Only aggregate structure is recorded
here: no biometric values, identifiers, bodies of identity responses or timestamps of personal activity.

## 1 · Characteristics

| Characteristic | Current evidence | Label | Open question | Next step (tier) |
|---|---|---|---|---|
| 180A DIS 2A24/2A26/2A27 | model `5.0`, fw `50.43.1.0`, hw `WG50_r52` (E01/E02); app caches `noop.deviceInfo` | CONFIRMED (2026-11-02) | Current firmware after any OTA since | Read 180A once (read-only GATT read; needs approval as strap contact) |
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
| 67 (probe default) | GET_ALARM_TIME | auto in probe | `READ_ONLY_PAYLOADS` reads **id 0** | id 1 | id 0 is invalid (H02) | Probe `--commands 67` reads the wrong slot; use `--alarm-script get1`, or change the default (code change, no strap needed) |
| 84 | GET_BODY_LOCATION_AND_STATUS | auto | yes | — | FAILURE `01 00…` (E02) | Arguments needed? Desk research (Goose/Asherlc) before any resend |
| 141 | GET_ADVERTISING_NAME | auto | yes | — | never sent; response redacted by the probe | Low value (identifier); keep unsent |
| 145 | GET_HELLO | auto | static hello | yes | CONFIRMED; body redacted | Not required for other commands (E06) |
| 151 | GET_BATTERY_PACK_INFO | auto | yes | yes (connect + poll) | E02 shape = `unavailable`, **not** "no pack"; SUCCESS = `answeredUndecoded` (`Whoop5Charging.packInfo`) | Reply while a pack is attached: never captured |
| 35, 76 | Harvard hello / name | registry "auto" | **no** | — | none | Identity data; no reason to send |
| 40, 42, 44 | GET LED drive / TIA gain / bias | registry "auto" | **no** | — | none | Exact arguments unknown; desk research only. Registry R label ≠ authorisation |
| 121, 128 | GET device config / feature flag | registry "auto" | **no** | — | none | Need a key argument; **no key sweep**. Desk research for documented keys |
| 132 | GET_RESEARCH_PACKET | registry "auto" | **no** | — | none | Arguments/effects unknown; desk research |
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
| 47 v0x12 (frame 124, payload 112) | continuous 1 Hz | HR @14, R-R @15/16, gravity floats @37/41/45 | — | CONFIRMED |
| 47 v0x1a (frame 88, **payload 76**) | 41,237 frames archived (40,754 unique seconds; duplicates = re-sent un-acked chunks) | time @7 only | Bursts of 40 consecutive seconds, median ~19–20 min apart (all 15 days). Constant: @0 type, @1 0x1a, @2 0x80, @6, @10, @75. @3 u32 counter +1 per record. @19–66: 24 × i16 LE per record with lag-1 correlation 0.79 decaying to ~0 by lag 6 and 0.48 across record boundaries → a sampled waveform at ~24 samples/s. @70 a slowly varying byte in a narrow range. @11–18, @67–74 mostly constant within a burst. | Burst cadence and waveform-like layout CONFIRMED as structure; **meaning UNKNOWN** (PPG/optical vs motion vs other is not established; no guessed field names) |
| 52 IMU | none archived in this window | — | — | UNKNOWN |

The periodic 40-s windows match a duty-cycled measurement; tying them to SpO₂, skin temperature or optical
sampling needs a controlled scenario (e.g. a known cool/warm change, a known still period) and is HYPOTHESIS
until then.

## 5 · Findings that suggest improvements (ranked)

| # | Finding | Evidence | Where the fix belongs | Risk / metric |
|---|---|---|---|---|
| 1 | **The alarm slot is rewritten ~every 15 min.** `AppModel` calls `AlarmController.syncDeviceAlarm()` on every new clock measurement (each connect and each ~15-min history pull, which starts with GET_CLOCK); it sends SET + GET even when `armedKey` already equals the next occurrence and was read back. | ~610 event-56 rows, median 15 min apart | NOOP only: skip SET when the confirmed key matches, verify with GET (read-only) instead, re-SET only on mismatch/empty | Fewer persistent strap writes (flash/battery effect UNKNOWN). Metric: event-56 count/day → ~1–2 |
| 2 | Probe `--commands 67` reads alarm id 0, which is invalid on this firmware | H02, probe source | Probe code | None (read-only either way) |
| 3 | v0x1a burst content undecoded | §4 | Offline decoding, then a controlled passive scenario | Decode only with reproducible evidence |
| 4 | Event 14 frequency vs "double tap" label | §3 | Docs + any future gesture feature | Don't build on it until meaning is settled |
| 5 | Periodic 29/110/120 reports undecoded | §3 | Offline correlation with battery/charging/wear | — |

## 6 · Firmware acquisition (status after phase 1)

| Question | Status |
|---|---|
| Readback/dump command in any reviewed source | **None found** (registry, Goose table, probe, app). Firmware commands 36–38/83/142–144 and DFU 45 load images; they are not a read path and stay prohibited. |
| Official update artifact | **Not yet researched** (next phase: desk research only; do not trigger an update). |
| Hardware readout | **Not yet researched** (desk research on a spare unit only; no teardown/debug attach in this issue). |
| Custom firmware | **No basis yet**: image format, signing/secure boot, rollback and recovery are all UNKNOWN. |

## 7 · Remaining experiments (none run; each needs explicit owner approval)

| ID | What | Touches strap | Why |
|---|---|---|---|
| C01 | Read DIS 2A24/2A26/2A27 once | GATT read only | Current firmware identity |
| C02 | Passive subscription capture around connect, charge on/off, wear off/on (bounded, no commands beyond the app's own) | Notifications only | fd4b0004 coverage, event 14/109/117/43 meaning, fd4b0007 framing |
| C03 | Offline: review existing fd4b0007 fragments in committed captures | No | Diagnostic framing |
| C04 | Desk research: arguments for 40/42/44/84/121/128/132 in Goose/Asherlc | No | Prerequisite for any new read; no key sweeps |
| C05 | Desk research: official update manifests, MCU/storage identity | No | Firmware go/no-go |
