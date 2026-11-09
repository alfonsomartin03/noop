import Foundation
import Combine
import UserNotifications
import StrandAnalytics

/// Which check-ins are on, which prompts each asks (in order), and their optional reminders. Preferences live in
/// UserDefaults (`checkin.*`); entries live in the store. Turning a session off or removing a prompt never deletes past
/// entries — they keep the prompt id and version they were answered under.
@MainActor
final class CheckInSettings: ObservableObject {
    struct Reminder: Codable, Equatable {
        var enabled = false
        var hour: Int
        var minute = 0
    }

    @Published var morningEnabled: Bool { didSet { save() } }
    @Published var eveningEnabled: Bool { didSet { save() } }
    @Published var morningPrompts: [String] { didSet { save() } }
    @Published var eveningPrompts: [String] { didSet { save() } }
    @Published var morningReminder: Reminder { didSet { save() } }
    @Published var eveningReminder: Reminder { didSet { save() } }

    private let defaults: UserDefaults
    private var loading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        morningEnabled = defaults.bool(forKey: "checkin.morning.enabled")
        eveningEnabled = defaults.bool(forKey: "checkin.evening.enabled")
        morningPrompts = Self.ids(defaults, "checkin.morning.prompts") ?? CheckInLibrary.defaultMorning
        eveningPrompts = Self.ids(defaults, "checkin.evening.prompts") ?? CheckInLibrary.defaultEvening
        morningReminder = Self.reminder(defaults, "checkin.morning.reminder") ?? Reminder(hour: 8)
        eveningReminder = Self.reminder(defaults, "checkin.evening.reminder") ?? Reminder(hour: 21)
        loading = false
    }

    func enabled(_ s: CheckInSession) -> Bool { s == .morning ? morningEnabled : eveningEnabled }
    func setEnabled(_ s: CheckInSession, _ on: Bool) { if s == .morning { morningEnabled = on } else { eveningEnabled = on } }
    func promptIds(_ s: CheckInSession) -> [String] { s == .morning ? morningPrompts : eveningPrompts }
    func setPromptIds(_ s: CheckInSession, _ ids: [String]) { if s == .morning { morningPrompts = ids } else { eveningPrompts = ids } }
    func reminder(_ s: CheckInSession) -> Reminder { s == .morning ? morningReminder : eveningReminder }
    func setReminder(_ s: CheckInSession, _ r: Reminder) { if s == .morning { morningReminder = r } else { eveningReminder = r } }

    /// The prompts a session asks, in the user's order, dropping ids no longer in the library.
    func prompts(_ s: CheckInSession) -> [CheckInPrompt] { promptIds(s).compactMap(CheckInLibrary.prompt) }
    var anyEnabled: Bool { morningEnabled || eveningEnabled }

    private func save() {
        guard !loading else { return }
        defaults.set(morningEnabled, forKey: "checkin.morning.enabled")
        defaults.set(eveningEnabled, forKey: "checkin.evening.enabled")
        defaults.set(morningPrompts, forKey: "checkin.morning.prompts")
        defaults.set(eveningPrompts, forKey: "checkin.evening.prompts")
        defaults.set(try? JSONEncoder().encode(morningReminder), forKey: "checkin.morning.reminder")
        defaults.set(try? JSONEncoder().encode(eveningReminder), forKey: "checkin.evening.reminder")
    }

    private static func ids(_ d: UserDefaults, _ key: String) -> [String]? { d.stringArray(forKey: key) }
    private static func reminder(_ d: UserDefaults, _ key: String) -> Reminder? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(Reminder.self, from: $0) }
    }
}

/// Optional check-in reminders: one-off notifications for the next week (never a repeating trigger, so a completed or
/// skipped session's reminder for that day can be withdrawn). A reminder offers "Remind me in 30 minutes"; dismissing
/// it does nothing else. When notifications aren't allowed, the Overview card is the reminder.
@MainActor
final class CheckInReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheckInReminders()
    static let category = "noop.checkin"
    static let snoozeAction = "noop.checkin.snooze"
    private static let prefix = "noop.checkin."
    private static let daysAhead = 7

    /// Registers the category and becomes the notification delegate (check-in banners show while NOOP is in front;
    /// every other notification keeps the system default of not presenting in the foreground).
    func install() {
        let center = UNUserNotificationCenter.current()
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Remind me in 30 minutes", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [snooze], intentIdentifiers: [])])
        center.delegate = self
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Rebuild pending check-in reminders. `done` holds "date|session" keys already completed or skipped.
    func reschedule(settings: CheckInSettings, done: Set<String>, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) && !$0.contains(".snooze.") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let cal = Calendar.current
        for s in CheckInSession.allCases {
            let r = settings.reminder(s)
            guard settings.enabled(s), r.enabled, !settings.prompts(s).isEmpty else { continue }
            for offset in 0..<Self.daysAhead {
                guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                      let fire = cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: day), fire > now else { continue }
                let key = Repository.dayString(day)
                if done.contains("\(key)|\(s.rawValue)") { continue }
                let content = UNMutableNotificationContent()
                content.title = s.title
                content.body = "A few quick taps: \(s.about.lowercased())."
                content.categoryIdentifier = Self.category
                content.userInfo = ["session": s.rawValue, "date": key]
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let req = UNNotificationRequest(identifier: "\(Self.prefix)\(s.rawValue).\(key)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                try? await center.add(req)
            }
        }
    }

    /// Withdraw today's reminder (and any snooze) for a session once it is completed or skipped.
    func withdraw(session: CheckInSession, date: String) {
        let center = UNUserNotificationCenter.current()
        let ids = ["\(Self.prefix)\(session.rawValue).\(date)", "\(Self.prefix)\(session.rawValue).snooze.\(date)"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.categoryIdentifier == Self.category ? [.banner, .sound, .list] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if response.actionIdentifier == Self.snoozeAction, content.categoryIdentifier == Self.category,
           let s = content.userInfo["session"] as? String, let d = content.userInfo["date"] as? String,
           let copy = content.mutableCopy() as? UNMutableNotificationContent {
            let req = UNNotificationRequest(identifier: "\(Self.prefix)\(s).snooze.\(d)", content: copy,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false))
            center.add(req)
        }
        completionHandler()
    }
}
