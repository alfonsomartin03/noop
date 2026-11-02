# Test results

## Offline (no device)

| Suite | Command | Result (2026-11-02) |
|---|---|---|
| Python decoder over real 5.0 frames | `python3 -m unittest Tools/whoop_re/test_whoop5_decode.py` | 22 passed |
| Swift protocol package (incl. new 5.0 decoders, clock, redaction, sync session, battery policy) | `cd Packages/WhoopProtocol && swift test` | 124 passed, 0 failed |
| StrandAnalytics | `cd Packages/StrandAnalytics && swift test` | 325 passed |
| WhoopStore | `cd Packages/WhoopStore && swift test` | 105 passed |
| App tests | `xcodebuild -scheme Strand test` | passed |
| Capture sweep | `python3 Tools/whoop_re/whoop5_decode.py <6 NOOP captures>` | 890 frames, 0 CRC/framing failures |

The Python tests cover: CRC-16 + CRC-32 on 31 real frames; the builder reproduces the static hello and a
probe-built command byte-for-byte (Python and Swift framing agree); truncated, too-short, trailing-bytes,
bad SOF, bad declared length; payload corruption (CRC-32 only fails) and header corruption (CRC-16 fails);
fragmented + concatenated streams with leading garbage; partial frame; absurd length resync; response,
battery, clock, LINK_VALID, data-range and HISTORY_END decoding; event body length; hello redaction.

## Live (owner's strap)

| Test | Repeatable via | Outcome |
|---|---|---|
| E01 GATT enumeration + DIS/battery reads | `ble_probe --seconds 20` | pass, map stable across E01/E02 |
| E02 read-only matrix | `ble_probe --commands 11,34,7,26,98,2,1,84,80,151` | 10/10 answered, 0 timeouts; see EXPERIMENT_LOG |
| E04 realtime HR on/off | `ble_probe --commands 11,34,26 --toggle 3 --seconds 50` | on → 42 frames at 1 Hz; off → 0 frames (E04b, 15 s) |
| E04c realtime vs stored HR | `python3` comparison of E04 frames vs `hrSample` | 42/42 equal at lag 0 |
| E08 new NOOP build live | three connects 12:07–12:15 | see EXPERIMENT_LOG E08: all checks passed after the archive fix |
| Link sharing with NOOP | E01/E02/E04 | NOOP stayed connected and kept working |

## Robustness items not yet exercised

Unexpected disconnect mid-pull, Bluetooth off/on, app restart mid-pull, low battery (< 10 %),
simultaneous commands from two clients. Duplicate records are handled by the DB unique key and
`historySeenTs` (code review), not tested live.
