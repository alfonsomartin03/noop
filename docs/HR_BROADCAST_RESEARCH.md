# Heart-rate broadcast: what is known (researched 2026-10-15)

Goal: let NOOP switch the strap's standard Bluetooth heart-rate broadcast (service `0x180D`, char `0x2A37`) on and off, as the WHOOP app's "HR Broadcast" setting does.

## WHOOP 4.0 — documented, implemented
- Command number 14 (`TOGGLE_GENERIC_HR_PROFILE` in `whoop_protocol.json`), payload `[0x01]` on / `[0x00]` off, written to the command characteristic `61080002-…`. A public write-up ([reverse-engineering-whoop-post](https://mintlify.wiki/bWanShiTong/reverse-engineering-whoop-post/control/heart-rate-broadcast)) shows the on/off packets; their layout matches NOOP's own command framing.
- The strap does not report the current state; the WHOOP app resends "on" periodically. The strap emits `BLE_HR_PROFILE_ENABLED(24)` / `BLE_HR_PROFILE_DISABLED(25)` events when it changes.
- Status: implemented in NOOP (Live screen switch). Not yet tested on a 4.0 strap.

## WHOOP 5.0 / MG — NOT documented, NOT implemented
- Public sources checked ([Cracking the WHOOP 5.0 over Bluetooth](https://judes.club/writing/cracking-the-whoop-5-bluetooth-protocol/), [Rudra5417/whoop5-protocol](https://github.com/Rudra5417/whoop5-protocol), [b-nnett/goose](https://github.com/b-nnett/goose), [vishk23/noop](https://github.com/vishk23/noop)) give the 5.0 frame format but no HR-broadcast command. One source lists SET_CONFIG feature flags `make_hrfm_visible` and `hr_ch_switching`, with no description of what they do.
- Known 5.0 framing: `AA 01`, length u16 LE, two role bytes, CRC-16/MODBUS over the first 6 bytes, then `[0x23][seq][cmd][b3][payload]` padded to 4 bytes, then CRC-32. Commands must be written with response to `fd4b0002`. NOOP already builds these frames (`buildWhoop5CommandFrame`).
- Whether command 14 exists on 5.0 with a `[state]` payload is **unknown**. NOOP does not send it; a guessed command is not sent to a 5.0 strap.
- Sources disagree on whether the standard HR service works without broadcast on a 5.0. Our own strap showed "subscribed, no readings" with broadcast off.

## How to find out safely (owner's own strap)
1. Capture the phone's Bluetooth traffic while toggling "HR Broadcast" in the WHOOP app (Android: Developer options → Bluetooth HCI snoop log; iPhone: Apple Bluetooth logging profile + sysdiagnose).
2. Find writes to the 5.0 command characteristic around each toggle; validate header CRC-16 and trailer CRC-32 on every frame.
3. Confirm the pattern repeats for on and for off, record the anonymised frames as test fixtures, and only then add the exact command to the 5.0 allowlist.
4. If SET_CONFIG flags turn out to be involved, document them before sending anything.
