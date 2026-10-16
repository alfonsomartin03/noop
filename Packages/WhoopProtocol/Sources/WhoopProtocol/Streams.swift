import Foundation

// MARK: - Decoded stream rows (the durable, compact local record)
// Phase E and WhoopStore depend on these EXACT shapes. ts is wall-clock unix seconds
// EXCEPT inside extractStreams' inputs; the structs themselves always carry wall-clock ts.

// The row types below are the compact, durable form of decoded data; ts is always wall-clock unix seconds.
public struct HRSample: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

public struct RRInterval: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let rrMs: Int
    public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
}

public struct WhoopEvent: Equatable, Codable {
    public let ts: Int          // real unix seconds (event RTC; never offset)
    public let kind: String
    public let payload: [String: ParsedValue]
    public init(ts: Int, kind: String, payload: [String: ParsedValue]) {
        self.ts = ts; self.kind = kind; self.payload = payload
    }
}

public struct BatterySample: Equatable, Codable {
    public let ts: Int          // unix seconds — event RTC for BATTERY_LEVEL events, else wallClockRef
    public let soc: Double?
    public let mv: Int?
    public let charging: Bool?  // only the BATTERY_LEVEL event reports this; nil otherwise
    public init(ts: Int, soc: Double?, mv: Int?, charging: Bool? = nil) {
        self.ts = ts; self.soc = soc; self.mv = mv; self.charging = charging
    }
}

// MARK: - type-47 HISTORICAL_DATA biometric rows. JSON keys MUST match
// biometric_streams_golden.json exactly (see extract_historical_streams).

public struct SpO2Sample: Equatable, Codable {
    public let ts: Int
    public let red: Int
    public let ir: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, red: Int, ir: Int, unit: String = "raw_adc") {
        self.ts = ts; self.red = red; self.ir = ir; self.unit = unit
    }
}

public struct SkinTempSample: Equatable, Codable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

public struct RespSample: Equatable, Codable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

public struct GravitySample: Equatable, Codable {
    public let ts: Int
    public let x: Double
    public let y: Double
    public let z: Double
    public let unit: String     // "g"
    public init(ts: Int, x: Double, y: Double, z: Double, unit: String = "g") {
        self.ts = ts; self.x = x; self.y = y; self.z = z; self.unit = unit
    }
}

// One bundle of every stream decoded from a batch of frames.
public struct Streams: Equatable, Codable {
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var spo2: [SpO2Sample]
    public var skinTemp: [SkinTempSample]
    public var resp: [RespSample]
    public var gravity: [GravitySample]
    public var events: [WhoopEvent]
    public var battery: [BatterySample]
    public init(hr: [HRSample] = [], rr: [RRInterval] = [],
                spo2: [SpO2Sample] = [], skinTemp: [SkinTempSample] = [],
                resp: [RespSample] = [], gravity: [GravitySample] = [],
                events: [WhoopEvent] = [], battery: [BatterySample] = []) {
        self.hr = hr; self.rr = rr
        self.spo2 = spo2; self.skinTemp = skinTemp; self.resp = resp; self.gravity = gravity
        self.events = events; self.battery = battery
    }

    private enum CodingKeys: String, CodingKey {
        case hr, rr, spo2, skinTemp = "skin_temp", resp, gravity, events, battery
    }

    // Custom decode so older fixtures (streams_golden.json / historical_golden.json) that
    // lack the new biometric keys still decode — missing arrays default to empty.
    // Missing keys decode as empty arrays so older fixtures still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hr = try c.decodeIfPresent([HRSample].self, forKey: .hr) ?? []
        rr = try c.decodeIfPresent([RRInterval].self, forKey: .rr) ?? []
        spo2 = try c.decodeIfPresent([SpO2Sample].self, forKey: .spo2) ?? []
        skinTemp = try c.decodeIfPresent([SkinTempSample].self, forKey: .skinTemp) ?? []
        resp = try c.decodeIfPresent([RespSample].self, forKey: .resp) ?? []
        gravity = try c.decodeIfPresent([GravitySample].self, forKey: .gravity) ?? []
        events = try c.decodeIfPresent([WhoopEvent].self, forKey: .events) ?? []
        battery = try c.decodeIfPresent([BatterySample].self, forKey: .battery) ?? []
    }
}

extension Streams { public static let empty = Streams() }

/// Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
/// Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of _to_wall.
// The strap's clock is arbitrary; one reference pair (device, wall) maps its timestamps to real time.
private func toWall(_ deviceTs: Int?, _ deviceClockRef: Int, _ wallClockRef: Int) -> Int? {
    guard let deviceTs = deviceTs else { return nil }
    return wallClockRef + (deviceTs - deviceClockRef)
}

/// Turn parsed frames into datastore rows. Port of interpreter.extract_streams.
///
/// HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also
/// carries an HR byte but streams alongside type-40 during raw collection, so routing both
/// would double-count HR for the same instants. CRC-failed and non-ok frames are skipped.
// Live path: HR/RR come only from REALTIME_DATA, since the raw packet repeats the same heartbeat and would double count.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams {
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "REALTIME_DATA":
            let ts = toWall(p["timestamp"]?.intValue, deviceClockRef, wallClockRef)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            // Unlike Python, drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
            guard let ts = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            // BATTERY_LEVEL events (every ~8 min) carry SoC/mV/charging + a real RTC ts →
            // the DENSE battery series (the post-hook decoded the fields).
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            continue
        }
    }
    return out
}

