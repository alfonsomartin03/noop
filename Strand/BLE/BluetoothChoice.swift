import Foundation
import CoreBluetooth

/// The user's remembered Bluetooth decision, kept in UserDefaults so it survives relaunches and rebuilds.
///
/// macOS stores its own Allow / Don't Allow answer per app signature; an ad-hoc-signed rebuild loses it and the system
/// prompt returns (see Signing.xcconfig). NOOP keeps its own copy so a "Don't Allow" stays respected: while declined,
/// no CBCentralManager is created at launch, so nothing scans and the system prompt is not raised again. An "Allow"
/// cannot silence the system prompt for a re-signed build; only stable signing does that.
/// No CoreBluetooth instances here — pure decisions, unit-testable.
enum BluetoothChoice: String {
    case undecided, allowed, declined

    static let key = "noop.bluetoothChoice"

    static func stored(_ defaults: UserDefaults = .standard) -> BluetoothChoice {
        defaults.string(forKey: key).flatMap(BluetoothChoice.init(rawValue:)) ?? .undecided
    }

    static func store(_ choice: BluetoothChoice, _ defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
    }

    /// The choice implied by the system's answer; nil while the system has not asked (keeps the remembered one).
    static func from(_ authorization: CBManagerAuthorization) -> BluetoothChoice? {
        switch authorization {
        case .allowedAlways: return .allowed
        case .denied, .restricted: return .declined
        case .notDetermined: return nil
        @unknown default: return nil
        }
    }

    /// Whether to create the Bluetooth manager at launch. A remembered decline wins over an undetermined system state
    /// (a rebuilt app that would prompt again), but a later Allow in System Settings re-enables Bluetooth.
    static func shouldStartBluetooth(stored: BluetoothChoice, authorization: CBManagerAuthorization) -> Bool {
        stored != .declined || authorization == .allowedAlways
    }

    /// Reconnect attempts while the app is open and the strap link is lost.
    static let reconnectIntervalSeconds = 15 * 60
}
