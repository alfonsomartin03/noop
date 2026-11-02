# WHOOP 5.0 reverse engineering

Evidence-graded protocol reference for the owner's WHOOP 5.0 strap, built from live experiments and
passive captures. Every claim carries one of these labels:

| Label | Meaning |
|---|---|
| **CONFIRMED** | Reproduced against the owner's strap (live experiment, or a capture of the strap's own traffic). |
| **SUPPORTED** | Stated by one or more independent implementations, or seen in captures, but not reproduced here. |
| **HYPOTHESIS** | Plausible, not sufficiently tested. |
| **UNKNOWN** | Not established. |
| **UNSAFE** | Excluded from testing because of possible side effects. |

Device under test: model `5.0`, firmware `50.43.1.0`, hardware `WG50_r52` (Device Information, E01).

| File | Contents |
|---|---|
| [PROTOCOL_SPEC.md](PROTOCOL_SPEC.md) | Transport and frame format |
| [GATT_MAP.md](GATT_MAP.md) | Services, characteristics, descriptors |
| [COMMAND_REGISTRY.md](COMMAND_REGISTRY.md) | Every command number, tested or not |
| [PACKET_TYPES.md](PACKET_TYPES.md) | Packet types and decoded layouts |
| [STATE_MACHINE.md](STATE_MACHINE.md) | Connection and history-sync sequence |
| [SENSOR_STREAMS.md](SENSOR_STREAMS.md) | Which sensor data is reachable and how |
| [EXPERIMENT_LOG.md](EXPERIMENT_LOG.md) | Chronological evidence |
| [UNKNOWN_CAPABILITIES.md](UNKNOWN_CAPABILITIES.md) | Open questions |
| [SAFETY_MATRIX.md](SAFETY_MATRIX.md) | Allowed, restricted, prohibited operations |
| [TEST_RESULTS.md](TEST_RESULTS.md) | Repeatable tests and outcomes |
| [AUDIT.md](AUDIT.md) | Phase 1 audit of the app's BLE code |
| [whoop5_commands.json](whoop5_commands.json) | Machine-readable command registry |
| [captures/](captures/) | Redacted live captures (JSONL) |

## Tools

- `Tools/ble_probe` — read-only live probe (Swift, CoreBluetooth). Build with `Tools/ble_probe/make_app.sh`
  (an `.app` wrapper is needed so macOS grants it Bluetooth). Run:
  `open -W -n --stdout OUT.txt NOOPBLEProbe.app --args --seconds 30 --commands 11,34 --exp E03 --out /tmp/E03.jsonl`.
  It can only send the read-only allowlist in `main.swift`; any other number is refused at argument parsing.
  It attaches to the link NOOP already holds (macOS shares one connection between processes).
  `--toggle 3` (the only reversible entry) sends `[1]`, captures, and always sends `[0]` before exiting.
  Each rebuild gets a new ad-hoc signature, so macOS asks for Bluetooth permission again; the probe waits 90 s.
- `Tools/whoop_re/whoop5_decode.py` — standalone decoder for saved captures (no dependencies).
  `python3 Tools/whoop_re/whoop5_decode.py capture.jsonl [-v]`.
- `Tools/whoop_re/test_whoop5_decode.py` — tests over real captured frames in `Tools/whoop_re/fixtures/`.

## Redaction

Never written to captures or fixtures: serial number (`2A25`), advertising/device name, the hello (145)
response body, and console-log hex (console text is kept with Bluetooth addresses masked). Biometric
history records (type 47) are not committed as fixtures.
