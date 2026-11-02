import Foundation

// Typed WHOOP 5.0 message decoders. Every layout here is CONFIRMED on the owner's strap
// (fw 50.43.1.0) — see docs/reverse-engineering/PACKET_TYPES.md. Offsets are PAYLOAD offsets
// (payload = frame[8 ..< len-4]); nothing outside this file should index 5.0 frames by hand.

/// Why a 5.0 frame could not be decoded as the requested message.
public enum Whoop5DecodeError: Error, Equatable {
    case badFrame              // envelope / CRC failure
    case wrongType(UInt8)      // a different packet type
    case wrongCommand(UInt8)   // a response to a different command
    case notSuccess(Whoop5Result)
    case truncated(need: Int, have: Int)
    case implausible(String)   // a field outside its physically possible range
}

/// The validated payload of a 5.0 frame (bytes between the header CRC and the CRC-32 trailer).
public func whoop5Payload(_ frame: [UInt8]) -> [UInt8]? {
    guard verifyFrame(frame, family: .whoop5).ok, frame.count >= 12 else { return nil }
    let end = (Int(frame[2]) | Int(frame[3]) << 8) + 8 - 4
    return Array(frame[8..<end])
}

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> Int {
    Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
}

/// Plausible strap wall-clock seconds (2020-01-01 … 2040-01-01). Anything else is a misread, not a time.
public func isPlausibleUnix(_ t: Int) -> Bool { (1_577_836_800...2_208_988_800).contains(t) }

// MARK: - Command responses

/// Result byte of a 5.0 COMMAND_RESPONSE. Names from Goose; all four values observed on the strap.
public enum Whoop5Result: Equatable, Sendable {
    case failure, success, pending, unsupported
    case other(UInt8)
    init(_ b: UInt8) {
        switch b {
        case 0: self = .failure
        case 1: self = .success
        case 2: self = .pending
        case 3: self = .unsupported
        default: self = .other(b)
        }
    }
}

/// `[36][strap seq][cmd][app seq][result][body…]`.
public struct Whoop5CommandResponse: Equatable, Sendable {
    public let command: UInt8
    public let appSeq: UInt8
    public let strapSeq: UInt8
    public let result: Whoop5Result
    public let body: [UInt8]
    /// PENDING is always followed by a second response carrying the final result.
    public var isFinal: Bool { result != .pending }

    public static func decode(_ frame: [UInt8]) -> Whoop5CommandResponse? {
        guard let p = whoop5Payload(frame), p.count >= 5, p[0] == 36 || p[0] == 38 else { return nil }
        return Whoop5CommandResponse(command: p[2], appSeq: p[3], strapSeq: p[1], result: Whoop5Result(p[4]),
                                     body: Array(p[5...]))
    }
}

/// GET_CLOCK (11) reply body: `[unix sec u32][subsec u32, 1/32768 s][00 00 00]`.
public struct Whoop5Clock: Equatable, Sendable {
    public let unix: Int
    public let subseconds: Int
    /// Strap time in seconds, including the sub-second part.
    public var seconds: Double { Double(unix) + Double(subseconds) / 32768.0 }

    public static func decode(_ r: Whoop5CommandResponse) -> Result<Whoop5Clock, Whoop5DecodeError> {
        guard r.command == 11 else { return .failure(.wrongCommand(r.command)) }
        guard r.result == .success else { return .failure(.notSuccess(r.result)) }
        guard r.body.count >= 8 else { return .failure(.truncated(need: 8, have: r.body.count)) }
        let t = le32(r.body, 0), sub = le32(r.body, 4)
        guard isPlausibleUnix(t) else { return .failure(.implausible("clock \(t)")) }
        guard sub < 32768 else { return .failure(.implausible("subseconds \(sub)")) }
        return .success(Whoop5Clock(unix: t, subseconds: sub))
    }
}

/// GET_BATTERY_LEVEL (26) reply: percent in body[0] (equalled the standard 0x2A19 value on the strap).
public func whoop5BatteryPercent(_ r: Whoop5CommandResponse) -> Int? {
    guard r.command == 26, r.result == .success, let b = r.body.first, b <= 100 else { return nil }
    return Int(b)
}