/// Append a BatterySample from a parsed frame's battery_pct/battery_mV/battery_charging
/// fields (no-op when neither soc nor mv is present). charging is a real Bool only when the
/// frame reported it (BATTERY_LEVEL events); command responses leave it nil.
// Battery rows are added only when a percentage or millivolt value was present.
func appendBattery(_ out: inout Streams, ts: Int, p: [String: ParsedValue]) {
    let soc = p["battery_pct"]?.doubleValue
    let mv = p["battery_mV"]?.intValue
    guard soc != nil || mv != nil else { return }
    let charging = p["battery_charging"]?.intValue.map { $0 != 0 }
    out.battery.append(BatterySample(ts: ts, soc: soc, mv: mv, charging: charging))
}

// MARK: - WHOOP 5.0 realtime heart-rate record

/// Decoded WHOOP 5.0 `REALTIME_DATA` (type 40) record.
///
/// LAYOUT IS A HYPOTHESIS, not a published spec: it is the verified WHOOP 4.0 realtime layout
/// (`timestamp u32 @6, subseconds u16 @10, heart_rate u8 @12, rr_count u8 @13, rr u16… @14`) shifted by the
/// 4-byte-longer 5.0 header, i.e. `@10 / @14 / @16 / @17 / @18`. It matches the observed 32-byte frames
/// (8 header + 20 payload + 4 CRC32) and must be confirmed against a real strap (timestamps should step ~1 s,
/// heart rate should be steady and plausible).
// 5.0 realtime layout is inferred from 4.0 shifted by the longer header, so verify against a real strap.
public struct Whoop5Realtime: Equatable, Sendable {
    public let timestamp: UInt32
    public let subseconds: UInt16
    public let heartRate: Int
    public let rr: [Int]          // milliseconds, zeros dropped
}

public func decodeWhoop5Realtime(_ frame: [UInt8]) -> Whoop5Realtime? {
    guard verifyFrame(frame, family: .whoop5).ok, frame.count >= 18, frame[8] == 40 else { return nil }
    let ts = UInt32(frame[10]) | UInt32(frame[11]) << 8 | UInt32(frame[12]) << 16 | UInt32(frame[13]) << 24
    let sub = UInt16(frame[14]) | UInt16(frame[15]) << 8
    let hr = Int(frame[16])
    let declaredEnd = (Int(frame[2]) | Int(frame[3]) << 8) + 8 - 4   // start of the CRC32 trailer
    let n = Int(frame[17])
    var rr: [Int] = []
    for i in 0..<n {
        let o = 18 + i * 2
        guard o + 1 < min(declaredEnd, frame.count) else { break }
        let v = Int(frame[o]) | Int(frame[o + 1]) << 8
        if v > 0 { rr.append(v) }
    }
    return Whoop5Realtime(timestamp: ts, subseconds: sub, heartRate: hr, rr: rr)
}

// MARK: - WHOOP 5.0 historical record (type 47)

/// One decoded WHOOP 5.0 stored record. The layout was derived from a real strap capture (30 consecutive records,
/// payload version byte 0x12) and cross-checked: timestamps step exactly 1 s, heart rate agrees with the R-R
/// intervals (60000/bpm ≈ rr), and the 3 floats form a unit-length gravity vector (|g| = 1.00).
///
/// Payload offsets (payload = frame[8 ..< len-4]):
///   0 type 47 · 1 version 0x12 · 3 counter · 7 timestamp u32 (unix s) · 14 heart_rate u8 · 15 rr_count u8
///   16 rr[i] u16 ms · 37/41/45 gravity x/y/z float32 (g)
/// Other bytes (optical / temperature / SpO2 candidates) are NOT decoded: their meaning is unverified.
public struct Whoop5HistoricalRecord: Equatable, Sendable {
    public let timestamp: Int
    public let heartRate: Int          // 0 when the strap had no reading
    public let rr: [Int]               // ms
    public let gravity: (x: Double, y: Double, z: Double)?

    public static func == (a: Self, b: Self) -> Bool {
        a.timestamp == b.timestamp && a.heartRate == b.heartRate && a.rr == b.rr
            && a.gravity?.x == b.gravity?.x && a.gravity?.y == b.gravity?.y && a.gravity?.z == b.gravity?.z
    }
}

// Sanity checks (plausible timestamp, RR range, unit-length gravity) reject misaligned or garbage records.
public func decodeWhoop5Historical(_ frame: [UInt8]) -> Whoop5HistoricalRecord? {
    guard frame.count >= 8 + 112 + 4, frame[8] == 47, frame[9] == 0x12,
          verifyFrame(frame, family: .whoop5).ok else { return nil }
    let p = Array(frame[8..<(frame.count - 4)])
    func u32(_ o: Int) -> Int { Int(p[o]) | Int(p[o+1]) << 8 | Int(p[o+2]) << 16 | Int(p[o+3]) << 24 }
    func f32(_ o: Int) -> Double { Double(Float(bitPattern: UInt32(truncatingIfNeeded: u32(o)))) }
    let ts = u32(7)
    guard (1_500_000_000...2_200_000_000).contains(ts) else { return nil }
    let hr = Int(p[14])
    var rr: [Int] = []
    for i in 0..<min(Int(p[15]), 4) {
        let v = Int(p[16 + i * 2]) | Int(p[17 + i * 2]) << 8
        if (250...3000).contains(v) { rr.append(v) }
    }
    let g = (f32(37), f32(41), f32(45))
    let norm = (g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot()
    let gravity = (0.7...1.3).contains(norm) ? g : nil
    return Whoop5HistoricalRecord(timestamp: ts, heartRate: hr, rr: rr, gravity: gravity)
}
