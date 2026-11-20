# Evidence matrix, next steps and closure (issue #25, 2026-11-17 → closed 2026-11-20)

Scope: WHOOP 5.0, fw `50.43.1.0`, hw `WG50_r52` (one unit). **No strap commands, writes or hardware contact were made for
this document.** Inputs, all copies: a SQLite backup of NOOP's database (data to 2026-11-17 16:15 local), the app's
`undecoded-history` archive (2026-11-02 → 11-17, 43,906 v0x1a records), the six October manual-pull files (544 v0x12
records), and the committed redacted captures. Only aggregates are recorded. Branch state checked against `origin`
(GitHub CLI not authenticated, so PR state is from git only): `main` = `origin/main` = `c84466d`; `issue/25-c06-c07`
(+1 commit), `docs/step-walk-1` (+3, W01–W03 docs) and `feature/strain-steps` (+1, experimental Steps tile) are **not
merged**. Nothing here merges them.

Evidence levels used below: **B** observed bytes/timing · **S** reproducible statistical relationship (with the control
named) · **I** semantic interpretation · **P** product-ready · **U** unknown. Confidence words follow
[README.md](README.md) labels.

## 1 · What the gaps could mean (assessment)

1. **Strap time is not Mac time, and NOOP does not correct it.** Live events carry the strap's timestamp and NOOP stores
   the receipt time next to it. The daily minimum of (receipt − strap time) rises steadily from 22.2 s (Nov 5) to 38.9 s
   (Nov 17): **+1.41 s/day ≈ 16 ppm**, strap behind (`strap_clock_offset.py`). GET_CLOCK replies in the Nov 2 captures
   (17.9–18.9 s) and the live events in the same captures (18.2–18.8 s) agree, so live-event latency is under ~1 s and the
   offset is the clock, not delivery delay. Cause: `ClockPolicy` asks for SET_CLOCK at ≥ 2 s drift, but SET_CLOCK is not in
   `BLEManager.whoop5Allowed`, so on a 5.0 it is never sent. Every stored 5.0 timestamp (HR, steps, temperature, events,
   sleep edges) is therefore in strap time, ~40 s late today and growing. Consequences: W01–W03 edge offsets (~30 s) are
   explained by the strap clock, **not** a fast wearer clock as W03 suggested; C02a's "14:58:12" (Mac receipt) and the
   DB's 14:57:34 (strap) are the same event. Alarms are unaffected (they map strap time explicitly).
2. **Step reset timing is not observable in existing history.** NOOP has stored step change points only since
   2026-11-17 14:07. Across all local data there are two decreases, bounded by gaps of 7 and 26 days
   (`step_reset_scan.py`). The October pulls do not help. The next ordinary overnight sync will (NOOP pulls every ~15 min
   and the strap buffers history), so **no extra wearer task is needed** for the reset boundary — only NOOP left running.
3. **The optical-burst "PPG matches HR" claim was weaker than reported.** See §2 row R26 and §3: the flat ~6 % chance
   rate ignored that stored HR is concentrated in the sleep range and that the first-pass spectrum peaks near the band
   floor regardless of HR. With the stored per-sample deltas (a derivative signal) there is a real but modest HR
   relation; it is not yet strong enough to support any feature.
4. **Event 120's "HR summary" reading is confounded.** Its strongest field (u16 @8) follows 2-h movement (r −0.77) more
   than HR (r −0.50); after removing time-of-day both shrink and nothing passes a Bonferroni-corrected, split-half
   replication test (`event120_check.py`). "Unknown periodic summary, possibly inverse-activity" is the honest label.
5. **Charging fields are coherent but single-session-type.** 117/110/109/3/7/8/21/22 agree with each other across four
   stored sessions. C02b/C06b (2026-11-20) added one session with wearer-timed attach/removal: 151 `[01]` presence
   followed the pack (on while charging and full, zeros after removal), 117 = 4 came with CHARGING_OFF at 100 %.
6. **Firmware: no image held, no first-hand boot-security evidence.** The 2026-11-20 desk review (§5)
   corrects the Apollo4 default assumption: secure capability is not proof of WHOOP provisioning it.
   Custom installation remains unproven; artifact acquisition and spare-unit debug research are possible leads,
   not demonstrated workarounds.

## 2 · Evidence matrix

Tier: **O** offline · **W** wearer-assisted, no new commands · **A** needs owner approval (strap command/new payload) ·
**H** hardware-invasive (spare unit only, out of scope).

