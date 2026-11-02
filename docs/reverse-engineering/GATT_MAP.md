# GATT map (WHOOP 5.0, fw 50.43.1.0, hw WG50_r52)

Enumerated with `discoverServices(nil)` / `discoverCharacteristics(nil)` / `discoverDescriptors` in E01
and again in E02 (identical). CoreBluetooth hides Generic Access (1800) and Generic Attribute (1801), so
those are not listed.

| Service | Characteristic | Properties | Descriptors | Observed value / behaviour | Role | Label |
|---|---|---|---|---|---|---|
| 180A Device Information | 2A29 Manufacturer | read | — | `WHOOP Inc.` | identity | CONFIRMED |
| | 2A24 Model Number | read | — | `5.0 ` (trailing space) | identity | CONFIRMED |
| | 2A25 Serial Number | read | — | *redacted* | identity | CONFIRMED |
| | 2A26 Firmware Revision | read | — | `50.43.1.0` | identity | CONFIRMED |
| | 2A27 Hardware Revision | read | — | `WG50_r52` | identity | CONFIRMED |
| 180F Battery | 2A19 Battery Level | read, notify | 2902 | `20` (%), equals command 26 | battery | CONFIRMED |
| 180D Heart Rate | 2A37 HR Measurement | notify | 2902 | streams only while HR broadcast (cmd 14) is on | standard HR | CONFIRMED (app, 2026-10-21) |
| fd4b0001 WHOOP | fd4b0002 | write, write-without-response | — | command input | commands | CONFIRMED |
| | fd4b0003 | notify | 2902 | command responses | responses | CONFIRMED |
| | fd4b0004 | notify | 2902 | silent in every capture | events? (Asherlc name: EVENTS_FROM_STRAP) | UNKNOWN |
| | fd4b0005 | notify | 2902 | history, events, metadata, console logs | data | CONFIRMED |
| | fd4b0007 | notify | 2902 | 244-byte fragments at connect, before the hello | diagnostics (Asherlc: MEMFAULT; Goose: "debug") | SUPPORTED |

Not present on this unit: the "puffin" service `11500001-6215-11ee-8c99-0242ac120002` (Asherlc docs), the
2BED Battery Level Status characteristic (Goose parses it), 2A28 Software Revision. Absent from E01 and E02.

Security: no characteristic advertises the encryption-required property bits; the strap still enforces
pairing at ATT level (NOOP's retry path handles ATT errors 5/15 on first access). Read of every 180A
characteristic succeeded on the already-bonded link.

Descriptors: only 2902 (CCCD) exists, on every notify characteristic. CoreBluetooth reported value `1`
for all of them, including 2A37, which NOOP does not subscribe to. CoreBluetooth may report its own cached
state rather than the strap's, so this does not prove the HR broadcast was on (UNKNOWN).

Advertisement: NOOP's log shows the 5.0 service UUID in the advertisement and `connectable=1`; a strap
connected elsewhere stops advertising (CONFIRMED by NOOP's scan-fallback logs). Manufacturer data not yet
captured (the probe records it only when it has to scan).

## Differences from published research

- ryanbr/noop and Asherlc describe the same fd4b0002–0005 + 0007 set. Matches.
- Asherlc's second "puffin" service is absent: either a different hardware revision (MG?) or a different
  firmware. UNKNOWN.
- Firmware `50.43.1.0` is newer than the `50.38.1.0` quoted by ryanbr/noop for the hello payload, so offsets
  taken from that firmware need re-checking.
