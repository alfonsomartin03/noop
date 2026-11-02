import Foundation
import CoreBluetooth
import WhoopProtocol

// WHOOP 5.0 read-only BLE probe.
//
//   swift run ble_probe [--seconds N] [--commands 11,34,...] [--hello] [--exp ID] [--out FILE]
//
// What it does: finds the strap (shares the link if NOOP already holds it), enumerates every service,
// characteristic and descriptor, reads the standard read-only characteristics (Device Information,
// Battery), subscribes to the fd4b notify channels, optionally sends commands from READ_ONLY_ALLOWLIST,
// and logs every frame as JSONL. It never writes anything except allowlisted command frames (and the
// static CLIENT_HELLO when --hello is passed), never acks history, never writes descriptors.
//
// Redaction: serial number, system ID, device/advertising name, the hello (145) response and console-log
// hex are never written to the log; console text is kept with Bluetooth addresses masked.

/// Commands this probe may send. Every entry is marked read-only ("R") in Goose's 5.0 command table
/// (b-nnett/goose Rust/core/src/commands.rs). Nothing else can be sent: unknown numbers are refused.
let READ_ONLY_ALLOWLIST: [UInt8: String] = [
    1: "LINK_VALID",
    2: "GET_MAX_PROTOCOL_VERSION",
    7: "REPORT_VERSION_INFO",
    11: "GET_CLOCK",
    26: "GET_BATTERY_LEVEL",
    34: "GET_DATA_RANGE",
    80: "GET_ALL_HAPTICS_PATTERN",
    84: "GET_BODY_LOCATION_AND_STATUS",
    98: "GET_EXTENDED_BATTERY_INFO",
    141: "GET_ADVERTISING_NAME",
    151: "GET_BATTERY_PACK_INFO",
]
/// Reversible on/off commands, each needing the owner's approval per experiment (`--toggle N`). The probe
/// sends `[1]`, captures, and always sends `[0]` before exiting. 3 = TOGGLE_REALTIME_HR (approved for E04).
let REVERSIBLE_ALLOWLIST: [UInt8: String] = [
    3: "TOGGLE_REALTIME_HR",
]
/// Responses whose body may identify the device; logged as length only.
let REDACTED_RESPONSES: Set<UInt8> = [145, 141, 76]
/// Device Information characteristics that identify the unit (serial number, system ID).
let REDACTED_DIS: Set<String> = ["2A25", "2A23"]

let whoopService = CBUUID(string: DeviceFamily.whoop5.serviceUUIDString)
let cmdChar = CBUUID(string: DeviceFamily.whoop5.commandCharacteristicUUIDString)
let disService = CBUUID(string: "180A")
let batteryService = CBUUID(string: "180F")
let hrService = CBUUID(string: "180D")

struct Options {
    var seconds = 20.0
    var commands: [UInt8] = []
    var hello = false
    var experiment = "EXP"
    var out: String? = nil
    var toggle: UInt8? = nil
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--seconds": o.seconds = min(max(Double(it.next() ?? "") ?? 20, 3), 300)   // bounded capture
        case "--commands":
            for s in (it.next() ?? "").split(separator: ",") {
                guard let n = UInt8(s), READ_ONLY_ALLOWLIST[n] != nil else {
                    FileHandle.standardError.write("refusing command \(s): not in the read-only allowlist\n".data(using: .utf8)!)
                    exit(2)
                }
                o.commands.append(n)
            }
        case "--toggle":
            guard let n = UInt8(it.next() ?? ""), REVERSIBLE_ALLOWLIST[n] != nil else {
                FileHandle.standardError.write("refusing toggle: not in the reversible allowlist\n".data(using: .utf8)!)
                exit(2)
            }
            o.toggle = n
        case "--hello": o.hello = true
        case "--exp": o.experiment = it.next() ?? o.experiment
        case "--out": o.out = it.next()
        default:
            FileHandle.standardError.write("unknown option \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func maskAddresses(_ s: String) -> String {
    s.replacingOccurrences(of: "[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}", with: "<addr>", options: .regularExpression)
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let opt: Options
    let session = String(UUID().uuidString.prefix(8))
    let started = Date()
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var command: CBCharacteristic?
    var reassemblers: [CBUUID: Reassembler] = [:]
    var out: FileHandle?
    var pendingChars = 0
    var queue: [(cmd: UInt8, data: [UInt8])] = []
    var toggleOffSent = false
    var inflight: (cmd: UInt8, seq: UInt8, sentAt: Date, deadline: Date)?
    var seq: UInt8 = 200            // distinct from the app's low sequence numbers, so responses are attributable
    var commandsStarted = false
    var summary: [String] = []

    init(_ o: Options) {
        opt = o
        super.init()
        if let path = o.out {
            FileManager.default.createFile(atPath: path, contents: nil)
            out = FileHandle(forWritingAtPath: path)
        }
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in   // room for the permission prompt
            guard let self, self.peripheral?.state != .connected else { return }
            self.finish("no strap connected within 90 s (central=\(self.central.state.rawValue))")
        }
    }

