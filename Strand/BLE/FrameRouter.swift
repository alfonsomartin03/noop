import Foundation
import WhoopProtocol

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
// Decodes whole frames into LiveState updates. No CoreBluetooth here, which keeps it unit-testable.
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?

    public init(state: LiveState) {
        self.state = state
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    public func handle(frame: [UInt8], family: DeviceFamily = .whoop4) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        // Corrupt frames never touch state.
        if parsed.crcOK == false { return }

        state.lastFrameType = parsed.typeName

        // WHOOP 5.0 realtime: the generic parser exposes no fields for 5.0, so decode the record directly.
        if family == .whoop5 {
            if parsed.typeName == "REALTIME_DATA", let rt = decodeWhoop5Realtime(frame) {
                // Plausibility window: 0 or absurd values are sensor glitches, not heart rates.
                if (30...220).contains(rt.heartRate) { state.heartRate = rt.heartRate }
                if !rt.rr.isEmpty { state.rr = rt.rr }
            }
            return
        }

        switch parsed.typeName {
        case "REALTIME_DATA":
            // Reject 0 / out-of-range spikes from the realtime stream; AppModel medians the rest.
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220 {
                state.heartRate = hr
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.rr = rr
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                state.lastEvent = ev
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                // Belt-and-suspenders: a BLE_BONDED event confirms the link is bonded.
                // (BLEManager also sets bonded=true when the confirmed write succeeds.)
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
                // Physical inputs the strap exposes — live only (this path never sees historical
                // replay, which goes through the Backfiller). Event strings are "NAME(rawValue)".
                if ev.hasPrefix("BLE_HR_PROFILE_ENABLED") {
                    state.hrBroadcast = true
                } else if ev.hasPrefix("BLE_HR_PROFILE_DISABLED") {
                    state.hrBroadcast = false
                }
                if ev.hasPrefix("DOUBLE_TAP") {
                    state.onDoubleTap?()
                } else if ev.hasPrefix("WRIST_ON") {
                    if !state.worn { state.worn = true; state.onWristChange?(true) }
                } else if ev.hasPrefix("WRIST_OFF") {
                    if state.worn { state.worn = false; state.onWristChange?(false) }
                }
            }

        default:
            break
        }
    }
}