/// GET_DATA_RANGE (34) final reply (67-byte body). Field meanings CONFIRMED on two samples (E02, E04):
/// the trim pointer equalled the last ack sent, +41 the last record of the previous pull, +57 the newest record.
public struct Whoop5DataRange: Equatable, Sendable {
    /// Strap's trim pointer (page, block) — what the last HISTORICAL_DATA_RESULT ack moved it to.
    public let trimPage: Int
    public let trimBlock: Int
    /// Highest page counter the strap reports (HYPOTHESIS: its write position). Kept for diagnostics only.
    public let headPage: Int
    /// Oldest record the strap still holds (a rolling ~3-week buffer; moves forward by itself).
    public let oldestUnix: Int
    /// Time of the last record handed over in an acknowledged pull.
    public let lastSyncedUnix: Int
    /// Newest record the strap holds (≈ strap clock now). The pull target.
    public let newestUnix: Int

    public static let bodyLength = 65   // fields up to +61; observed bodies are 67 bytes

    public static func decode(_ r: Whoop5CommandResponse) -> Result<Whoop5DataRange, Whoop5DecodeError> {
        guard r.command == 34 else { return .failure(.wrongCommand(r.command)) }
        guard r.result == .success else { return .failure(.notSuccess(r.result)) }
        let b = r.body
        guard b.count >= bodyLength else { return .failure(.truncated(need: bodyLength, have: b.count)) }
        let oldest = le32(b, 33), synced = le32(b, 41), newest = le32(b, 57)
        for (name, t) in [("oldest", oldest), ("lastSynced", synced), ("newest", newest)] where !isPlausibleUnix(t) {
            return .failure(.implausible("\(name) \(t)"))
        }
        guard oldest <= newest else { return .failure(.implausible("oldest \(oldest) after newest \(newest)")) }
        return .success(Whoop5DataRange(trimPage: le32(b, 5), trimBlock: le32(b, 17), headPage: le32(b, 1),
                                        oldestUnix: oldest, lastSyncedUnix: synced, newestUnix: newest))
    }
}

// MARK: - History metadata

/// METADATA (49): `[49][seq][kind u8][unix u32 @3]…`; HISTORY_END carries the 8 bytes the ack must echo at
/// payload[13..<21]. CONFIRMED on 51 captured frames. Type 56 (puffin metadata) was never seen on this strap;
/// Goose reads its kind as u16 @2 — decoded that way, without a time.
public enum Whoop5HistoryMeta: Equatable, Sendable {
    case start(unix: Int?)
    case end(unix: Int?, endData: [UInt8])
    case complete
    case other(kind: Int)

    public static func decode(_ frame: [UInt8]) -> Whoop5HistoryMeta? {
        guard let p = whoop5Payload(frame), p.count >= 4, p[0] == 49 || p[0] == 56 else { return nil }
        let isPuffin = p[0] == 56
        let kind = isPuffin ? le16(p, 2) : Int(p[2])
        let unix: Int? = !isPuffin && p.count >= 7 ? le32(p, 3) : nil
        switch kind {
        case 1: return .start(unix: unix)
        case 2: return p.count >= 21 ? .end(unix: unix, endData: Array(p[13..<21])) : nil
        case 3: return .complete
        default: return .other(kind: kind)
        }
    }

    /// Trim page / block an END would move the strap to once acked (end_data = page u32, block u32).
    public var trimPosition: (page: Int, block: Int)? {
        guard case .end(_, let d) = self else { return nil }
        return (le32(d, 0), le32(d, 4))
    }
}

// MARK: - Events

/// WHOOP 5.0 event numbers seen on the strap. Names come from the shared 4.0/5.0 enum; only the ones
/// observed on 5.0 are listed. Anything else is kept as `.unknown` with its raw body.
public enum Whoop5EventKind: Equatable, Sendable {
    case batteryLevel                // 3
    case chargingOn                  // 7 CHARGING_ON (EventNumber table; not yet captured on a 5.0)
    case chargingOff                 // 8 CHARGING_OFF
    case batteryPackConnected        // 21 BATTERY_PACK_CONNECTED
    case batteryPackRemoved          // 22 BATTERY_PACK_REMOVED
    case connectionUp                // 11 BLE_CONNECTION_UP
    case connectionDown              // 12 BLE_CONNECTION_DOWN
    case hrProfileEnabled            // 24 BLE_HR_PROFILE_ENABLED
    case hrProfileDisabled           // 25 BLE_HR_PROFILE_DISABLED
    case strapConditionReport        // 29 (body meaning UNKNOWN; sent every 10 min)
    case realtimeHROn                // 33 BLE_REALTIME_HR_ON — CONFIRMED: matched both TOGGLE_REALTIME_HR [1] sends
    case realtimeHROff               // 34 BLE_REALTIME_HR_OFF — CONFIRMED: matched both [0] sends
    case extendedBatteryInformation  // 63 (name SUPPORTED; arrives with event 3)
    case doubleTap                   // 14 — CONFIRMED: arrived as the wearer stopped a buzz (H02b)
    case alarmSet                    // 56 STRAP_DRIVEN_ALARM_SET — CONFIRMED (H02b, H04): body [rev 3][id][sec u32][subsec u16][pattern]
    case strapAlarmExecuted          // 57 STRAP_DRIVEN_ALARM_EXECUTED (SUPPORTED, Goose)
    case appAlarmExecuted            // 58 APP_DRIVEN_ALARM_EXECUTED — CONFIRMED after RUN_ALARM
    case alarmDisabled               // 59 STRAP_DRIVEN_ALARM_DISABLED (SUPPORTED, Goose)
    case hapticsFired                // 60 — CONFIRMED (H07, H02b)
    case hapticsTerminated           // 100 — CONFIRMED; body[1]: 0 expired, 2 user terminated (Goose names)
    case unknown(Int)