    // MARK: logging

    func record(_ fields: [String: Any]) {
        var f = fields
        f["t"] = Date().timeIntervalSince1970
        f["session"] = session
        f["exp"] = opt.experiment
        guard let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
        out?.write(data + Data("\n".utf8))
    }

    func say(_ s: String) {
        print(String(format: "[%6.2f] ", Date().timeIntervalSince(started)) + s)
        record(["kind": "note", "text": s])
    }

    func finish(_ reason: String) {
        say("finished: \(reason)")
        for s in summary { print("  " + s) }
        if let p = peripheral {
            for s in p.services ?? [] where s.uuid == whoopService {
                for c in s.characteristics ?? [] where c.isNotifying { p.setNotifyValue(false, for: c) }
            }
            // Only drops this process's claim; the link stays up for any other app using it.
            central.cancelPeripheralConnection(p)
        }
        try? out?.close()
        out = nil   // late delegate callbacks (didDisconnect) must not write to a closed handle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    // MARK: central

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        say("central state=\(c.state.rawValue) auth=\(CBCentralManager.authorization.rawValue)")
        guard c.state == .poweredOn else {
            if c.state == .unauthorized { finish("Bluetooth permission denied for this process") }
            return
        }
        let known = c.retrieveConnectedPeripherals(withServices: [whoopService])
        if let p = known.first {
            say("strap already connected to this Mac (shared link) — attaching")
            attach(p)
        } else {
            say("scanning for fd4b0001…")
            c.scanForPeripherals(withServices: [whoopService])
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        record(["kind": "adv", "rssi": rssi.intValue, "services": svcs,
                "connectable": (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false,
                "has_mfr_data": advertisementData[CBAdvertisementDataManufacturerDataKey] != nil])
        say("discovered strap rssi=\(rssi) adv services=\(svcs)")
        c.stopScan()
        attach(p)
    }

    func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        say("connected; discovering all services")
        p.discoverServices(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + opt.seconds) { [weak self] in self?.endWindow() }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        say("disconnected: \(error?.localizedDescription ?? "no error")")
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finish("connect failed: \(error?.localizedDescription ?? "?")")
    }

    // MARK: GATT enumeration

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { say("service discovery error: \(error.localizedDescription)") }
        for s in p.services ?? [] {
            record(["kind": "service", "uuid": s.uuid.uuidString, "primary": s.isPrimary])
            pendingChars += 1
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        pendingChars -= 1
        if let error { say("characteristic discovery error on \(s.uuid): \(error.localizedDescription)") }
        for c in s.characteristics ?? [] {
            let props = propNames(c.properties)
            record(["kind": "characteristic", "service": s.uuid.uuidString, "uuid": c.uuid.uuidString,
                    "props": props, "notifying": c.isNotifying])
            summary.append("\(s.uuid.uuidString.prefix(8)) / \(c.uuid.uuidString) [\(props.joined(separator: ","))]")
            p.discoverDescriptors(for: c)
            // Reads only on standard SIG services; vendor characteristics are never read or written blindly.
            if (s.uuid == disService || s.uuid == batteryService), c.properties.contains(.read) {
                p.readValue(for: c)
            }
            if s.uuid == whoopService {
                if c.uuid == cmdChar { command = c }
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    p.setNotifyValue(true, for: c)
                }
            }
        }
        if pendingChars == 0 { startCommands() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor c: CBCharacteristic, error: Error?) {
        for d in c.descriptors ?? [] {
            record(["kind": "descriptor", "characteristic": c.uuid.uuidString, "uuid": d.uuid.uuidString])
            p.readValue(for: d)   // descriptor reads (CCCD state, user description) are side-effect free
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        var f: [String: Any] = ["kind": "descriptor_value", "characteristic": d.characteristic?.uuid.uuidString ?? "?",
                                "uuid": d.uuid.uuidString]
        if let error { f["error"] = error.localizedDescription }
        else { f["value"] = String(describing: d.value ?? "nil") }
        record(f)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        record(["kind": "subscribe", "uuid": c.uuid.uuidString, "notifying": c.isNotifying,
                "error": error?.localizedDescription ?? ""])
    }

    // MARK: commands

    func startCommands() {
        guard !commandsStarted else { return }
        commandsStarted = true
        // Let subscriptions settle before writing anything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let p = self.peripheral, let c = self.command else {
                self?.say("no fd4b0002 command characteristic — commands skipped"); return
            }
            if self.opt.hello {
                self.write(DeviceFamily.whoop5ClientHello, cmd: 145, seq: 1, to: c, on: p)
            }
            self.queue = self.opt.commands.map { ($0, []) }
            if let t = self.opt.toggle { self.queue.append((t, [1])) }
            self.next()
        }
    }

