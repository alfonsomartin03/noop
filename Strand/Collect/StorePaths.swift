import Foundation
enum StorePaths {
    /// `<AppSupport>/OpenWhoop/whoop.sqlite`, creating the directory if needed. A fixture launch uses its copy instead.
    // One fixed location for the database; the same path is used by capture, the read model and backups.
    static func defaultDatabasePath() throws -> String {
        if let fixture = LaunchMode.fixtureStore { return fixture }
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("whoop.sqlite").path
    }
}

/// Developer launch options, read once from the environment. See docs/BUILD.md ("Fixture launch").
enum LaunchMode {
    /// `NOOP_FIXTURE_STORE=<path to a database COPY>` opens that file instead of the live store and keeps Bluetooth off,
    /// so screens can be inspected and timed without touching the strap. Opening a store can migrate it: never point
    /// this at the live database.
    static let fixtureStore: String? = ProcessInfo.processInfo.environment["NOOP_FIXTURE_STORE"].flatMap { $0.isEmpty ? nil : $0 }
    /// False in a fixture launch: no CoreBluetooth manager is created, so nothing scans, connects or sends commands.
    static var bluetoothEnabled: Bool { fixtureStore == nil }
    /// Process start, for the launch-to-content timing a fixture launch prints.
    static let started = Date()

    /// Fixture only: the destination to open on (`-noop.fixture.tab trends`), for screenshots.
    static var fixtureTab: String? { fixtureStore == nil ? nil : UserDefaults.standard.string(forKey: "noop.fixture.tab") }
    /// Fixture only: `-noop.fixture.live YES` opens the live-strap sheet on launch.
    static var fixtureLiveSheet: Bool { fixtureStore != nil && UserDefaults.standard.bool(forKey: "noop.fixture.live") }
    /// Fixture only: `-noop.fixture.battery cycle` plays synthetic battery states (idle, charging, full, disconnected)
    /// through the real battery surfaces; `charging` holds a charging reading. Synthetic: no strap reports charging today.
    static var fixtureBattery: String? { fixtureStore == nil ? nil : UserDefaults.standard.string(forKey: "noop.fixture.battery") }
    /// Fixture only: `-noop.fixture.alarmHistory YES` appends synthetic alarm history (one occurrence per status) to the
    /// fixture COPY, for visual checks of Alarms ▸ History. Never runs on the real store.
    /// Fixture only: `-noop.fixture.alarmDetail YES` opens the newest history occurrence's detail sheet.
    static var fixtureAlarmDetail: Bool { fixtureStore != nil && UserDefaults.standard.bool(forKey: "noop.fixture.alarmDetail") }
    static var fixtureAlarmHistory: Bool { fixtureStore != nil && UserDefaults.standard.bool(forKey: "noop.fixture.alarmHistory") }
}
