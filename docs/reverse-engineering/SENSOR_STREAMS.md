# Sensor streams (WHOOP 5.0, fw 50.43.1.0)

Only what this strap was seen to deliver is CONFIRMED. Anything known from 4.0 or other firmware is not
assumed to exist here.

| Signal | Path | Rate / format | Label |
|---|---|---|---|
| Heart rate | type-47 history, payload[14] | 1 record/s, u8 bpm | CONFIRMED |
| R-R intervals | type-47 payload[15..] | up to 4 × u16 ms per record | CONFIRMED |
| Gravity / orientation | type-47 payload[37..48] | 3 × float32 g, 1/s | CONFIRMED |
| Heart rate (standard) | 2A37 | ~1 Hz, BLE HR profile with R-R in 1/1024 s; only while cmd 14 is on | CONFIRMED (NOOP 2026-10-21) |
| Battery % | 2A19 and cmd 26 | u8 % | CONFIRMED |
| Battery mV / charging | event 3 BATTERY_LEVEL | soc @1, mV @5, charging byte 9 bit 0; pushed ~every 30 s while charging | CONFIRMED (fw 50.43.1.0) |
| Connection events | events 11/12 | — | CONFIRMED |
| Skin temperature | type-47 v0x12 payload 65 u16 ÷ 100 °C | 1/s with every history record; ≈ 35 °C on 544 local frames, matching console `skin_temp = 35.01` | SUPPORTED + locally consistent (not decoded by NOOP) |
| Wear detection | firmware state machine `SIGPROC-WEAR-DETECT V5` (console); events 10 (off) / 9 (on), live on fd4b0004 | ~14 s after removal / ~15 s after replacing in C02a (wearer-timed to the minute) | CONFIRMED once (C02a) |
| Optical window (type-47 v0x1a "R26") | history, 40-s bursts ~every 20 min | u32 base + 24 × i16 deltas per record (25 samples); burst counter @13 | layout SUPPORTED + locally consistent; **25 Hz single-channel PPG** (HR-matched in 161/279 bursts, 2026-11-17); wavelength UNKNOWN; no red/IR pair, so not SpO₂ |
| Other optical / IMU streams | Goose's capture sequence uses cmds 107/108/153 | not tested (needs a start/read-back/stop/restore lifecycle first) | UNKNOWN beyond R26 |
| Accelerometer raw / gyroscope | Goose: 106 `[1,1]`, 154 persistent R21; ryanbr/noop: R21 IMU 1244 B | not tested (154 is gate C) | UNKNOWN |
| Realtime HR (type 40) | cmd 3 `[1]` on / `[0]` off, fd4b0005 | 1 Hz, u8 bpm at payload[8], strap-clock unix at payload[2]; no R-R observed | CONFIRMED (E04) |
| Respiration, SpO2 | not in decoded fields | — | UNKNOWN |
| ECG ("Labrador") | Goose cmds 124/125/139 | MG-specific? | UNKNOWN; not tested |

Scaling, sampling and timestamps for the CONFIRMED rows: history timestamps are strap-clock unix seconds,
and the strap clock runs ~15 s behind wall time (E02: 13–18 s; 2026-10-31 note: ~15 s). NOOP stores them
uncorrected. Missing samples: HR was never 0 in the 634 captured records; records with no valid R-R carry
count 0. The strap does not fill gaps: records are only produced while it is collecting.

Battery and bandwidth: a history pull runs at ~6.2 KB/s (firmware PullStats). Realtime HR costs one 32-byte frame per second (~32 B/s, negligible). Raw IMU has not been measured; it will be measured
in a bounded window (≤ 60 s) once approved.
