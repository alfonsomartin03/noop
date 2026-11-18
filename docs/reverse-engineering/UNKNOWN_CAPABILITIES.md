# Unknowns and hypotheses

| Topic | Status | How to resolve safely |
|---|---|---|
| Does the trim pointer **erase** data, or only mark it read? GET_DATA_RANGE still reports an oldest record from 2026-10-11 after many acks. | UNKNOWN | Passive: compare oldest time across days. Goose's SET_READ_POINTER (33) might re-serve trimmed data; restricted, needs approval. |
| Data-range words +1 / +9 / +21 / +25 | UNKNOWN / HYPOTHESIS (+41/+49/+57 CONFIRMED on two samples) | More samples around a pull. |
| Is CLIENT_HELLO required before other commands? | UNKNOWN | E06 (probe as sole client). |
| fd4b0007 content (Memfault chunks?) | SUPPORTED name only; **silent** on a fresh probe-only connect without hello (C02a) — HYPOTHESIS: sent after something NOOP does at connect (hello/bond) | Passive `--passive` capture while NOOP itself connects (probe attached first); no debug writes. |
| fd4b0004 coverage | Live alarm/haptic events CONFIRMED (H02b–H07); which other kinds go live is UNKNOWN | Passive capture C02 (CAPABILITY_MATRIX.md). |
| Header bytes 4–5 meaning (`00 01` / `01 00`) | HYPOTHESIS: direction or source/destination | Already consistent on 900+ frames; no active test needed. |
| Events 110, 120, 123; body of 29 | 29/110 periodic (10 min), 29 u16 @6 = soc × 10 (locally CONFIRMED); 109 charge-current-like, 117 charger state (HYPOTHESES, CAPABILITY_MATRIX.md §3); 123 HYPOTHESIS connection state; 110 charger-status report (HYPOTHESIS, 2026-11-17); 120 tracks prior-2-h HR (correlation only, meaning UNKNOWN) | C02 passive capture with timed actions; for 120 test competing explanations (following vs prior HR, steps, wear, sleep, time of day) on held-out days. |
| Type-47 v0x1a records (frame 88, payload 76) | time @7, counter @3, 40-s bursts ~every 20 min, u32 base + 24 × i16 deltas = **25 Hz single-channel PPG** (2026-11-17, HR-matched); wavelength, quality fields and purpose UNKNOWN | Controlled passive scenario; no guessed offsets. |
| Wrist on/off on 5.0; meaning of frequent event 14 | Double tap (14) CONFIRMED as alarm dismissal; ~780 daytime-clustered occurrences in 2 weeks (HYPOTHESIS: also fires on activity); wrist off/on = events 10/9 (C02a, CONFIRMED once) | More timed off/on samples; charging scenario C02b still pending. |
| Skin temperature over BLE | type-47 v0x12 payload 65 u16 ÷ 100 °C (external layouts; 544/544 local frames plausible, ≈ 35 °C) — SUPPORTED, no reference thermometer | Decode in NOOP (CAPABILITY_MATRIX.md §5 #6). Goose's raw fd4b0007 debug write stays prohibited. |
| Undecoded type-47 bytes (optical, SpO2, respiration) | UNKNOWN; R18 leads (quality flags, alt HR, band state, step source) listed in CAPABILITY_MATRIX.md §4; byte 82 is **not** an established SpO₂ value. Full R18 frames can now be kept (`ResearchCapture`) | Correlation only after controlled scenarios; no guessed offsets. |
| Realtime HR (type 40): R-R slots (payload 9–17) and byte 18 | timestamp/HR CONFIRMED (E04); R-R never seen | Repeat E04 during light movement or after exercise, when R-R is more likely to be reported. |
| Raw IMU / optical streams on 5.0 | SUPPORTED (Goose commands) | Restricted; 154/153 are persistent toggles, so prohibited. |
| Haptics on 5.0 | 19 notify buzz + 122 stop CONFIRMED (H07); other patterns UNKNOWN (80 UNSUPPORTED) | No new patterns without approval. |
| Alarm payloads | `[4, 1, …]` SET/GET, `[2,1]` RUN, `[2,0xFF]` disable CONFIRMED (H02b–H06b, H04); id 0 invalid; NOOP uses them | Rewrite cadence finding in CAPABILITY_MATRIX.md §5. |
| Cmd 84 / 151 failures: argument needed or feature absent? | **151 resolved** (C06a 2026-11-17): payload `[01]` → SUCCESS with the pack off; pack-on reply still unseen (C06b). 84 still UNKNOWN | C06b with a pack; do not guess payloads. |
| Corrupt-frame and unknown-command error responses | UNKNOWN | Not tested by policy. |
| MG vs 5.0 differences, "puffin" service 11500001 | UNKNOWN; absent on this unit | — |
| Charging state on 5.0 | Event 3 byte 9 bit 0 CONFIRMED (500 stored events, two charge sessions); events 7/8/21/22 observed on pack attach/remove; 151 SUCCESS reply while attached never captured; events 109/117 appear around charging (UNKNOWN) | Passive capture with a pack attached (C02). |
| Strap clock drift rate | ~15 s slow on two dates | Repeat GET_CLOCK daily (read-only). NOOP never sets the 5.0 clock. |
| Capability status per Phase 11 list | stream control: probable; sampling modes: speculative; haptics: probable; LED: unsupported (no LED commands in Goose 5.0 beyond optical drive, prohibited); clock: confirmed read, probable set; power-saving/ship mode: unsafe | — |
