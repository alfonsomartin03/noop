# WHOOP 5.0 transport and frame specification

Device: firmware `50.43.1.0`, hardware `WG50_r52`. Labels are defined in [README.md](README.md).

## 1. Transport

| Item | Finding | Label | Evidence |
|---|---|---|---|
| Custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` | CONFIRMED | E01 |
| Commands | written to `fd4b0002` (write and write-without-response both allowed); NOOP and the probe write with response | CONFIRMED | E01, E02 |
| Command responses | arrive on `fd4b0003` only | CONFIRMED | E02 (11 responses), app log |
| History, events, console logs | arrive on `fd4b0005` | CONFIRMED | 6 NOOP captures, 890 frames |
| `fd4b0007` | sends 244-byte fragments right after subscription, before the hello; content not captured | CONFIRMED (traffic) / SUPPORTED (Memfault diagnostics, per Asherlc docs) | app log 2026-11-02 00:03:19 |
| `fd4b0004` | no traffic in any capture | CONFIRMED (silence) | E01, E02, app logs |
| ATT MTU | 247 (firmware console: `mtu = 247`); notifications up to 244 bytes | CONFIRMED | console log 2026-10-13, app log |
| PHY | 2M both directions (`DM_PHY_UPDATE_IND … RX: 2, TX: 2`) | CONFIRMED | console log 2026-10-13 |
| Shared link | a second macOS process can attach to the connection NOOP holds (`retrieveConnectedPeripherals`), read, subscribe and send commands; both processes get every notification | CONFIRMED | E01, E02 (NOOP stayed connected) |
| Bonding | macOS bonds on the first protected access; firmware logs `BLE Bond failure` when the bond is stale | CONFIRMED (log text) | console log 2026-10-13 |

## 2. Frame envelope

```
off  size  field
 0    1    SOF 0xAA
 1    1    format, always 0x01
 2    2    declared length, u16 LE = padded payload length + 4
 4    2    direction: 00 01 app→strap, 01 00 strap→app
 6    2    CRC-16/MODBUS over bytes 0..5, u16 LE
 8    n    payload (record), zero-padded to a multiple of 4 on send
 8+n  4    CRC-32 (zlib) over the payload, u32 LE
total = declared length + 8
```

| Item | Label | Evidence |
|---|---|---|
| SOF, format, length, both CRCs | CONFIRMED | 890 captured frames + 21 E02 frames, 0 CRC failures |
| Bytes 4–5 = direction (`00 01` sent, `01 00` received) | CONFIRMED as observed values; the meaning "direction" is HYPOTHESIS | every TX frame `0001`, every RX frame `0100` |
| App frames padded to 4 bytes | CONFIRMED (strap accepts them) | E02 |
| Strap frames are also multiples of 4 (20, 24, 28, 32, 36, 48, 52, 56, 76, 84, 124) | CONFIRMED | captures |
| Little-endian multi-byte fields | CONFIRMED | lengths, CRCs, timestamps all decode LE |

## 3. Record (payload) header

```
payload[0]  packet type  (see PACKET_TYPES.md)
payload[1]  sequence     (sender's counter)
payload[2]  command / event / metadata kind (type-specific)
```

- Sent commands: `[35][seq][cmd][data…]`. The strap echoes the app's `seq`. CONFIRMED.
- Strap sequence: `payload[1]` of responses is the strap's own counter, +1 for every response it sends
  (76, 77, … 86 across E02). CONFIRMED.

## 4. Command response

```
payload[0] 36 (COMMAND_RESPONSE)
payload[1] strap sequence
payload[2] command being answered
payload[3] app sequence being answered
payload[4] result: 0 FAILURE, 1 SUCCESS, 2 PENDING, 3 UNSUPPORTED
payload[5…] body
```

Result names come from Goose (`commandResultName`); all four values were seen on this strap (E02).
`PENDING` is always followed by a second response with the final result (`GET_DATA_RANGE`, `GET_HELLO`).
Type 38 (puffin response) was never seen on this strap. Unbonded links are reported (Asherlc) to get a
type-38 error 1180; not reproduced here (UNKNOWN).

## 5. Integrity

- CRC-16/MODBUS: poly 0xA001 reflected, init 0xFFFF, no final XOR. CONFIRMED.
- CRC-32: zlib (reflected 0xEDB88320, init and final XOR 0xFFFFFFFF). CONFIRMED.
- No CRC failure in any capture so far, so the strap's response to a corrupt frame is UNKNOWN (and not
  tested: sending deliberately corrupt frames is not in the allowlist).

## 6. Reassembly

Each notify characteristic is an independent byte stream; frames can span notifications (244-byte
fragments) and one notification can carry several frames. Reassemble per characteristic: find `0xAA`,
read the length at bytes 2–3, wait for `length + 8` bytes. Reject lengths above 16 KiB and resync on the
next `0xAA`. Implemented in `Reassembler(family: .whoop5)` and `whoop5_decode.Reassembler`; covered by
tests (fragmented, concatenated, leading garbage, absurd length).

## 7. Timing (observed, not limits)

| Exchange | Latency | Evidence |
|---|---|---|
| Simple read-only command → final response | 30–62 ms | E02 |
| First command after attaching | 5.7 s (GET_CLOCK) | E02; also 10–12 s at the 00:03 app connect |
| GET_DATA_RANGE pending → final | < 5 ms apart, 2.6 s after send | E02 |
| History ack → ack response | 20–40 ms | app log 10:57 |
| Ack response → next HISTORY_START | ≤ 20 ms | app log 10:57 |
| History pull throughput | ~6.2 KB/s, 2553 records in 55 s | firmware `PullStats` console line |

Use ≥ 7 s per-command timeout and a 25 s grace after `PENDING` (Goose uses the same values).