    public init(_ n: Int) {
        switch n {
        case 3: self = .batteryLevel
        case 7: self = .chargingOn
        case 8: self = .chargingOff
        case 21: self = .batteryPackConnected
        case 22: self = .batteryPackRemoved
        case 11: self = .connectionUp
        case 12: self = .connectionDown
        case 24: self = .hrProfileEnabled
        case 25: self = .hrProfileDisabled
        case 29: self = .strapConditionReport
        case 33: self = .realtimeHROn
        case 34: self = .realtimeHROff
        case 63: self = .extendedBatteryInformation
        case 14: self = .doubleTap
        case 56: self = .alarmSet
        case 57: self = .strapAlarmExecuted
        case 58: self = .appAlarmExecuted
        case 59: self = .alarmDisabled
        case 60: self = .hapticsFired
        case 100: self = .hapticsTerminated
        default: self = .unknown(n)
        }
    }

    public var name: String {
        switch self {
        case .batteryLevel: return "BATTERY_LEVEL"
        case .chargingOn: return "CHARGING_ON"
        case .chargingOff: return "CHARGING_OFF"
        case .batteryPackConnected: return "BATTERY_PACK_CONNECTED"
        case .batteryPackRemoved: return "BATTERY_PACK_REMOVED"
        case .connectionUp: return "BLE_CONNECTION_UP"
        case .connectionDown: return "BLE_CONNECTION_DOWN"
        case .hrProfileEnabled: return "BLE_HR_PROFILE_ENABLED"
        case .hrProfileDisabled: return "BLE_HR_PROFILE_DISABLED"
        case .strapConditionReport: return "STRAP_CONDITION_REPORT"
        case .realtimeHROn: return "BLE_REALTIME_HR_ON"
        case .realtimeHROff: return "BLE_REALTIME_HR_OFF"
        case .extendedBatteryInformation: return "EXTENDED_BATTERY_INFORMATION"
        case .doubleTap: return "DOUBLE_TAP"
        case .alarmSet: return "STRAP_DRIVEN_ALARM_SET"
        case .strapAlarmExecuted: return "STRAP_DRIVEN_ALARM_EXECUTED"
        case .appAlarmExecuted: return "APP_DRIVEN_ALARM_EXECUTED"
        case .alarmDisabled: return "STRAP_DRIVEN_ALARM_DISABLED"
        case .hapticsFired: return "HAPTICS_FIRED"
        case .hapticsTerminated: return "HAPTICS_TERMINATED"
        case .unknown(let n): return "EVENT_\(n)"
        }
    }
}

/// `[48][seq][event u16][unix u32][subsec u16][body_len u16][body…]` — length checked on all 26 captured events.
public struct Whoop5Event: Equatable, Sendable {
    public let number: Int
    public let kind: Whoop5EventKind
    public let unix: Int
    public let subseconds: Int
    public let body: [UInt8]

    public static func decode(_ frame: [UInt8]) -> Result<Whoop5Event, Whoop5DecodeError> {
        guard let p = whoop5Payload(frame) else { return .failure(.badFrame) }
        guard p.first == 48 else { return .failure(.wrongType(p.first ?? 0)) }
        guard p.count >= 12 else { return .failure(.truncated(need: 12, have: p.count)) }
        let n = le16(p, 2), len = le16(p, 10)
        guard 12 + len <= p.count else { return .failure(.truncated(need: 12 + len, have: p.count)) }
        return .success(Whoop5Event(number: n, kind: Whoop5EventKind(n), unix: le32(p, 4), subseconds: le16(p, 8),
                                    body: Array(p[12..<(12 + len)])))
    }