| Question | Observed (B) | Statistical (S) | Interpretation (I) · confidence | Alternative | Falsified by | Next discriminating step | Tier |
|---|---|---|---|---|---|---|---|
| Strap clock vs Mac | live events: deviceTs + receivedAt (alarmEvent); GET_CLOCK replies in E02/E04/H02/H05/H07 | daily min offset 22.2 → 38.9 s, linear +1.41 s/day over 13 days; clock reply ≈ event offset on Nov 2 | strap RTC runs ~16 ppm slow, never corrected on 5.0 · **CONFIRMED** (two methods) | constant delivery latency (ruled out by clock replies); offset changes on reconnect | a day whose minimum drops without a SET_CLOCK; clock reply ≠ event offset | decide whether NOOP should send SET_CLOCK (a strap write: approval) or correct stored timestamps (code-only) | O / A |
| Step counter @49 | u16 increments within 5 s of activity ≠ 0 (544 Oct records; 1,980 change points) | W01 −2.7 %, W02 +1.3 % vs hand counts judged unreliable by the wearer | on-strap step count · **SUPPORTED** | counts arm swings / any periodic motion | increments during non-locomotor arm movement, or a reliable count off by > 5 % | W04 protocol (§4) | W |
| Step reset | 2 decreases, bounded by 7- and 26-day gaps | none possible | daily reset · **UNKNOWN** (time, zone, trigger) | reset at local midnight; UTC midnight; on sync/connect; on charge/reboot; u16 wrap (ruled out: max seen 10,665) | a decrease bounded to a few seconds away from every candidate boundary | S01 night 1 (2026-11-17/18): no drop at local or UTC midnight; one drop bounded to 26 s (08:15:03–08:15:29), 1 s after an alarm rang and ~2.5 min after sleep end → wake or alarm, not midnight. Night 2 (2026-11-18/19, no alarm): no drop at midnight, at natural wake (sleep end 09:21) or at 08:15 → **alarm SUPPORTED** (1 event + 1 control). Night 3 (2026-11-20): frozen prediction met — early smart-wake ring 07:47:40, drop 07:47:41, before the dismissal tap → alarm SUPPORTED by 2 events + 1 control (deadline ring untested). Also a drop during the 23.6-min T03 removal (11-19 18:29–18:52; wrist off/on, handling double taps or a reconnect) → **not the only trigger** | W (passive) |
| Activity code @55 | 0/1/2 only (190 / 1,083 / 163 change points) | 2 only during W02/W03 runs (and 6 s brisk walk); 1 walking; 0 still | classifier output: 0 still, 1 walk, 2 run · 2 **CONFIRMED** on two runs, 1/0 **SUPPORTED** | intensity/cadence bands rather than gait classes; 1 also for cycling or arm motion | code 1/2 during seated arm movement or cycling; code 0 during a counted walk | W04 + non-locomotor block | W |
| R18 float @33 (#44) | never negative; median 0.008 still / 0.164 walk / 0.731 run by activity code; 74,383 full frames (research capture, 2026-11-18/19) | r +0.39 with per-second gravity change; \|g3\| (37/41/45) within 1±0.05 in 95.8 %, \|g4\| incl. @33 p99 1.24 | dynamic-acceleration magnitude (unit unassigned) · **SUPPORTED**; quaternion-w reading **REJECTED** for this firmware | a smoothed activity-intensity index rather than acceleration | hold-out days (from 2026-11-20): any negative values, or medians not increasing 0 < 1 < 2 | `r18_field_inventory.py --since 2026-11-20`; still/rotation/translation scenarios to assign a scale | O, then W |
| R18 u8 @29 (#44) | equals HR @14 in 77.3 %; median \|diff\| 0; > 3 bpm apart in 1.1 % when both set; never set when HR is 0 or vice versa | r +1.00 with HR @14 | a second, closely tracking HR value (e.g. smoothed/alternate estimator) · **UNRESOLVED** | a delayed copy of HR; HR before a correction step | hold-out: equal share outside 50–95 % or median \|diff\| > 1 | lag analysis (@29 vs HR shifted ±1–5 s) on hold-out days | O |
| R18 f32 @105 (#44) | finite, never 0; p1/p50/p99 −5.29 / −5.21 / −1.81; median −5.23 still / −2.96 walk / −2.02 run | only clean float outside the known four | activity-linked quantity, possibly a log-scaled motion energy · **UNKNOWN** | a filter state or a variance estimate | hold-out: medians not increasing 0 < 1 < 2 | relation to float @33 (log transform) on hold-out days | O |
| R18 other bytes (#44) | 112-byte payload: 46 constant, 17 few-valued, 49 varying; few-valued unlabelled bytes share ≤ 0.023 bits with activity code | strongest unlabelled HR correlates besides @29: \|r\| ≤ 0.63 | no motion/rest or quality flag identified · **UNRESOLVED** | flags tied to wear, sleep or signal quality | — | annotated wear/off-wrist/sleep scenarios (W); never mapped to REM/deep/light | W |
| Wrist off/on 10/9 | C02a: live, ~1 s after strap timestamp; DB: 3 pairs (23 s, 23 s, 2 min 3 s) | — | strap's wear detector · **CONFIRMED** once (timed) | proximity/optical contact flag rather than "worn" (could fire on a loose strap or a table) | event 10 with the strap still worn, or no event on a ≥ 2 min removal | T01 (§4): removal, loose wear, charger, table | W |
| Skin temp @65 ÷ 100 | 91,399 samples since Nov 16 14:40; around the C02a removal (2 min 3 s): ~1.4 °C lower at the first reading after reattachment, ~0.45 °C of that recovered within 20 s, then a slow rise over the next 8 min; no samples stored while off-wrist | — | scaling **SUPPORTED** (plausible range, console agreement); sensor accuracy **UNKNOWN**; nightly baseline needs ≥ 5 nights | byte is a filtered/compensated estimate, not raw; lag minutes not seconds | systematic offset vs a skin probe at the same site; non-physiological jumps on charge | T01; reference only with a skin-contact probe, not an air thermometer | W |
| 151 `[01]` | SUCCESS on all 4 reads: pack off `01` + 30 zeros (C06a, and C06b 3 min after removal); pack on (charging, full) `01 01` + id + serial + raw u16 + `0c 01` + 3 zeros | n = 4 (2 on, 2 off) | 28-byte layout: revision, presence, 6-byte id, 16-byte serial, raw charge u16, 2 opaque + 3 padding · presence **CONFIRMED**; raw charge = pack charge in 0.1 % **HYPOTHESIS** | cache lags a transition by more than seen (+53 s / +3 min) | a stale presence after a transition | C06b done 2026-11-20 (EXPERIMENT_LOG) | A |
| 40/42/44 | UNSUPPORTED, 3-byte zero body | n = 1 each | not readable on this firmware · **CONFIRMED** for this payload | readable with a payload | — | none (closed) | — |
| Charger 117/110/109 | 117 byte 1: 2 attach, 2↔3 charging, 0 pause (93 %), 4 with CHARGING_OFF at 100 %; 110 byte 3 tracks it; 109 = pack report (id, serial, raw charge falling 760 → 418 as the strap charged) | 5 sessions (C02b timed) | 117 = 4 full **SUPPORTED** (frozen prediction met once); 0 = pause; 109 = pack self-report **CONFIRMED** (same id/raw as 151); raw = pack charge **HYPOTHESIS** | 4 = thermal stop / removal | 117 = 4 below ~98 % or at removal without CHARGING_OFF | more sessions; interrupted charge | W + A |
| R26 optical bursts | 40-s bursts ~20 min apart; base u32 + 24 i16 deltas; byte 14 takes 0–3, constant for days (changes on Nov 5, 9, 10, 14, 15) | deltas: 67 % within 5 bpm vs 63 % HR-decile shuffle; HR ≥ 80: 28 % vs 9 % shuffle; r +0.51 | pulse-bearing optical window · **SUPPORTED**; HR tracking weak; byte 14 **UNKNOWN** | ambient/motion-dominated signal with occasional pulse; a different LED/gain per byte-14 value | the HR ≥ 80 excess disappearing on new data | §3 tool on more high-HR bursts; per-record clipping check; byte-14 transitions vs reconnect/charge times | O |
| Event 120 | every 2 h exactly; 32-byte body; 5 fields constant | strongest: u16 @8 vs prior-2-h movement r −0.77 raw, −0.41 after time-of-day; nothing passes split-half Bonferroni | periodic summary · **UNKNOWN** | inverse activity/stillness; sleep-state counter; HR (mostly via time-of-day) | a field that replicates against one explanation across days with the others controlled | 2026-11-19 rerun (219 reports): closest u16@18 ~ hr_prev +0.32, u16@21 ~ hr_next −0.31, u8@9 ~ move_prev −0.43 (over Bonferroni overall, halves same sign, per-half not reached) → **frozen** as the only candidates; `event120_check.py --holdout` tests them on reports from 2026-11-20 only (≥ 80, ~2026-11-27) | O |
| Event 14 | ~780 rows, waking hours, clusters; after alarm dismissal (H04/H06b); none during 1.6 h with walks/runs | — | gesture event, used as dismissal · dismissal **CONFIRMED**; "every 14 is a deliberate double tap" **HYPOTHESIS** | wrist-flick/screen-like gesture detector; knock detector | 14 firing during a no-touch negative-control block, or not firing on deliberate taps | G01 (§4) | W |
| Alarm slot writes | event 56 ~50/day to Nov 16; **2 on Nov 17** | app history Nov 17: 1 deadline SET, 1 ring-now SET + 1 RUN, 52 GET verifies | read-before-write works on the strap · **CONFIRMED** (first real day) | — | ~50/day returning | keep counting for a week | O |
| fd4b0007 | 244-byte fragments at connect before hello (E01); silent on a probe-only connect | — | debug/crash channel (external Memfault naming) · **SUPPORTED** externally only | build-id/heartbeat chunks | — | passive capture of a NOOP-initiated connect (C02 scope) | A |
| Firmware readout | no read command in any reviewed source; 143 only inside an update load | — | **no known path** (not proof of none) | undocumented diagnostic export; app-side cache of packages | a documented read command or vendor tool | §5 ladder | — |

## 3 · Optical bursts (R26): corrected analysis

`Tools/whoop_re/ppg_burst_check.py` on all 1,085 bursts ≥ 30 s (1,084 with stored HR). Frequency resolution of a 40-s
window is 1.5 bpm; "match" = strongest 40–200 bpm component within 5 bpm of the median stored HR over the burst.

| Variant | Match | Controls | Notes |
|---|---|---|---|
| First pass (record minus its own mean; 2026-11-17 earlier, 279 bursts Nov 14–17) | 161/279 (58 %) vs "≈ 6 % chance" | chance assumed uniform peaks | the reported figure |
| Same method, all 16 days (`--mode mean`) | 592/1,084 (55 %) | shuffled bursts ≥ 6 h apart **27 %**; HR shifted ±10 min **45 %**; within HR deciles **53 %** | peak vs HR r **−0.10**; matches 91 % at HR < 60, **3 %** at HR ≥ 80 → the peaks sit at 40–70 bpm whatever the HR, and the sleep-range HR does the "matching". Subtracting each 1-s record's mean also injects a 1 Hz (60 bpm) artifact (synthetic test) |
| Stored deltas as a derivative signal (default `--mode deltas`) | 725/1,084 (**67 %**), median error 2.0 bpm; 21 at 2×HR, 32 at HR/2 | shuffled **25 %**; ±10 min **50 %**; within HR deciles **63 %** | r **+0.51**; 299 peaks still at 57–63 bpm (record-boundary artifact) |
| Deltas with 57–63 bpm masked (`--mask-1hz`) | 592/1,084 (55 %); **134 at 2×HR** | shuffled 19 %; ±10 min 39–40 %; within HR deciles 50 % | r +0.31; HR ≥ 80: 61/210 (29 %). Removing the 1 Hz artifact pushes many peaks to the 2×HR harmonic, so the pulse fundamental is weak relative to its harmonic |
| Deltas, bursts with HR ≥ 80 only | 59/210 (**28 %**) | shuffled within the stratum **9 %** (95th pct 12 %, max 14 % of 500) | the only stratum where chance is low: genuine HR tracking, but weak |

Byte 14 (values 0–3, five transitions in 16 days, otherwise constant for days) does not change the match rate
(64–69 % per value). Its transitions should be compared against charge sessions, reconnect storms and NOOP restarts
before guessing (five transitions: any alignment would be weak evidence). Burst framing: 1,068 of 1,085 bursts are
exactly 40 records; counter + 1 per burst; no sample clipping checked yet (next: min/max per record vs i16 range).

Why same-strap HR is not validation: the strap's stored HR is very likely computed from this same optical front end, so
agreement shows the bytes carry a pulse-related signal, not that either is physiologically correct. No second channel,
wavelength or LED identity is visible, so **no SpO₂** can be derived. **Decision (#45, 2026-11-19): no product use of R26.** Rerun on 1,220 bursts: 55 % matched with the 1 Hz record-rate artifact masked vs 51 % within-HR-decile and ~40 % for ±10-min-shifted HR, so pulse content specific to the burst is weak. Bytes stay archived for research; revisit only with a second channel or a reference. Product use is **not recommended**: nothing here
beats the HR NOOP already has.

## 4 · Proposed experiments — **not executed**

All wearer experiments use **Mac time** (System Settings clock or `date` in Terminal) and are read against
`strap_clock_offset.py`'s offset for that day (subtract ~40 s from Mac times to get strap time, Nov 2026). NOOP is the only
client unless stated; no probe runs.

| ID | What | Who | Procedure | Stop / analysis |
|---|---|---|---|---|
| S01 | Step reset boundary | passive | Leave NOOP running and connected overnight; nothing else. Next morning copy the DB (SQLite backup). | `step_reset_scan.py --db copy`: expect one decrease bounded to ≤ a few seconds; compare with local midnight (strap time) and UTC midnight. Repeat on a second night before relying on it. |
| W04 | Reliable counted walk + non-locomotor control | wearer | Note Mac time at each mark. 2 min standing still → 500 steps counted with a hand tally counter (or video of feet) → 2 min still → 200 steps running → 2 min still → 3 min seated arm movement (typing, gesturing, no steps) → 2 min still. Phone pedometer may run as a comparison, not ground truth. | Per-block `step_walk_check.py` with offset applied; still blocks must add ~0; arm block reveals false steps and code 1/2 misfires. |
| T01 | Wear state vs temperature | wearer | Note Mac times. 10 min worn → remove, place on table 5 min → replace 10 min → loosen strap one notch 5 min (worn) → remove and put on charger 10 min → off charger, worn 15 min. | Event 10/9 latency vs notes; whether a loose strap triggers 10; temperature lag/settling per transition; temperature on the charger. |
| C02b + C06b | Charging session | owner approval for C06b only | NOOP connected. Pack attached (note time) → charge to full → wait 10 min → detach (note). If convenient, one interrupted charge (detach at ~60 %, reattach). **C06b**: once with pack attached and charging: `ble_probe --commands 151 --pack-rev1` (one run, one attempt, seq 200–255, 7 s timeout). | Expect 7/21 at attach, 3 with charging bit, 109 every 10 min, 117 2→3→4, 110 stages, 8/22 at removal. C06b: SUCCESS with non-zero bytes → compare with pack-off reply; same zeros → `01` is not a pack selector or the pack has no data; FAILURE/anything but a 36 response → stop. |
| G01 | Event 14 specificity | wearer | Note Mac times. 5 min no touching (control) → 10 deliberate double taps, 30 s apart → 5 min control → 10 single taps → 10 wrist flicks → 10 knocks on a table near the strap. No alarm active. | Count 14 per block (events pull with history). Deliberate taps ≈ 10 and controls 0 supports "double tap"; flicks/knocks firing shows a broader detector. |
| K01 | Strap clock | owner decision | Option A (no strap write): NOOP stores `receivedAt − deviceTs` offsets and maps stored 5.0 timestamps to Mac time (code change + rescoring). Option B: allow SET_CLOCK on 5.0 (8 bytes `[unix u32][subsec u32]`; persistent write, WHOOP's app sends it). **Decided 2026-11-18: B.** One-shot test passed (−40.47 s → −0.07 s; history still served); NOOP re-syncs at most daily after a completed pull (`ClockResyncPolicy`, key `noop.clock.autoResync`). Option A (re-mapping timestamps stored before the fix) not done. | A is reversible and offline-testable; B fixes drift at the source. |

## 5 · Firmware feasibility and workarounds — desk review 2026-11-20

**Result: no demonstrated custom-firmware installation or reliable downgrade was found. Hardware impossibility
has not been established.** The owner requested a fresh online investigation after the #47 no-go decision of
2026-11-19. That historical decision remains the implementation boundary; this review recommends bounded
artifact/security research, not flashing. No GitHub issue was reopened by this review.

Scope: repository evidence and command implementation, public reverse-engineering projects, firmware archive
references, FCC filings, Ambiq security documentation and advisories. No binary or owner app package was acquired
or analysed; no strap commands, debug attachment, update, private-service request or hardware experiment occurred.
The locally observed target remains WHOOP 5.0 `WG50_r52`, firmware `50.43.1.0`.

### Security assumptions corrected

Ambiq confirms WHOOP uses Apollo processors [1], but the exact part on this unit remains unknown. The earlier
statement that Apollo4 ships with customer secure boot enabled was too strong: Ambiq's security guide says
“An unprogrammed chip defaults to Non-secure mode.” Secure SKU, customer boot policy and lifecycle state are
separate concepts. Apollo3 also has configurable boot/debug policy [2,3]. These are chip capabilities, not
measurements of WHOOP's production provisioning. Signed membership certificates (155–159) likewise do not prove
image signing or boot authentication.

Keep four boundaries distinct: transfer/integrity, installation, authenticated boot, and recovery. Acquiring an
image or recalculating CRCs does not establish the latter three. Conversely, compression/high entropy alone does
not establish encryption. A server fetch or empty phone cache closes that acquisition lead, not all acquisition.

### Feasibility ladder

| Route | Evidence and limits | Next evidence / stopping condition |
|---|---|---|
| Original image, offline | **None held.** Search-indexed `tanarchytan/whoop-firmware` README describes 4.0, 5.0/MG and pack manifests, hashes and release binaries; direct repository, releases, README and 5.0 manifest requests returned 404 [4]. A former archive lead, not an available download. | Obtain a provenance-backed original/cached artifact; record source, SHA-256, version and target. No recovered binary means no offline firmware conclusions. |
| App/update architecture | No owner app package inspected. Upstream describes image comparisons and 50.42.1.0 transfer/container contracts, including compressed and decompressed forms [5]. This revises the earlier suggestion that only a 4.0 container was described. | Inspect an owner-controlled app/cache or surviving research artifact. Determine full vs delta, chip-specific code, authentication, boot handoff and recovery. Do not infer successful installation from upstream documentation. |
| Debug or wired boot | Exact MCU, SWD exposure, protection state and boot policy **UNKNOWN**. Public WG50 FCC internal photographs exist [6]; they establish neither debug pinout nor unlocked access. No read/dump command is known; 143 readback checks a just-written update chunk, not installed firmware. | Spare-unit board/part survey and evidence of actual protection configuration; separately scoped hardware work. No protection changes or erase-to-unlock attempts. |
| Older signed WHOOP image | Could preserve old behavior without replacing the OS, **if** compatible images and rollback policy permit it. No reliable public downgrade found [5,7]. WHOOP 4.0's Maxim/Nordic architecture does not transfer to 5.0. | Authentic compatible image, rollback/boot-policy evidence and recovery route; stop short of installation without these. |
| Modified/custom image | Application CRC checks are documented externally; signature, boot acceptance and rollback remain unresolved for our unit [5]. | If WHOOP-enforced authentication requires unavailable keys, ordinary flashing is blocked. An open debug path or permissive boot policy could change feasibility; neither is demonstrated. |
| Runtime/bootloader flaw | Possible in principle; no WHOOP custom-code or persistent-install demonstration found. See advisories below. | First establish affected implementation, patch state and reachability. Runtime execution would not by itself establish persistence through authenticated boot. |
| External flash read/replacement | Engineering hypothesis: may recover stored artifacts; contents and boot role unknown. Does not inherently defeat MCU authentication. | Establish memory map and storage role before treating it as an image or boot route. |
| MCU/board replacement | Engineering alternative, not an unlock: effectively a new wearable using some existing components. | Requires board mapping, drivers, calibration, charging and power management. No implementation proposed. |

### Published vulnerabilities: relevant leads, not a WHOOP exploit

Ambiq's January 21, 2026 advisory covers Cordio host-stack CVE-2024-48981 through CVE-2024-48986 across
Apollo3/4/5 variants, with fixes available [8]. Our console naming is consistent with Cordio, but this does not
establish affected code or patch status. The original maintainer disclosure concerns HCI parsing, the
controller-to-host interface [9]; arbitrary malformed HCI input is not equivalent to an ordinary remote BLE
command. Memory corruption could be relevant, but reachability, usable code execution and persistence are all
unproven here. No ready-made WHOOP workaround was found.

The other reviewed Ambiq advisory (PSNGA02EN v1.1, July 27, 2026) concerns Cortex-M55 security extensions and
toolchains [10], not evidence of a vulnerability on the reported Cortex-M4 WHOOP platform. No demonstrated
WHOOP fault-injection or boot-security bypass was found in the searches; absence of a result is not proof of
absence.

### Practical fallback: standard Bluetooth HR and R–R

OpenStrap reports describe proprietary data withholding on some 50.43.x straps and restoration after an official
signed, device-bound membership token. A November 19 comment reports HR/R–R still flowing on standard
`0x180D`/`0x2A37` from a reportedly locked 50.43.2.0 strap [11]. This is **external, unverified evidence**; cold-start
enablement, token state and indefinite operation are not established. Firmware version alone does not diagnose a
lock, and our working 50.43.1.0 unit has not been shown to be affected.

Locally, `Strand/BLE/Commands.swift` already implements command 14 for standard HR broadcast, with a recorded
2026-10-21 hardware check; listening is opt-in (`listenToHRBroadcast`). A continuous nearby collector is a
potential fallback for live HR/R–R, **not implemented or tested here as a locked-device fallback**. It cannot
recover disconnected history or substitute for temperature, motion and other proprietary records. Existing
stock-firmware decoding/configuration research remains the practical path for NOOP features.

### Recommendation and boundaries

1. Prioritize a provenance-backed image or owner-controlled app/cache for offline analysis; the former archive
   and upstream artifact authors are leads. Nobody was contacted in this task.
2. If hardware research is pursued, identify the MCU and actual debug/boot protection on a dedicated spare.
   Survey scope needs separate review; flashing still requires a known recovery route. No spare or recovery
   route was established in this task.
3. Validate standard HR/R–R as a fallback separately if data access becomes a concern. Do not assume that a
   membership gate and secure boot are the same mechanism.
4. Keep custom firmware outside the implementation plan until code loading, boot acceptance and recovery are
   demonstrated. This desk review changes evidence quality, not the app's command allowlists or safety rules.

### Sources checked 2026-11-20

1. [Ambiq Q2 2025 customer disclosure](https://s206.q4cdn.com/849744944/files/doc_financials/2025/q2/Ambiq-Reports-Second-Quarter-2025-Finanicial-Results-Transcript.pdf).
2. [Apollo4 Security User's Guide, §5](https://contentportal.ambiq.com/documents/20123/387822/Apollo4-SoC-Security-Users-Guide.pdf): configurable customer security; unprogrammed non-secure default. The indexed tokenized PDF was readable; the bare link was intermittently unavailable.
3. [Apollo3 Blue security guidelines](https://contentportal.ambiq.com/documents/20123/387797/Apollo3-Blue-Family-Typical-Security-Guidelines-App-Note.pdf).
4. [Former firmware archive](https://github.com/tanarchytan/whoop-firmware): search-indexed README only; direct routes returned 404. Its binary provenance/hash claims were not independently verified.
5. [Upstream NOOP update research](https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_UPDATES.md), baseline 50.42.1.0: community protocol contracts, expressly not a validated installation procedure.
6. [WHOOP WG50 FCC internal photographs](https://fccid.io/m/f48b526dd1f29ba13dbbcfd43fc7264bcf9d6c15736ba56c5c86f1b9ba925e97.pdf), public filing mirror.
7. [OpenStrap compatibility assessment](https://github.com/OpenStrap/edge): no reliable downgrade established.
8. [Ambiq Cordio advisory PSNGA01EN](https://contentportal.ambiq.com/documents/20123/5519281/Ambiq-Security-Advisory-A-SOCAPG-PSNGA01EN-3B-3BP-330BP-330MP-4B-4BL-4BP-510B-510BL.pdf).
9. [Mbed maintainer disclosure](https://forums.mbed.com/t/mbed-os-ble-security-vulnerabilities/24482): indexed text readable; direct opening redirected to ArmMbed GitHub during this review.
10. [Ambiq Cortex-M55 advisory PSNGA02EN](https://contentportal.ambiq.com/documents/20123/5519281/Ambiq-Security-Advisory-A-SOCAPG-PSNGA02EN-330BP-330MP-510-510L-510B-510BL-510DL.pdf).
11. [OpenStrap issue #673](https://github.com/OpenStrap/edge/issues/673): first-hand community reports, including November 19 standard HR/R–R observation; not local acceptance tests.

## 6 · Ranked next steps

| # | Step | Information gained | Prerequisites | Effort | Risk | Stopping rule |
|---|---|---|---|---|---|---|
| 1 | S01 passive overnight + `step_reset_scan.py` | reset boundary (gates any daily step total) | NOOP left running | minutes | none | one decrease bounded ≤ 60 s on two nights |
| 2 | K01 decision (clock) | correct timestamps for every 5.0 stream | owner choice | A: ~1 day code; B: one approved write | A none; B persistent strap write | offset < 2 s after the fix |
| 3 | W04 counted walk | step error figure, code 1/2 false positives | tally counter or video, Mac clock | 20 min | none | error bound ≤ 3 % on two walks and arm block ≤ 10 steps |
| 4 | C02b + C06b | charging semantics; meaning of 151 body | pack, approval for C06b | 2–3 h passive + 1 read | low (one read) | one session with all transitions; C06b reply compared |
| 5 | T01 | wear detector behaviour; temperature lag | wearer, charger | 1 h | none | latencies and lag measured once each, repeat if surprising |
| 6 | G01 | event 14 specificity | wearer | 30 min | none | controls 0 and taps ≥ 8/10, or a clear counterexample |
| 7 | R26 / event 120 reruns | whether weak relations hold with more days | time | minutes each | none | relation passes the stratified / split-half controls, or is dropped |
| 8 | Firmware stage A/B (app package, owner's own) | whether any artifact path exists | owner provides package | hours | none (offline) | §5 next-evidence / stopping conditions |

Defined for steps before Trends (do not add Trends until #1 and #3 pass): a **daily total** is defined only when the
reset boundary is known and the day has a reference row before its first step; reset-crossing increments count the
post-reset value (steps since reset) instead of being dropped; a day with a sync gap that spans activity is **partial**
(show "at least N"); activity durations end at the first missing second (record presence from the per-second streams),
never carried across gaps; no rows = unavailable, never 0. **Implemented 2026-11-18 (PR #50)** in
`StepCounterSample.window(known:)` + `Repository.strapSteps`: post-reset value counted, an older reference row used only
when the window's first second synced, activity only over synced seconds, "≥ N" until the reset boundary is established.

## 7 · Recommendation

- **Now:** S01 (free), the K01 decision (Option A is fully offline), W04 with a tally counter, and the charging session
  when a pack is at hand. These convert the step counter and charging fields from "supported" to defensible product
  features, and fix a systematic ~40-s timestamp error in all 5.0 data.
- **Defer:** any R26 feature (no benefit shown over existing HR), event 120 semantics (insufficient data), Trends steps
  (blocked on S01/W04), and firmware installation; §5 recommends artifact acquisition and offline analysis first.
- **Would change this:** a public or owner-cached 5.0 image without per-device encryption (re-opens stage C); evidence
  that secure boot is not provisioned (re-opens E, still spare-unit only); a reliable count showing > 5 % step error
  (drop the step feature); a stratified-control-beating R26 HR match on high-HR bursts (re-open R26 as an independent
  pulse check).

Tools added for this pass (stdlib, read-only on copies, synthetic tests in `Tools/whoop_re/test_offline_checks.py`):
`strap_clock_offset.py`, `step_reset_scan.py`, `ppg_burst_check.py`, `event120_check.py`.

## 8 · Program closure (2026-11-20)

Issue #25 closes with every original question answered, ruled out, or deferred to the backlog below with its evidence
and stopping rule. Outcomes, one row per follow-up issue:

| Issue | Outcome | Status at closure |
|---|---|---|
| #38 research capture + backup | Full-frame capture, ack gate, backup/restore/replay procedure; live acceptance A01 passed | Closed (done) |
| #39 live packet 40 | Bounds fix; live R–R unit = ms **CONFIRMED** (L01) | Closed (done) |
| #40 config reads 121/128 | C08: 4/4 named reads, layout **CONFIRMED**; NOOP never sends them | Closed (done) |
| #41 charging / pack info | 151 `[01]` layout **CONFIRMED**, 117 = 4 = full, 109 = pack report; app decodes presence and "Fully charged" | Done; interrupted-charge and reconnect-with-pack checks → backlog |
| #42 steps | Counter tracks walking/running (W01–W03); reset follows alarm rings (S01, 2 mornings) and one removal; no midnight reset; experimental tile with completeness rules | Done at experimental scope; accuracy figure (W04) and deadline-ring reset → backlog |
| #43 wear + skin temperature | Events 10/9 = off/on **CONFIRMED** (C02a, T03); nightly temperature stored from 11-17, change appears after 5 nights | Done; first change value (~11-22) and an in-night removal → backlog |
| #44 R18 fields | float@33 = dynamic acceleration **SUPPORTED**, quaternion rejected; u8@29, f32@105 unresolved | Done offline; frozen hold-out (`--since 2026-11-20`, after 11-25) → backlog |
| #45 R26 / event 120 | R26: **no product use** (weak burst-specific pulse, one channel, no SpO₂); event 120 candidates frozen | Decided; hold-out (~11-27, ≥ 80 reports) → backlog |
| #46 ordinary-use outcomes | Alarm writes 49 → 2/day **CONFIRMED**; redundant battery reads skipped; daily clock re-sync observed; in-app counters running | Done; multi-day counter rates and controlled drain → backlog |
| #47 firmware | **No-go** (no image, no read path, auth commands, unknown boot/recovery); desk review 2026-11-20 in §5 | Closed (no-go) |
| #48 deterministic trend tests | Fixed-date anchor + DST/UTC tests | Closed (done) |

**Backlog after #25** (no strap writes; each runs on copies or passively, rules frozen above):

1. Event-120 hold-out — `event120_check.py --holdout` once ≥ 80 reports exist (~2026-11-27); no verdict below that.
2. R18 hold-out — `r18_field_inventory.py --since 2026-11-20` after the capture ends (2026-11-25).
3. W04 counted walk (tally counter, ≥ 1,000 steps, still edges) → step error bound; > 5 % error drops the feature.
4. Step reset on a deadline (non-early) ring; a tap-free removal.
5. First nightly skin-temperature change (~2026-11-22) and one off-wrist interval inside a night.
6. Charging: interrupted charge (~60 %), reconnect with the pack on, 151 latency after a transition.
7. #46 counters over several days; a controlled discharge window.

Never in scope without a new owner decision: firmware writes or extraction, key sweeps, SET twins (39/41/43),
121/128 writes.
