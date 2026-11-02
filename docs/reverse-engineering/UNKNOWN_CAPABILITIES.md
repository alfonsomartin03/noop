# Unknowns and hypotheses

| Topic | Status | How to resolve safely |
|---|---|---|
| Does the trim pointer **erase** data, or only mark it read? GET_DATA_RANGE still reports an oldest record from 2026-10-11 after many acks. | UNKNOWN | Passive: compare oldest time across days. Goose's SET_READ_POINTER (33) might re-serve trimmed data; restricted, needs approval. |
| Data-range words +1 / +9 / +21 / +25 | UNKNOWN / HYPOTHESIS (+41/+49/+57 CONFIRMED on two samples) | More samples around a pull. |
| Is CLIENT_HELLO required before other commands? | UNKNOWN | E06 (probe as sole client). |
| fd4b0007 content (Memfault chunks?) | SUPPORTED name only | E07: capture at connect, redact, check for Memfault chunk header. |
| fd4b0004 purpose (silent so far) | UNKNOWN | Keep subscribed in all experiments. |
| Header bytes 4–5 meaning (`00 01` / `01 00`) | HYPOTHESIS: direction or source/destination | Already consistent on 900+ frames; no active test needed. |
| Events 110, 120, 123; body of 29 | 29/110 periodic (10 min); 123 HYPOTHESIS connection state; 120 UNKNOWN | E05 and more reconnects. |
| Type-47 v0x1a records (88 B) | time @7 CONFIRMED; rest UNKNOWN | Offline analysis of the archive in Application Support/OpenWhoop/undecoded-history. |
| Wrist on/off and double-tap on 5.0 | UNKNOWN | E05 with the strap removed and replaced. |
| Skin temperature over BLE | firmware computes it; BLE location UNKNOWN | Look for a ~35 °C quantity in undecoded type-47 bytes across a warm/cool change; Goose's fd4b0007 debug request is restricted. |
| Undecoded type-47 bytes (optical, SpO2, respiration) | UNKNOWN | Correlation only after controlled scenarios; no guessed offsets. |
| Realtime HR (type 40): R-R slots (payload 9–17) and byte 18 | timestamp/HR CONFIRMED (E04); R-R never seen | Repeat E04 during light movement or after exercise, when R-R is more likely to be reported. |
| Raw IMU / optical streams on 5.0 | SUPPORTED (Goose commands) | Restricted; 154/153 are persistent toggles, so prohibited. |
| Haptics on 5.0 (cmd 19 vs 79; 80 returned UNSUPPORTED) | SUPPORTED (Goose: 19) | Restricted; needs approval (buzzes the strap, harmless but user-visible). |
| Alarm payloads (`[4, alarmId, …]` per Goose vs NOOP's 4.0 form) | SUPPORTED | Restricted; NOOP's alarm code uses the 4.0 form and is blocked on 5.0, which is correct. |
| Cmd 84 / 151 failures: argument needed or feature absent? | UNKNOWN | Code analysis of Goose first; do not guess payloads. |
| Corrupt-frame and unknown-command error responses | UNKNOWN | Not tested by policy. |
| MG vs 5.0 differences, "puffin" service 11500001 | UNKNOWN; absent on this unit | — |
| Charging state on 5.0 | UNKNOWN: no CHARGING_ON/OFF event seen, 2BED absent, event 3 charging bit SUPPORTED only | Passive: capture event 3 bodies while the strap charges (probe attached during a NOOP pull) and compare with the charger LED. |
| Strap clock drift rate | ~15 s slow on two dates | Repeat GET_CLOCK daily (read-only). NOOP never sets the 5.0 clock. |
| Capability status per Phase 11 list | stream control: probable; sampling modes: speculative; haptics: probable; LED: unsupported (no LED commands in Goose 5.0 beyond optical drive, prohibited); clock: confirmed read, probable set; power-saving/ship mode: unsafe | — |
