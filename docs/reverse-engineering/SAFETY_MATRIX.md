# Safety matrix

| Tier | Commands | Policy |
|---|---|---|
| **Auto (read-only)** | 1, 2, 7, 11, 26, 34, 80, 84, 98, 141, 151 (all gate R in Goose; 141 response redacted) | `Tools/ble_probe` may send these, one attempt each, ≥ 0.3 s apart, 7 s timeout, 25 s after PENDING. |
| **Reversible, per-experiment approval** | 3 toggle realtime HR, 14 HR broadcast, 63 R10/R11 realtime, 22 send historical data (starts a pull) | Bounded window (≤ 60 s), always send the "off" form afterwards, record pre/post state. Only 3 is in the probe's reversible list (`--toggle 3`, approved 2026-11-02 for E04); the probe always sends `[0]` before exiting. |
| **Restricted: data-affecting** | 23 HISTORICAL_DATA_RESULT | CONFIRMED to advance the strap's trim pointer (firmware log). Send only after the chunk is durably stored (NOOP's safe-trim order). Never from research tools. |
| **Restricted: state-changing, needs a written procedure + approval** | 10 set clock, 16, 19/79/122 haptics, 20 abort historical, 33 set read pointer, 66–69 alarms, 77/140 set name, 81/82, 96/97, 105–108, 123 select wrist, 124/125/139 Labrador | Behaviour or payloads unverified on 5.0, or persistent. |
| **Prohibited** | 25 force trim, 29 reboot, 32 power cycle, 36–38/83/142–144 firmware, 45 BLE DFU, 99 reset fuel gauge, 39/41/43 optical front-end writes, 52/53 DP type, 115–120 config/feature-flag key exchange and writes, 131 research packet, 153/154 persistent R20/R21 | Never sent. Unknown numbers (not in Goose's table) are never sent; no brute force. |
| **Never** | Writing descriptors other than CCCD, writing to fd4b0003–0007, sending malformed or CRC-invalid frames to the strap | — |

Data handling:

- Never export serial number, device/advertising name, hello (145) response bodies, session tokens, pairing
  material, or raw console hex (contains Bluetooth addresses).
- Biometric history stays out of committed fixtures.
- The probe shares the link with NOOP. Run it only when NOOP is not mid-pull: its log shows `History:` lines
  during a pull. Use seq 200–255 so responses are attributable.

## History acknowledgement policy (implemented 2026-11-02)

Facts: an ack (`23 [01]+end_data`) is what makes the strap send the next chunk (without it the strap re-sends
the same chunk: SUPPORTED, ryanbr/noop and NOOP's keep-on-strap behaviour), and it moves the strap's trim
pointer (CONFIRMED, firmware log). Whether trimmed records remain readable by another app is UNKNOWN; the
strap's oldest-record time keeps moving with a ~3-week rolling buffer regardless of acks (CONFIRMED, 2 samples).

So NOOP acks only what it has safely stored, and nothing else (`BLEManager.commitWhoop5HistoryChunk`):

1. Records and events of the chunk are committed in one SQLite transaction (`INSERT … ON CONFLICT DO NOTHING`,
   idempotent); the ack is sent only after that commit returns. A failed write ends the pull without an ack.
2. Frames NOOP cannot decode (type-47 version ≠ 0x12, e.g. 0x1a; type-52 IMU) are written verbatim and fsynced
   to `Application Support/OpenWhoop/undecoded-history/<day>.jsonl` before the ack. If that write fails, the
   chunk is not acked and the pull stops. (First live run, before the archive existed: the chunk was refused,
   as designed.)
3. The ack's `end_data` comes from that chunk's own CRC-checked END frame, and is sent only if the same pull
   (session id) is still active. A chunk finishing after its pull ended is saved but not acked.
4. One pull at a time (`whoop5HistoryActive` / range-wait guards); keep-alive never sends commands mid-pull.
5. "Never delete data from the strap" (`keepDataOnStrap`) sends no acks at all; each pull then stops after
   the first chunk. This remains the user's choice; the default is to ack after saving.
6. Crash-safe: an un-acked chunk is re-sent by the strap next pull; duplicates are absorbed by the database keys.

A local save is not a promise that the strap keeps its copy.

## Battery alerts (implemented 2026-11-02)

Low (< 20 %): fires once on the first fresh reading below 20 % (a crossing, or the first reading after launch or
connect); re-armed only after a reading ≥ 25 %; never while charging is confirmed; state persists across restarts.
Charging complete: only when a verified source reports charging AND 100 %; once per charging session. No WHOOP 5.0
charging source is verified yet (event 3's charging bit is SUPPORTED only), so this alert cannot fire today.
Readings older than 10 minutes never trigger an alert. Disabled alerts still advance state (no backlog later).

## Alarm and haptic commands (verified 2026-11-02, fw 50.43.1.0)

NOOP may send: SET_ALARM_TIME 66 only as `[4, 1, strap-time u32, 00 00, Goose default pattern]` (any other shape is
refused in `sendWhoop5`); GET 67 `[4,1]`; RUN 68 `[2,1]`; DISABLE-ALL 69 `[2,0xFF]` only when NOOP itself stored the
alarm (`alarm.ownsStrapAlarm`), so an alarm set by another app is never cleared; haptic 19 one-loop notify buzz and
STOP 122 `[1]`. Alarm id 0 is invalid. Every alarm write is verified by read-back before the UI says "on strap".