    func next() {
        guard inflight == nil, let p = peripheral, let c = command, !queue.isEmpty else { return }
        let (cmd, data) = queue.removeFirst()
        seq = seq == 255 ? 200 : seq + 1
        let frame = buildWhoop5CommandFrame(seq: seq, command: cmd, data: data)
        inflight = (cmd, seq, Date(), Date().addingTimeInterval(7))
        write(frame, cmd: cmd, seq: seq, to: c, on: p)
        armTimeout(cmd: cmd, seq: seq)
    }

    /// Capture window over: switch any approved toggle back off (and wait for its answer) before exiting.
    func endWindow() {
        guard let t = opt.toggle, !toggleOffSent else {
            finish("capture window \(Int(opt.seconds)) s elapsed"); return
        }
        toggleOffSent = true
        queue = [(t, [0])]
        if inflight == nil { next() }   // otherwise next() runs when the in-flight command completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.finish("capture window \(Int(self?.opt.seconds ?? 0)) s elapsed; toggle \(t) switched off")
        }
    }

    func armTimeout(cmd: UInt8, seq: UInt8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let f = self.inflight, f.cmd == cmd, f.seq == seq else { return }
            if Date() > f.deadline {
                self.say("TIMEOUT cmd=\(cmd) \(commandName(cmd)) seq=\(seq) — no final response (not retried)")
                self.record(["kind": "result", "cmd": Int(cmd), "seq": Int(seq), "outcome": "timeout"])
                self.inflight = nil
                self.next()
            } else { self.armTimeout(cmd: cmd, seq: seq) }
        }
    }

    func write(_ frame: [UInt8], cmd: UInt8, seq: UInt8, to c: CBCharacteristic, on p: CBPeripheral) {
        record(["kind": "frame", "dir": "tx", "ch": c.uuid.uuidString, "len": frame.count, "hex": hex(frame),
                "cmd": Int(cmd), "seq": Int(seq), "name": commandName(cmd)])
        say("TX cmd=\(cmd) \(commandName(cmd)) seq=\(seq) \(hex(frame))")
        p.writeValue(Data(frame), for: c, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        record(["kind": "write_ack", "uuid": c.uuid.uuidString, "error": error?.localizedDescription ?? ""])
        if let error { say("write error: \(error.localizedDescription)") }
    }

    // MARK: notifications

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        let bytes = [UInt8](v)
        let svc = c.service?.uuid
        if svc == disService || svc == batteryService || svc == hrService {
            var f: [String: Any] = ["kind": "read", "service": svc!.uuidString, "uuid": c.uuid.uuidString, "len": bytes.count]
            if REDACTED_DIS.contains(c.uuid.uuidString) { f["value"] = "<redacted>" }
            else if c.uuid.uuidString == "2A19" { f["value"] = Int(bytes.first ?? 0) }
            else if let s = String(bytes: bytes, encoding: .utf8), s.allSatisfy({ !$0.isNewline }) { f["value"] = s; f["hex"] = hex(bytes) }
            else { f["hex"] = hex(bytes) }
            record(f)
            say("READ \(c.uuid.uuidString) = \(f["value"] ?? f["hex"] ?? "")")
            return
        }
        guard svc == whoopService else { return }
        let asm = reassemblers[c.uuid] ?? Reassembler(family: .whoop5)
        reassemblers[c.uuid] = asm
        record(["kind": "fragment", "ch": c.uuid.uuidString, "len": bytes.count])
        for frame in asm.feed(bytes) { handle(frame, on: c.uuid) }
    }

    func handle(_ frame: [UInt8], on ch: CBUUID) {
        let chk = verifyFrame(frame, family: .whoop5)
        var f: [String: Any] = ["kind": "frame", "dir": "rx", "ch": ch.uuidString, "len": frame.count,
                                "hdr_crc": chk.crc8OK ?? false, "crc32": chk.crc32OK ?? false]
        let type = frame.count > 8 ? frame[8] : 0
        f["type"] = Int(type)
        var redact = false
        if (type == 36 || type == 38), frame.count > 12 {
            let cmd = frame[10], oseq = frame[11], result = frame[12]
            f["cmd"] = Int(cmd); f["seq"] = Int(oseq); f["result"] = Int(result)
            redact = REDACTED_RESPONSES.contains(cmd)
            if let fl = inflight, fl.cmd == cmd, fl.seq == oseq {
                let ms = Int(Date().timeIntervalSince(fl.sentAt) * 1000)
                f["latency_ms"] = ms
                say("RX response cmd=\(cmd) seq=\(oseq) result=\(result) len=\(frame.count) latency=\(ms)ms")
                if result != 2 {   // 2 = PENDING (Goose); wait for the final result
                    record(["kind": "result", "cmd": Int(cmd), "seq": Int(oseq), "outcome": "result \(result)", "latency_ms": ms])
                    inflight = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.next() }
                } else {
                    inflight = (fl.cmd, fl.seq, fl.sentAt, Date().addingTimeInterval(25))
                }
            } else {
                say("RX response cmd=\(cmd) seq=\(oseq) result=\(result) len=\(frame.count) (not ours)")
            }
        }
        if type == 50 {
            redact = true
            let body = frame.count > 23 ? Array(frame[19..<(frame.count - 4)]) : []
            f["text"] = maskAddresses(String(decoding: body.filter { $0 != 0 }, as: UTF8.self))
        }
        f["hex"] = redact ? "<redacted \(frame.count) bytes>" : hex(frame)
        record(f)
        if type != 36 && type != 38 { say("RX \(ch.uuidString.prefix(8)) type=\(type) len=\(frame.count) crc=\(chk.ok)") }
    }
}

func commandName(_ c: UInt8) -> String {
    READ_ONLY_ALLOWLIST[c] ?? REVERSIBLE_ALLOWLIST[c] ?? (c == 145 ? "GET_HELLO" : "?")
}

func propNames(_ p: CBCharacteristicProperties) -> [String] {
    var o: [String] = []
    if p.contains(.broadcast) { o.append("broadcast") }
    if p.contains(.read) { o.append("read") }
    if p.contains(.writeWithoutResponse) { o.append("writeNoResp") }
    if p.contains(.write) { o.append("write") }
    if p.contains(.notify) { o.append("notify") }
    if p.contains(.indicate) { o.append("indicate") }
    if p.contains(.authenticatedSignedWrites) { o.append("signedWrite") }
    if p.contains(.extendedProperties) { o.append("extended") }
    if p.contains(.notifyEncryptionRequired) { o.append("notifyEncReq") }
    if p.contains(.indicateEncryptionRequired) { o.append("indicateEncReq") }
    return o
}

let probe = Probe(parseOptions())
RunLoop.main.run()
