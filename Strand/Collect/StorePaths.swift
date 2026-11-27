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
    /// Testing and diagnostic paths (test host, fixture launches, connection log, unified-log lines, ops counters,
    /// live R–R evidence, raw and research capture) exist only in Debug builds; a Release build compiles them out unless
    /// built with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=NOOP_DIAGNOSTICS` (Release-speed fixture timings, docs/BUILD.md).
    #if DEBUG || NOOP_DIAGNOSTICS
    static let diagnostics = true
    #else
    static let diagnostics = false
    #endif
    /// `NOOP_FIXTURE_STORE=<path to a database COPY>` opens that file instead of the live store and keeps Bluetooth off,
    /// so screens can be inspected and timed without touching the strap. Opening a store can migrate it: never point
    /// this at the live database. Diagnostic builds only.
    static let fixtureStore: String? = diagnostics
        ? ProcessInfo.processInfo.environment["NOOP_FIXTURE_STORE"].flatMap { $0.isEmpty ? nil : $0 } : nil
    /// Fixture only: start the iPhone-sync receiver with pairing open and codes auto-accepted (#79 checks).
    static var fixtureSyncPair: Bool { fixtureStore != nil && UserDefaults.standard.bool(forKey: "noop.fixture.syncPair") }
    /// False in a fixture launch: no CoreBluetooth manager is created, so nothing scans, connects or sends commands.
    static var bluetoothEnabled: Bool { fixtureStore == nil && !CompanionMode.isOn }
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
    #if os(macOS)
    /// Fixture only: `-noop.fixture.detail strain|sleep|recovery` opens that Overview detail page on launch, and
    /// `-noop.fixture.day yyyy-MM-dd` picks the day (default: newest with data), for visual checks (#86).
    static var fixtureDetail: TodayDetail? {
        switch fixtureStore == nil ? nil : UserDefaults.standard.string(forKey: "noop.fixture.detail") {
        case "strain": return .strain
        case "sleep": return .sleep
        case "recovery": return .recovery
        default: return nil
        }
    }
    #endif
    /// Fixture only: `-noop.fixture.scrollTo strain-tiles` scrolls the page to the view with that id after loading.
    static var fixtureScrollTo: String? { fixtureStore == nil ? nil : UserDefaults.standard.string(forKey: "noop.fixture.scrollTo") }
    /// Fixture only: `-noop.fixture.width <points>` resizes the main window after launch (floor: the 1000-pt minimum).
    static var fixtureWidth: Int? {
        guard fixtureStore != nil else { return nil }
        let w = UserDefaults.standard.integer(forKey: "noop.fixture.width")
        return w > 0 ? w : nil
    }
    /// Fixture only: `-noop.fixture.appearance dark|light` forces the app's appearance (system setting otherwise).
    static var fixtureAppearance: String? { fixtureStore == nil ? nil : UserDefaults.standard.string(forKey: "noop.fixture.appearance") }
    static var fixtureDay: String? { fixtureStore == nil ? nil : UserDefaults.standard.string(forKey: "noop.fixture.day") }
}
