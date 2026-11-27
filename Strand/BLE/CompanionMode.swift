import Foundation

/// Mac companion mode (#78): the iPhone collects from the strap, so this Mac creates no Bluetooth central, scans,
/// reconnects or sends any command (clock, alarm, battery) to the strap. History, scoring and iPhone sync keep working.
/// Stored per device; the iPhone never sets it on the Mac. Turning it off lets the Mac collect again, which needs the
/// strap re-paired to the Mac.
enum CompanionMode {
    static let key = "noop.companionMode"
    static var isOn: Bool {
        #if os(macOS)
        UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }
    static func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}
