import Foundation
import UserNotifications
import WhoopProtocol

/// Turns battery readings into the two user notifications (low battery, charging complete).
///
/// The decisions live in `BatteryAlertPolicy` (WhoopProtocol, unit-tested); this class only persists its state
/// across launches and posts through UserNotifications. Charging is only ever known from a verified source —
/// none is verified on WHOOP 5.0 yet, so the charging-complete alert stays silent rather than guessing.
@MainActor
final class BatteryMonitor {
    static let lowEnabledKey = "notify.batteryLow"
    static let fullEnabledKey = "notify.batteryFull"
    private static let stateKey = "notify.batteryAlertState"

    private let policy = BatteryAlertPolicy()
    private var state: BatteryAlertState
    private let defaults: UserDefaults
    /// Overridable for tests; posts the notification.
    var post: (String, String, String) -> Void = BatteryMonitor.postNotification

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.stateKey), let s = try? JSONDecoder().decode(BatteryAlertState.self, from: d) {
            state = s
        } else {
            state = BatteryAlertState()
        }
    }

    static func isEnabled(_ key: String, _ d: UserDefaults = .standard) -> Bool { d.object(forKey: key) as? Bool ?? true }

    func ingest(_ r: BatteryReading, now: Date = Date()) {
        let alerts = policy.evaluate(r, now: now.timeIntervalSince1970, state: &state,
                                     lowEnabled: Self.isEnabled(Self.lowEnabledKey, defaults),
                                     fullEnabled: Self.isEnabled(Self.fullEnabledKey, defaults))
        if let d = try? JSONEncoder().encode(state) { defaults.set(d, forKey: Self.stateKey) }
        for a in alerts {
            switch a {
            case .low(let pct):
                post("whoop.battery.low", "WHOOP battery low",
                     "Your WHOOP is at \(pct)%. Consider charging it soon to avoid interruptions in data recording.")
            case .full:
                post("whoop.battery.full", "WHOOP fully charged", "Your WHOOP has reached 100%. You can remove the charger.")
            }
        }
    }

    /// Ask for notification permission (called when the user turns an alert on, and once at launch if any is on).
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postNotification(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // Respect the system setting: if notifications are off for NOOP, nothing is shown (and nothing queued).
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }
}
