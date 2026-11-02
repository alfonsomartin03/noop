# Connection and sync state machine (WHOOP 5.0)

Reconstructed from NOOP's own logs (connects on 2026-11-01 18:44, 2026-11-02 00:03, 08:50) and the
probe sessions E01/E02. Timings are observed values.

```
IDLE ──scan fd4b0001──▶ DISCOVERED ──connect──▶ CONNECTED ──discover all──▶ DISCOVERED_GATT
   ▲                                                                        │ subscribe 0003/0004/0005/0007 (+2A19)
   │                                                                        ▼
   │                                                     SUBSCRIBED ──write CLIENT_HELLO (145, with response)──▶ HELLO_SENT
   │                                                                        │ write ack (bond done)
   │                                                                        ▼
   │                                       145 PENDING → 145 SUCCESS (2×124 B on 0003) ──▶ READY
   │                                                                        │
   │                READY ──GET_CLOCK, (REPORT_VERSION_INFO: unsupported), TOGGLE_GENERIC_HR_PROFILE[0]
   │                      ──GET_DATA_RANGE (PENDING→SUCCESS)──SEND_HISTORICAL_DATA──▶ SYNCING
   │                                                                        │
   │   SYNCING: START → ~60×type47 (+events, console) → END ──ack 23──▶ (next START …) ── COMPLETE ──▶ READY
   │                                                                        │ every 15 min (rate-limited) → SYNCING
   └──────────── disconnect (timeout / out of range) ◀──────────────────────┘ rescan after 3 s
```

| Transition | Trigger | Messages | Timeout / recovery | Mandatory? | Label |
|---|---|---|---|---|---|
| Scan | app start / disconnect | — | 10 s filtered scan, then name scan | yes | CONFIRMED |
| Shared attach | strap already connected to the Mac | `retrieveConnectedPeripherals` | — | — | CONFIRMED (probe) |
| Subscribe | after discovery | CCCD writes on 4 vendor chars | auth error → retry ×6 at 5 s | yes for responses | CONFIRMED |
| Hello | after subscribe | CLIENT_HELLO (cmd 145, data `01`) | 8 s watchdog | **UNKNOWN**: the probe's commands succeeded without sending its own hello, but NOOP had already sent one on that link | — |
| Hello responses | hello | 145 PENDING, 145 SUCCESS | ~20 ms after write ack | — | CONFIRMED |
| Firmware view of hello | — | console: `BLE_CMD: HELLO: Send hello packet` / `FG report received for Hello Packet` repeating every ~35 s while connected | — | — | CONFIRMED (console) |
| Clock read | READY | GET_CLOCK | first command after connect/attach waited 5.7–12 s | no | CONFIRMED |
| Range | before pull | GET_DATA_RANGE → PENDING → SUCCESS | — | no (Goose sends it first) | CONFIRMED |
| Pull | range ok | SEND_HISTORICAL_DATA (empty payload) → SUCCESS, START on 0005 | NOOP idle 20 s | yes | CONFIRMED |
| Chunk | END | ack `23 [01]+end_data` → SUCCESS in 20–40 ms → next START in ≤20 ms | — | yes to advance | CONFIRMED |
| No ack | END without ack | strap re-sends the same chunk; cursor frozen | — | — | SUPPORTED (ryanbr/noop; NOOP keep-on-strap note) |
| Complete | last chunk acked | METADATA COMPLETE; console `Historical Dump Complete`, `PullStats` | — | — | CONFIRMED |
| Idle | after pull | strap pushes nothing unprompted (45 s observed) | NOOP keep-alive 30 s, bounce after 120 s silence | — | CONFIRMED |
| Disconnect | link loss | CBError 6 "timed out unexpectedly"; firmware `Disconnected reason 0x13` (remote user terminated) on app-initiated drops | rescan in 3 s | — | CONFIRMED |
| Reconnect | — | full sequence again; `BLE_CONNECTION_DOWN/UP` events recorded and delivered in the next pull | — | — | CONFIRMED |

## NOOP's 5.0 sequence (as implemented 2026-11-02)

Connect → subscribe → CLIENT_HELLO → GET_CLOCK + GET_BATTERY_LEVEL (no REPORT_VERSION_INFO; versions from 180A)
→ keep-alive (60 s battery poll, 120 s silence bounce, realtime staleness) → pull: GET_CLOCK + GET_DATA_RANGE →
session target = range newest (fixed) → SEND_HISTORICAL_DATA → per END: save, then ack → COMPLETE → processing
(sleep / recovery / strain recompute) → complete. A range that never answers (10 s) starts the pull with
indeterminate progress. Periodic pulls every 15 min (timer jitter fixed: it used to skip every other tick).

## Not yet tested

- Whether commands work on a fresh link without CLIENT_HELLO (needs the probe to be the only client).
- Behaviour when two clients send commands at the same time (sequence numbers are per client, responses go to both).
- Interrupted pull resume: SUPPORTED by design (strap re-serves unacked chunk), not exercised here.
- Strap removal/replacement, walking and exercise scenarios (need the wearer; see EXPERIMENT_LOG next steps).