    /// BATTERY_LEVEL body (layout from ryanbr/noop): soc u16/10 @1 and mV u16 @5 CONFIRMED on one sample (20.0 % =
    /// 0x2A19, 3706 mV); the charging bit @10 read 0 while not charging and is unproven until seen while charging,
    /// so nothing user-facing uses it.
    public var batteryCandidate: (socPercent: Double, millivolts: Int, charging: Bool)? {
        guard kind == .batteryLevel, body.count >= 11 else { return nil }
        let soc = Double(le16(body, 1)) / 10, mv = le16(body, 5)
        guard (0...100).contains(soc), (2500...5000).contains(mv) else { return nil }
        return (soc, mv, body[10] & 1 == 1)
    }
}

// MARK: - Charging (WHOOP 5.0)

/// What the strap itself reports about charging. NOOP shows "charging" only from these, never from a rising percentage.
public enum Whoop5Charging {
    /// Charging events: CHARGING_ON/OFF and BATTERY_PACK_CONNECTED/REMOVED (the pack is the charger). nil for others.
    public static func signal(_ kind: Whoop5EventKind) -> Bool? {
        switch kind {
        case .chargingOn, .batteryPackConnected: return true
        case .chargingOff, .batteryPackRemoved: return false
        default: return nil
        }
    }

    public static let packInfoCommand: UInt8 = 151

    /// GET_BATTERY_PACK_INFO (151) reply: is a battery pack attached? CONFIRMED detached form (E02): result FAILURE with
    /// body `01` + zero bytes. Any SUCCESS is read as attached (the attached body layout is not decoded). nil = no answer.
    public static func packAttached(command: UInt8, result: Whoop5Result, body: [UInt8]) -> Bool? {
        guard command == packInfoCommand else { return nil }
        switch result {
        case .success: return true
        case .failure where body.first == 1 && body.dropFirst().allSatisfy({ $0 == 0 }): return false
        default: return nil
        }
    }

    public static func packAttached(_ r: Whoop5CommandResponse) -> Bool? {
        packAttached(command: r.command, result: r.result, body: r.body)
    }
}

// MARK: - Alarms and haptics (WHOOP 5.0)

/// 5.0 alarm / haptic command payloads, as verified on fw 50.43.1.0 (docs/reverse-engineering/ALARM_CAPABILITIES.md).
/// Alarm id 0 is rejected (INVALID_ALARM_ID); id 1 is accepted. Times are STRAP clock seconds.
public enum Whoop5Alarm {
    public static let alarmID: UInt8 = 1
    /// Goose's default alarm pattern: waveform [47, 152, 0…], loop control 0, 7 loops, 30 s. Accepted (VALID_PATTERN).
    public static let defaultPattern: [UInt8] = [47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30]
    /// Asherlc's one-loop notify buzz for command 19 (CONFIRMED: SUCCESSFUL_PLAY + HAPTICS_FIRED).
    public static let notifyBuzz: [UInt8] = [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]

    public static func setPayload(strapSeconds: UInt32, id: UInt8 = alarmID) -> [UInt8] {
        [4, id, UInt8(strapSeconds & 0xFF), UInt8(strapSeconds >> 8 & 0xFF), UInt8(strapSeconds >> 16 & 0xFF),
         UInt8(strapSeconds >> 24 & 0xFF), 0, 0] + defaultPattern
    }
    public static func getPayload(id: UInt8 = alarmID) -> [UInt8] { [4, id] }
    public static func runPayload(id: UInt8 = alarmID) -> [UInt8] { [2, id] }
    public static let disableAllPayload: [UInt8] = [2, 0xFF]

    /// Status byte of a 66/67/68/69/19/122 response body (body[1]); names from Goose.
    public enum Status: UInt8, Sendable {
        case unknown = 0, validPattern, invalidEffect, invalidLoops, invalidDuration, successfulPlay, hapticsFailure,
             hapticsTimeout, hapticsBusy, hapticsStopped, invalidAlarmTime, invalidAlarmID
    }
    public static func status(_ r: Whoop5CommandResponse) -> Status? {
        r.body.count >= 2 ? Status(rawValue: r.body[1]) : nil
    }
    /// GET_ALARM_TIME read-back: the stored strap time, or nil when the slot is empty (time 0 / failure).
    public static func storedTime(_ r: Whoop5CommandResponse) -> UInt32? {
        guard r.command == 67, r.result == .success, r.body.count >= 6 else { return nil }
        let t = UInt32(r.body[2]) | UInt32(r.body[3]) << 8 | UInt32(r.body[4]) << 16 | UInt32(r.body[5]) << 24
        return t == 0 ? nil : t
    }
}
