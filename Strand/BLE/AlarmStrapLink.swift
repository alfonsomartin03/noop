import Foundation
import WhoopProtocol
import StrandAnalytics

// Shared by the Mac app and the iPhone collector (#78): BLEManager conforms; only the Mac's AlarmController uses it.

/// The alarm commands NOOP may send (verified forms only; BLEManager builds the payloads).
enum AlarmStrapCommand: Equatable { case set(strapSeconds: UInt32), get, run, disableAll }

/// What AlarmController needs from the strap link. BLEManager conforms.
@MainActor
protocol AlarmStrapLink: AnyObject {
    /// A bonded WHOOP 5.0 link that can take alarm commands now.
    var alarmLinkReady: Bool { get }
    var alarmClock: ClockEstimate? { get }
    /// Sends one command; returns its app sequence number (replies echo it), nil when not sent.
    func sendAlarmCommand(_ c: AlarmStrapCommand) -> UInt8?
    /// Realtime HR stream ownership: the stream stays on while any owner holds it.
    func acquireRealtime(owner: String)
    func releaseRealtime(owner: String)
}

/// The realtime-stream owner name the alarm's wake window uses (BLEManager defers periodic pulls while it holds it).
enum AlarmRealtime { static let owner = "alarm" }
