# Command registry (WHOOP 5.0)

Generated from `whoop5_commands.json`. Numbers and names come from Goose's 5.0 table
(`b-nnett/goose` `Rust/core/src/commands.rs`, gate R = read-only, U = user-visible change, C = critical),
except 99 (RESET_FUEL_GAUGE), which only appears in NOOP's 4.0 enum. The **Observed** columns are from this
strap (fw 50.43.1.0); blank means never sent. Command frames are `[35][seq][cmd][data…]` written to fd4b0002.

Wire differences from 4.0 documented by Goose and not yet tested here: alarm commands 66–69 take
`[4, alarmId, …]` / `[2, alarmId]` forms, haptics use 19 not 79, IMU/optical toggles take `[1, on]`.

| # | Name | Goose gate | Sent | Observed result | Resp. bytes | Label | Safety | Notes |
|---:|---|---|---|---|---:|---|---|---|
| 1 | LINK_VALID | R | [] | SUCCESS | 32 | CONFIRMED | auto (read-only) | body = ASCII 'There it is.' + zero padding (E02). |
| 2 | GET_MAX_PROTOCOL_VERSION | R | [] | UNSUPPORTED | 20 | CONFIRMED | auto (read-only) | result 3 on fw 50.43.1.0 (E02). |
| 3 | TOGGLE_REALTIME_HR | U | [1] then [0] | SUCCESS | 20 | CONFIRMED | reversible, approval per experiment | E04: [1] starts 1 Hz type-40 on fd4b0005 within 1 s; [0] stops it (0 frames in the next 23 s). 34 ms responses. |
| 7 | REPORT_VERSION_INFO | R | [] | UNSUPPORTED | 20 | CONFIRMED | auto (read-only) | result 3 (E02 and every NOOP connect). Firmware version is in DIS 2A26 instead. |
| 10 | SET_CLOCK | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval | 8-byte [sec u32][subsec u32, 1/32768 s] (Goose + 4.0 docs). NOOP never sends it on 5.0; strap clock runs ~15 s slow. |
| 11 | GET_CLOCK | R | [] | SUCCESS | 28 | CONFIRMED | auto (read-only) | body: unix sec u32 @0, subsec u32 @4 (1/32768 s per Goose), 3 zero bytes. 5.7 s latency as first command after attach (E02). |
| 14 | TOGGLE_GENERIC_HR_PROFILE | U | [0]/[1] | SUCCESS | 20 | CONFIRMED | reversible, approval per experiment | HR broadcast off/on; on starts 2A37 within seconds (NOOP, 2026-10-21); off logs event 25 on next history pull. |
| 16 | TOGGLE_R7_DATA_COLLECTION | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 19 | RUN_HAPTIC_PATTERN_MAVERICK | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 20 | ABORT_HISTORICAL_TRANSMITS | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 22 | SEND_HISTORICAL_DATA | U | [] | SUCCESS | 20 | CONFIRMED | reversible, approval per experiment | starts history: START/records/END… then COMPLETE on fd4b0005 (app logs). |
| 23 | HISTORICAL_DATA_RESULT | U | [01]+end_data(8) | SUCCESS | 20 | CONFIRMED | restricted: deletes from strap (trim); only after data is durably stored | ack of HISTORY_END. Firmware then logs 'History burst success. Trim: block:page', i.e. it advances the strap's trim pointer. Without it the strap re-sends the same chunk. |
| 25 | FORCE_TRIM | C |  |  |  | UNSAFE | prohibited |  |
| 26 | GET_BATTERY_LEVEL | R | [] | SUCCESS | 24 | CONFIRMED | auto (read-only) | body[0] = battery % (20, equal to 2A19), 6 zero bytes (E02). |
| 29 | REBOOT_STRAP | C |  |  |  | UNSAFE | prohibited |  |
| 32 | POWER_CYCLE_STRAP | C |  |  |  | UNSAFE | prohibited |  |
| 33 | SET_READ_POINTER | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 34 | GET_DATA_RANGE | R | [] | PENDING→SUCCESS | 84 | CONFIRMED | auto (read-only) | PENDING (20 B) then 84 B body; layout in PACKET_TYPES.md (E02, app logs). |
| 35 | GET_HELLO_HARVARD | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 36 | START_FIRMWARE_LOAD | C |  |  |  | UNSAFE | prohibited |  |
| 37 | LOAD_FIRMWARE_DATA | C |  |  |  | UNSAFE | prohibited |  |
| 38 | PROCESS_FIRMWARE_IMAGE | C |  |  |  | UNSAFE | prohibited |  |
| 39 | SET_LED_DRIVE | C |  |  |  | UNSAFE | prohibited |  |
| 40 | GET_LED_DRIVE | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 41 | SET_TIA_GAIN | C |  |  |  | UNSAFE | prohibited |  |
| 42 | GET_TIA_GAIN | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 43 | SET_BIAS_OFFSET | C |  |  |  | UNSAFE | prohibited |  |
| 44 | GET_BIAS_OFFSET | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 45 | ENTER_BLE_DFU | C |  |  |  | UNSAFE | prohibited |  |
| 52 | SET_DP_TYPE | C |  |  |  | UNSAFE | prohibited |  |
| 53 | FORCE_DP_TYPE | C |  |  |  | UNSAFE | prohibited |  |
| 63 | SEND_R10_R11_REALTIME | U |  |  |  | SUPPORTED | reversible, approval per experiment | Goose sends [1]/[0]. Not exercised on 5.0 here. |
| 66 | SET_ALARM_TIME | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 67 | GET_ALARM_TIME | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 68 | RUN_ALARM | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 69 | DISABLE_ALARM | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 76 | GET_ADVERTISING_NAME_HARVARD | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 77 | SET_ADVERTISING_NAME_HARVARD | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 79 | RUN_HAPTICS_PATTERN | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 80 | GET_ALL_HAPTICS_PATTERN | R | [] | UNSUPPORTED | 20 | CONFIRMED | auto (read-only) | result 3 (E02). |
| 81 | START_RAW_DATA | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 82 | STOP_RAW_DATA | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 83 | VERIFY_FIRMWARE_IMAGE | C |  |  |  | UNSAFE | prohibited |  |
| 84 | GET_BODY_LOCATION_AND_STATUS | R | [] | FAILURE | 24 | CONFIRMED | auto (read-only) | result 0, body 01 00…; payload probably needs arguments (E02). |
| 96 | ENTER_HIGH_FREQ_SYNC | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 97 | EXIT_HIGH_FREQ_SYNC | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval | NOOP's 4.0 path sends [0]; blocked on 5.0 by NOOP's allowlist. |
| 98 | GET_EXTENDED_BATTERY_INFO | R | [] | UNSUPPORTED | 20 | CONFIRMED | auto (read-only) | result 3 (E02). |
| 99 | RESET_FUEL_GAUGE | — |  |  |  | UNSAFE | prohibited |  |
| 105 | TOGGLE_IMU_MODE_HISTORICAL | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 106 | TOGGLE_IMU_MODE | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 107 | ENABLE_OPTICAL_DATA | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 108 | TOGGLE_OPTICAL_MODE | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 115 | START_DEVICE_CONFIG_KEY_EXCHANGE | C |  |  |  | UNSAFE | prohibited |  |
| 116 | SEND_NEXT_DEVICE_CONFIG | C |  |  |  | UNSAFE | prohibited |  |
| 117 | START_FEATURE_FLAG_KEY_EXCHANGE | C |  |  |  | UNSAFE | prohibited |  |
| 118 | SEND_NEXT_FEATURE_FLAG | C |  |  |  | UNSAFE | prohibited |  |
| 119 | SET_DEVICE_CONFIG_VALUE | C |  |  |  | UNSAFE | prohibited |  |
| 120 | SET_FEATURE_FLAG_VALUE | C |  |  |  | UNSAFE | prohibited |  |
| 121 | GET_DEVICE_CONFIG_VALUE | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 122 | STOP_HAPTICS | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 123 | SELECT_WRIST | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 124 | TOGGLE_LABRADOR_DATA_GENERATION | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 125 | TOGGLE_LABRADOR_RAW_SAVE | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 128 | GET_FEATURE_FLAG_VALUE | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 131 | SET_RESEARCH_PACKET | C |  |  |  | UNSAFE | prohibited |  |
| 132 | GET_RESEARCH_PACKET | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 139 | TOGGLE_LABRADOR_FILTERED | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 140 | SET_ADVERTISING_NAME | U |  |  |  | SUPPORTED | restricted: needs reviewed procedure + approval |  |
| 141 | GET_ADVERTISING_NAME | R |  |  |  | SUPPORTED | auto (read-only) |  |
| 142 | START_FIRMWARE_LOAD_NEW | C |  |  |  | UNSAFE | prohibited |  |
| 143 | LOAD_FIRMWARE_DATA_NEW | C |  |  |  | UNSAFE | prohibited |  |
| 144 | PROCESS_FIRMWARE_IMAGE_NEW | C |  |  |  | UNSAFE | prohibited |  |
| 145 | GET_HELLO | R | [01] | PENDING→SUCCESS | 124 | CONFIRMED | auto (read-only) | static CLIENT_HELLO; two 124-byte responses (result 2 then 1). Body holds identity/session data: redacted, never logged. |
| 151 | GET_BATTERY_PACK_INFO | R | [] | FAILURE | 48 | CONFIRMED | auto (read-only) | result 0, body 01 + 30 zero bytes; no battery pack attached (E02). |
| 153 | TOGGLE_PERSISTENT_R20 | C |  |  |  | UNSAFE | prohibited |  |
| 154 | TOGGLE_PERSISTENT_R21 | C |  |  |  | UNSAFE | prohibited |  |
