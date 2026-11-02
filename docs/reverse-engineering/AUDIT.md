# Audit of NOOP's existing BLE integration (2026-11-02)

## Architecture map

| Concern | Where | Notes |
|---|---|---|
| Discovery / connect | `Strand/BLE/BLEManager.swift` `connect()`, `startUnfilteredScan()` | retrieve system-connected → filtered scan (6108/fd4b) → name scan after 10 s |
| Family detection | `peripheral(_:didDiscoverServices:)` | fd4b0001 → `.whoop5` |
| Pairing / bonding | 4.0: confirmed write of GET_BATTERY_LEVEL; 5.0: hello write ack (`markWhoop5Hello`) + ATT-error retry ×6 | stale-bond detection on `peerRemovedPairingInformation` |
| Subscriptions | 5.0: every notify char in fd4b0001, plus 2A19; 2A37 only if user opts in | |
| Framing / CRC | `Packages/WhoopProtocol/Framing.swift` | CRC8/CRC16/CRC32, `verifyFrame`, `buildWhoop5Frame`, `Reassembler` |
| Command set | `Strand/BLE/Commands.swift` (`WhoopCommand`), 5.0 allowlist `BLEManager.whoop5Allowed` | 4.0 frame builder in `WhoopCommand.frame` |
| Decode | `Interpreter.swift` + `whoop_protocol.json` (4.0), `Streams.swift` `decodeWhoop5Realtime` / `decodeWhoop5Historical` (5.0) | |
| Routing to UI | `FrameRouter.swift` | 5.0: realtime only; returns before EVENT |
| History (4.0) | `Collect/Backfiller.swift` | durable-before-ack order |
| History (5.0) | `BLEManager.pullWhoop5History` / `commitWhoop5HistoryChunk` | ack after `persistDecodedHistory` |
| Recovery | keep-alive 30 s, bounce after 120 s silence, rescan 3 s after disconnect | |
| Tests | `Packages/WhoopProtocol/Tests` (85 tests, 4.0 golden frames + 5.0 framing) | no 5.0 captured-frame fixtures before this work |

## Status (2026-11-02)

Findings 1, 3, 4, 5, 6, 7 are fixed in code; finding 2 now has an explicit ack policy (SAFETY_MATRIX.md). New
defects found and fixed while doing so: the 5.0 keep-alive was never started (no battery polling or link watchdog
on 5.0); the periodic pull skipped every other tick (899 s < 900 s floor); type-47 records that failed to decode
were dropped while their chunk was still acked; 0x2A37 samples were stamped in Mac time beside strap-time history.

## Findings

1. **Data-range "newest" is wrong on 5.0.** `logWhoop5DataRange` uses body+41 as newest; E02 shows +41 is
   the last-acked chunk time and +57 is the newest record. The Today sync strip therefore shows a stale end.
2. **Ack = trim, by default.** `keepDataOnStrap` defaults to `false`, so every 5.0 pull advances the strap's
   trim pointer (firmware log CONFIRMED). The commit message of `e066c08` describes the opposite default.
   Whether the WHOOP app can still read trimmed data is UNKNOWN. This is behaviour you chose; flagging so
   it is deliberate.
3. **5.0 events are dropped.** `parseFrame` uses 4.0 event offsets, so `FrameRouter` never sees 5.0 events
   (`RX 5.0 EVENT (undecoded)` in the log). The layout is now known (PACKET_TYPES.md).
4. **REPORT_VERSION_INFO is unsupported** on fw 50.43.1.0 but sent on every connect; firmware/hardware
   versions are available from Device Information (180A), which NOOP discovers but never reads.
5. **GET_CLOCK reply unused on 5.0.** The strap clock is ~15 s slow; history timestamps are stored
   uncorrected. `ClockCorrelation` is 4.0-only.
6. **Raw console logs are written to disk.** Manual pulls save console frames (containing a Bluetooth
   address) to `Documents/whoop5-history-*.jsonl` unredacted. Local only, but worth knowing before sharing.
7. **Stale comment:** `BLEManager` header says 5.0 command encoding is not implemented; it is.
8. **`dataRangeNewestUnix` / `isOffloadFrame`** use 4.0 offsets; they are only called on the 4.0 path (correct, but fragile).
9. Good: CRC gating before state updates, durable-before-ack ordering, destructive commands absent from
   `WhoopCommand`, 5.0 allowlist blocks 4.0-form alarm/haptics payloads.
