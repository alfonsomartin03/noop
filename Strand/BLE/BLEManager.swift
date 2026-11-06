import Foundation
import CoreBluetooth
import os
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// CoreBluetooth engine for WHOOP 4.0 and WHOOP 5.0: scan-by-service → connect → discover → bond → subscribe →
/// reassemble per characteristic → typed decode (5.0: WhoopProtocol/Whoop5Messages) → state, store, history sync.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    /// Opt-in (default off): subscribe to 2A37 ourselves. Off keeps the broadcast exclusively available to other devices.
    static let hrBroadcastKey = "hrBroadcastLastSet"
    static var listensToBroadcast: Bool { UserDefaults.standard.bool(forKey: "listenToHRBroadcast") }
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    // WHOOP 5.0 ("puffin") service; source: b-nnett/goose via DeviceFamily. UNVERIFIED on hardware here.
    static let whoop5Service = CBUUID(string: DeviceFamily.whoop5.serviceUUIDString)
    static let whoop5CmdWriteChar = CBUUID(string: DeviceFamily.whoop5.commandCharacteristicUUIDString)

    /// UserDefaults key: when true NOOP stores strap history but never acknowledges it, so the strap
    /// does not delete anything — but it also stops after the first chunk (~50 records), because the
    /// strap only sends the next chunk once the previous one is acked. Default false: ack after save.
    static let keepDataOnStrapKey = "noop.keepDataOnStrap"
    static var keepDataOnStrap: Bool {
        UserDefaults.standard.object(forKey: keepDataOnStrapKey) as? Bool ?? false
    }

    static let restoreID = "com.openwhoop.ble.central"

    private static let osLog = Logger(subsystem: "com.noopapp.noop", category: "ble")
    /// Seconds of filtered scanning with no hit before falling back to an unfiltered name-based scan.
    static let filteredScanTimeoutSeconds = 10
    /// Seconds to wait for any notification after the 5.0 hello before logging a diagnostic.
    static let helloResponseTimeoutSeconds = 8

    // MARK: Published state
    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    private var backfiller: Backfiller?
    /// True while a historical offload session is in progress (frames route to Backfiller).
    private var backfilling = false
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    private var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    private var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    private var keepAliveTick = 0
    /// Reconnect watchdog: while the app is open and the strap link is lost (not a user Disconnect), restart the
    /// scan every `BluetoothChoice.reconnectIntervalSeconds`. Runs for the life of the central, not just a connection.
    private var reconnectTimer: DispatchSourceTimer?
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// Who currently needs the (heavy) realtime stream ("live-sheet", "menu", "alarm"…). The stream stays on while any
    /// owner holds it and keep-alive re-arms it; releasing one owner never stops another's stream.
    private(set) var realtimeOwners = Set<String>()
    private var wantsRealtime: Bool { !realtimeOwners.isEmpty }
    /// Realtime HR samples with their measurement time (strap second mapped to the Mac clock), for smart wake.
    var onRealtimeHR: ((HRObservation) -> Void)?
    /// When battery / pack info was last requested; a poll skipped during a history download runs as soon as it ends.
    private var lastBatteryPollAt = Date.distantPast
    /// Pack-info requests by app sequence number: when sent and on which connection (a reply describes that moment).
    private var packInfoRequests: [UInt8: (at: Date, connection: UUID)] = [:]
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    private var connectHandshakeDone = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false
    /// Ordered queue of frames awaiting drain through the serial Backfiller task.
    private var backfillFrameQueue: [[UInt8]] = []
    /// True while the drain task is running (prevents a second drain task from launching).
    private var backfillDraining = false

    // MARK: CoreBluetooth
    /// nil in a fixture launch (`LaunchMode.bluetoothEnabled` false): nothing scans, connects or writes to a strap.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    private var clockRequested = false
    private var intentionalDisconnect = false
    private var stalePairingFailures = 0
    /// Hardware generation of the connected strap. Defaults to 4.0 (legacy path); switched to 5.0 when the
    /// fd4b… service is found during discovery. Drives framing, handshake and which commands are legal.
    private(set) var family: DeviceFamily = .whoop4
    private var batteryCharacteristic: CBCharacteristic?
    private var scanFallbackWork: DispatchWorkItem?
    private var helloWatchdog: DispatchWorkItem?
    private var unfilteredScan = false
    private var unfilteredSeen = 0
    private var rxFrameCount = 0
    private var whoop5Chars: [CBCharacteristic] = []
    private var whoop5Reassemblers: [CBUUID: Reassembler] = [:]
    private var rxFragmentCount = 0
    private var strapFrameTotal = 0
    private var whoop5HistoryActive = false
    private var historyCapture: FileHandle?
    /// Fired (main actor) whenever new strap data lands in the store, so the app can recompute and redraw.
    var onStoredDataChanged: (() -> Void)?
    /// True when the active pull was started by the connect-time auto-sync rather than the user.
    private var whoop5HistoryAutomatic = false
    /// Auto-pull runs once per connection.
    private var whoop5AutoPullDone = false
    private var historyEndLogged = 0
    private var historySeenTs = Set<Int>()
    private var historyIdleWork: DispatchWorkItem?
    private var historyMetaSeen: [String] = []
    private var historyDecoded: [Whoop5HistoricalRecord] = []
    static let historyMaxCapturedFrames = 600
    static let historyIdleSeconds = 20
    private var heartRateCharacteristic: CBCharacteristic?
    private var whoop5SetupAttempts = 0
    private var whoop5RetryPending = false
    private var whoop5ExhaustedLogged = false
    static let whoop5MaxSetupAttempts = 6
    static let disService = CBUUID(string: "180A")
    /// GET_CLOCK requests in flight: app seq → host time the request was written.
    private var clockRequestSentAt: [UInt8: Double] = [:]
    private var clockEstimator = DeviceClockEstimator()
    /// Increments per pull so a late chunk task from an ended pull can never ack into a new one.
    private var whoop5SessionID = 0
    /// Set when the open chunk holds a frame NOOP cannot store (unknown record version, IMU records).
    /// Such a chunk is never acknowledged: the strap keeps it and the pull stops.
    private var whoop5ChunkProblem: String?
    /// History frames in the open chunk that NOOP cannot decode yet (record version 0x1a, IMU records). They are
    /// archived verbatim (RawHistoryArchive) before the chunk is acknowledged, so an ack never discards them.
    private var whoop5ChunkUndecoded: [[UInt8]] = []
    private lazy var rawArchive: RawHistoryArchive? = try? RawHistoryArchive.standard()
    /// Strap events that arrived inside the open chunk; saved with its records (unknown events included).
    private var whoop5ChunkEvents: [WhoopEvent] = []
    /// Waiting for GET_DATA_RANGE before starting a pull (the range fixes the session's target).
    private var whoop5AwaitingRange = false
    private var whoop5RangeWait: DispatchWorkItem?
    /// Last realtime (type-40) strap second seen; a repeat is a duplicate frame.
    private var lastRealtimeSecond: UInt32?
    private var lastRealtimeAt: Date?
    /// Cursor: newest strap second the database holds contiguously from WHOOP 5.0 pulls (progress start).
    static let syncedThroughCursor = "whoop5_synced_through"
    /// Cursor pair persisting the latest clock estimate (milliseconds) and when it was measured.
    static let clockOffsetCursor = "whoop5_clock_offset_ms"
    static let clockMeasuredCursor = "whoop5_clock_measured_at"
    /// Called when a pull's download finished (strap sent HISTORY_COMPLETE and every chunk was saved),
    /// so the app can run processing. The bool is false for a pull that ended early.
    var onSyncDownloadFinished: ((Bool) -> Void)?
    /// Alarm/haptic command answers and events, for AlarmController's sync verification and dismissal.
    var onAlarmResponse: ((Whoop5CommandResponse) -> Void)?
    /// Second argument: true when the event is live (not a history replay).
    var onAlarmEvent: ((Whoop5Event, Bool) -> Void)?
    static let whoop5RetryDelaySeconds = 5
    /// The link dropped (alarm deliveries in flight fail; nothing is assumed delivered).
    var onLinkDropped: (() -> Void)?

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    let deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (foundation for M3 state restoration).
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        state.bluetoothChoice = BluetoothChoice.stored()
        if LaunchMode.bluetoothEnabled {
            if BluetoothChoice.shouldStartBluetooth(stored: state.bluetoothChoice, authorization: CBCentralManager.authorization) {
                startCentral()
            } else {
                log("Bluetooth off: you chose Don't Allow — turn it on in Settings ▸ Strap")
            }
        }
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        router.onLog = { [weak self] in self?.log($0) }
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        guard let path = try? StorePaths.defaultDatabasePath() else { return }
        guard let store = try? await WhoopStore(path: path) else { return }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        // Keep a history of battery readings so drain can be measured, not just the current level.
        state.onBatteryUpdate = { [weak self] pct in
            Task { @MainActor in await self?.collector?.recordBattery(pct: pct) }
        }
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture)
        backfiller?.acknowledgesChunks = { !BLEManager.keepDataOnStrap }
        syncedThrough = try? await store.cursor(BLEManager.syncedThroughCursor)
        // Strand: no server uploader/sync — all data stays on-device.
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        startCentral()
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        router.onLog = { [weak self] in self?.log($0) }
    }

    // MARK: Bluetooth access

    /// Create the central (raises the system prompt if macOS has not asked yet) and the reconnect watchdog.
    private func startCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        startReconnectTimer()
    }

    /// Remember the user's choice. Allowing starts Bluetooth now (or, when macOS itself denies NOOP, the caller sends the
    /// user to System Settings); declining disconnects, stops scanning and keeps Bluetooth off on later launches.
    public func setBluetoothAllowed(_ allowed: Bool) {
        BluetoothChoice.store(allowed ? .allowed : .declined)
        state.bluetoothChoice = allowed ? .allowed : .declined
        if allowed {
            intentionalDisconnect = false
            if LaunchMode.bluetoothEnabled { startCentral() }
            connect()
        } else {
            disconnect()
            reconnectTimer?.cancel()
            reconnectTimer = nil
            state.nextReconnectAt = nil
            central?.delegate = nil
            central = nil
            log("Bluetooth turned off in NOOP; remembered across launches")
        }
    }

    /// Record the system's answer once it gives one, so a Don't Allow is remembered even if a rebuild resets macOS's copy.
    private func rememberAuthorization() {
        let auth = CBCentralManager.authorization
        state.bluetoothDeniedBySystem = auth == .denied || auth == .restricted
        guard let choice = BluetoothChoice.from(auth), choice != state.bluetoothChoice else { return }
        BluetoothChoice.store(choice)
        state.bluetoothChoice = choice
    }

    private func startReconnectTimer() {
        reconnectTimer?.cancel()
        let s = BluetoothChoice.reconnectIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.reconnectFire() }
        t.resume()
        reconnectTimer = t
        state.nextReconnectAt = state.connected ? nil : Date().addingTimeInterval(TimeInterval(s))
    }

    /// Runs every 15 min for as long as the app is open: if the link is lost (and the user did not choose Disconnect),
    /// drop any connection attempt that never completed and scan again. A stale-pairing strap is retried too, in case the
    /// user has since reset Bluetooth; it fails fast and stays paused if not.
    private func reconnectFire() {
        let next = Date().addingTimeInterval(TimeInterval(BluetoothChoice.reconnectIntervalSeconds))
        guard !state.connected, !intentionalDisconnect else { state.nextReconnectAt = nil; return }
        state.nextReconnectAt = next
        guard let central, central.state == .poweredOn else { return }
        log("Strap link lost — periodic reconnect attempt")
        scanFallbackWork?.cancel()
        central.stopScan()
        if let p = peripheral, p.state != .connected {
            central.cancelPeripheralConnection(p)
            peripheral = nil
        }
        restoredPeripheral = nil
        connect()
    }

    // MARK: Public API
    // Scan by service first; if nothing is found, fall back to an unfiltered name-based scan (see startUnfilteredScan).
    public func connect() {
        intentionalDisconnect = false
        guard let central, central.state == .poweredOn else {
            log("Bluetooth not ready: \(central.map { BLEManager.stateName($0.state) } ?? (state.bluetoothChoice == .declined ? "turned off in NOOP" : "off for this launch")); authorization=\(BLEManager.authName(CBCentralManager.authorization))")
            return
        }
        // A strap that is already connected to macOS (or another app) does NOT advertise, so a scan can't
        // see it. Ask the system for such peripherals first.
        let known = central.retrieveConnectedPeripherals(
            withServices: [BLEManager.customService, BLEManager.whoop5Service])
        if let p = known.first {
            log("Found \(known.count) system-connected WHOOP peripheral(s) — connecting without scan")
            adopt(p)
            return
        }
        unfilteredScan = false
        unfilteredSeen = 0
        log("Scanning for WHOOP 4.0 (6108…) and 5.0 (fd4b…) services…")
        central.scanForPeripherals(
            withServices: [BLEManager.customService, BLEManager.whoop5Service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanFallbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startUnfilteredScan() }
        scanFallbackWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(BLEManager.filteredScanTimeoutSeconds), execute: work)
    }

    /// Fallback: some straps may not put their service UUID in the advertisement. Scan unfiltered and
    /// accept only peripherals whose name starts with "WHOOP". ASSUMPTION: the 5.0 advertises such a name.
    private func startUnfilteredScan() {
        guard let central, central.state == .poweredOn, !intentionalDisconnect, peripheral == nil else { return }
        log("No WHOOP service seen in \(BLEManager.filteredScanTimeoutSeconds)s — unfiltered scan by name. "
            + "If this fails: close the official WHOOP app / disconnect the strap from your phone (a strap "
            + "already connected elsewhere stops advertising), keep the strap close, and check it is charged.")
        central.stopScan()
        unfilteredScan = true
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Take ownership of a peripheral and start the connection.
    private func adopt(_ p: CBPeripheral) {
        scanFallbackWork?.cancel()
        central?.stopScan()
        peripheral = p
        p.delegate = self
        log("Connecting (peripheral state=\(p.state.rawValue))…")
        central?.connect(p, options: nil)
    }

    /// Start pairing over after a stale-bond failure. CoreBluetooth cannot unpair a device, so the user
    /// resets Bluetooth first; this clears the app-side state and rescans.
    // Used when macOS holds a stale pairing the strap has forgotten; clears state and scans again.
    public func restartPairing() {
        stalePairingFailures = 0
        state.pairingStale = false
        restoredPeripheral = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        central?.stopScan()
        log("Restarting pairing from scratch")
        connect()
    }

    /// Ask a WHOOP 5.0 whether its charging pack is attached (read-only GET_BATTERY_PACK_INFO).
    public func refreshChargingState() {
        if family == .whoop5 { requestPackInfo() }
    }

    public func disconnect() {
        intentionalDisconnect = true
        state.nextReconnectAt = nil
        scanFallbackWork?.cancel()
        helloWatchdog?.cancel()
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        central?.stopScan()
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    // Single place commands are framed and written; picks the 4.0 or 5.0 frame format from the connected family.
    /// Returns the app sequence number the command went out with (WHOOP 5.0 replies echo it), nil when not sent.
    @discardableResult
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) -> UInt8? {
        guard let p = peripheral, let ch = cmdCharacteristic else {
            log("send(\(command.label)) ignored — not connected")
            return nil
        }
        if family == .whoop5 {
            return sendWhoop5(command, payload: payload, peripheral: p, characteristic: ch, writeType: writeType)
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
        return seq
    }

    /// Commands verified (from the Goose reverse-engineering) to share their command NUMBER with the 4.0
    /// and to be read-only or trivially reversible. 5.0 payloads: Goose sends these with the payloads below.
    /// Everything else (alarm, haptics, historical, raw streams) stays blocked: payloads differ or are unverified.
    private static let whoop5Allowed: [WhoopCommand: (_ payload: [UInt8]) -> [UInt8]] = [
        .toggleRealtimeHR:   { $0.isEmpty ? [0] : [$0[0]] },   // [1] on / [0] off
        .toggleGenericHRProfile: { $0.isEmpty ? [0] : [$0[0]] },   // verified live on a 5.0: result=1, then 0x2A37 packets flow
        .reportVersionInfo:  { _ in [] },   // UNSUPPORTED on fw 50.43.1.0 (E02); allowed but never sent automatically
        .getClock:           { _ in [] },
        .getBatteryLevel:    { _ in [] },   // verified E02: body[0] = percent, equals 0x2A19
        .getBatteryPackInfo: { _ in [] },   // read-only, auto in COMMAND_REGISTRY; E02: FAILURE + 01 00… with no pack attached
        .getDataRange:       { _ in [] },
        .sendHistoricalData: { _ in [] },   // history pull (see pullWhoop5History)
        .historicalDataResult: { $0 },      // HISTORY_END ack: [0x01] + end_data (see ackWhoop5HistoryChunk)
        // Alarm / haptics: payloads verified live on fw 50.43.1.0 (ALARM_CAPABILITIES.md). Fixed forms only;
        // SET takes a payload built by Whoop5Alarm.setPayload and is refused in any other shape (sendWhoop5).
        .runHapticPatternMaverick: { _ in Whoop5Alarm.notifyBuzz },
        .stopHaptics:        { _ in [0x01] },
        .setAlarmTime:       { $0 },
        .getAlarmTime:       { _ in Whoop5Alarm.getPayload() },
        .runAlarm:           { _ in Whoop5Alarm.runPayload() },
        .disableAlarm:       { _ in Whoop5Alarm.disableAllPayload },
    ]
    private var whoop5SkippedLogged = Set<UInt8>()

    private func sendWhoop5(_ command: WhoopCommand, payload: [UInt8], peripheral p: CBPeripheral,
                            characteristic ch: CBCharacteristic, writeType: CBCharacteristicWriteType) -> UInt8? {
        guard let map = BLEManager.whoop5Allowed[command] else {
            if whoop5SkippedLogged.insert(command.rawValue).inserted {
                log("send(\(command.label)) not sent on WHOOP 5.0 — its 5.0 payload/encoding is unverified (logged once)")
            }
            return nil
        }
        guard didBond else {
            log("send(\(command.label)) deferred — WHOOP 5.0 link not bonded yet")
            return nil
        }
        if command == .setAlarmTime, !(payload.count == 20 && payload[0] == 4 && payload[1] == Whoop5Alarm.alarmID) {
            log("send(Set Alarm Time) refused on WHOOP 5.0 — payload is not the verified [4, 1, time, pattern] form")
            return nil
        }
        seq = seq &+ 1
        let data = map(payload)
        let frame = buildWhoop5CommandFrame(seq: seq, command: command.rawValue, data: data)
        if command == .getClock { clockRequestSentAt[seq] = Date().timeIntervalSince1970 }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? writeType : .withResponse
        p.writeValue(Data(frame), for: ch, type: type)
        log("→ 5.0 \(command.label) seq=\(seq) payload=\(hex(data))")
        return seq
    }

    /// One-shot, read-only probe once the 5.0 link is bonded + subscribed: proves the command channel works
    /// (responses show up as "RX 5.0 … cmd-response" lines). GET_CLOCK and REPORT_VERSION_INFO only read.
    private func whoop5Probe() {
        guard family == .whoop5, !whoop5ProbeSent else { return }
        whoop5ProbeSent = true
        // REPORT_VERSION_INFO answers UNSUPPORTED on this firmware; versions come from Device Information (180A).
        log("WHOOP 5.0: reading clock and battery")
        send(.getClock, payload: [])
        send(.getBatteryLevel, payload: [])
        requestPackInfo()                         // is the charging pack on?
        lastBatteryPollAt = Date()
        if wantsRealtime { send(.toggleRealtimeHR, payload: [0x01]) }   // resume a stream the user had on before a drop
        // Show the last broadcast choice the user made (the strap can't be asked). When that choice is off, send it
        // again: a reset strap or the WHOOP app can leave the broadcast on, and it's the only way to be sure of the
        // state. Off is idempotent; the strap emits BLE_HR_PROFILE_DISABLED only if it was actually on. "On" is never
        // sent here, so a strap the user hasn't chosen to broadcast is left alone.
        if let last = UserDefaults.standard.object(forKey: BLEManager.hrBroadcastKey) as? Bool {
            if state.hrBroadcast == nil { state.hrBroadcast = last }
            if !last {
                log("HR broadcast: user's choice is off — sending off")
                send(.toggleGenericHRProfile, payload: [0x00], writeType: .withResponse)
            }
        }
        autoPullWhoop5History()
        startKeepAlive()       // battery poll + link watchdog + realtime staleness (previously never started on 5.0)
        startBackfillTimer()   // 5.0 re-pulls every backfillIntervalSeconds too (the 4.0 handshake that starts it never runs here)
    }

    /// Pull whatever the strap has stored as soon as the 5.0 link is up, so the user never has to
    /// tap "Pull stored data". Acks follow `keepDataOnStrap`, like a manual pull, and it is rate-limited
    /// with the same floor as the 4.0 connect sync.
    private func autoPullWhoop5History() {
        guard !whoop5AutoPullDone else { return }
        whoop5AutoPullDone = true
        // Let the probe responses and the settled link come first, like the 4.0 path's 1.5 s delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.state.connected, self.family == .whoop5, self.didBond else { return }
            let now = Date().timeIntervalSince1970
            let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
            guard BackfillPolicy.shouldRun(trigger: .connect, now: now, lastBackfillAt: last) else {
                self.log("History: auto-pull skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
                return
            }
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
            self.log("History: auto-pulling stored data on connect")
            self.pullWhoop5History(automatic: true)   // asks for the data range first; the range fixes the target
        }
    }
    private var whoop5ProbeSent = false

    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        guard !BLEManager.keepDataOnStrap else { return }
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
    }

    // MARK: Backfill helpers

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    private func beginBackfill() {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return
        }
        guard let backfiller else {
            // Store not ready yet. Do NOT force live HR — the type-47 backfill is the metric
            // source. Just log; the next periodic backfill tick will run once the store is ready.
            log("Backfill: store not ready — deferring to next periodic tick")
            return
        }
        backfiller.begin()
        backfilling = true
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload (re/sync_openwhoop.py, re/diagnose_biometrics.py) uses [0x00] too. Plain offload — the
        // strap streams HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
    }

    /// Feed a frame to the Backfiller preserving exact arrival order. Frames are appended
    /// synchronously (delegate order) and drained sequentially by a single task, so START /
    /// data / END chunk assembly is never reordered (Backfiller.ingest is async).
    private func routeBackfillFrame(_ frame: [UInt8]) {
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in
            while !backfillFrameQueue.isEmpty {
                let f = backfillFrameQueue.removeFirst()
                await backfiller?.ingest(f)
                afterBackfillIngest()
            }
            backfillDraining = false
        }
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8]) -> Bool {
        guard frame.count > 4 else { return false }
        switch frame[4] {
        case 47, 48, 49, 50: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60
    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        log("Backfill: session ended — reason=\(reason)")
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        }
        onStoredDataChanged?()
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
        pollBatteryIfOverdue()
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                send(.setClock, payload: BLEManager.setClockPayload())
            }
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    // MARK: - Keep-alive (always-ping + liveness watchdog)

    /// Enable the heavy realtime stream (type-40/43) and remember we want it re-armed by keep-alive.
    public func startRealtime(owner: String = "ui") {
        realtimeOwners.insert(owner)
        send(.toggleRealtimeHR, payload: [0x01])
    }
    /// Release one owner's hold on the realtime stream. Only when no owner is left is the stream stopped and the now-stale
    /// live reading dropped. HR and R-R keep being recorded by the strap and arrive with the periodic history offload.
    public func stopRealtime(owner: String = "ui") {
        realtimeOwners.remove(owner)
        guard realtimeOwners.isEmpty else { return }
        send(.toggleRealtimeHR, payload: [0x00])
        state.heartRate = nil
        state.rr = []
        state.realtimeStreaming = false
    }

    /// Turn the strap's standard HR broadcast on/off (WHOOP 4.0). The strap answers with a
    /// BLE_HR_PROFILE_ENABLED/DISABLED event, which updates `state.hrBroadcast`.
    public func setHRBroadcast(_ on: Bool) {
        // "On" is only ever sent because of this toggle: the broadcast is for OTHER devices (bike computers, watches).
        // The strap can't report its current state and only emits an event on a real change, so track the user's choice
        // here (optimistic) and remember it; a later BLE_HR_PROFILE_ENABLED/DISABLED event still overrides it.
        state.hrBroadcast = on
        UserDefaults.standard.set(on, forKey: BLEManager.hrBroadcastKey)
        send(.toggleGenericHRProfile, payload: [on ? 0x01 : 0x00], writeType: .withResponse)
    }

    // Timers use DispatchSource on the main queue and are cancelled on disconnect to avoid leaks.
    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    // Runs every 30 s: bounces a silent link, re-arms realtime, and polls battery every other tick.
    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        if Date().timeIntervalSince(lastDataAt) > 120 {
            log("No data for >120s — bouncing link to resume streaming")
            if let p = peripheral { central?.cancelPeripheralConnection(p) }
            return
        }
        // A realtime stream that stopped delivering must not leave a frozen bpm on screen — checked before the offload
        // guard below, so stale HR is cleared during a history download too (this sends nothing to the strap).
        if state.realtimeStreaming, let at = lastRealtimeAt, Date().timeIntervalSince(at) > 10 {
            state.realtimeStreaming = false
            state.heartRate = nil
            log("Realtime HR: no frame for \(Int(Date().timeIntervalSince(at))) s — cleared the live value")
        }
        guard !backfilling, !whoop5HistoryActive, !whoop5AwaitingRange else { return }   // never poke the strap mid-offload
        if wantsRealtime { send(.toggleRealtimeHR, payload: [0x01]) }   // re-arm so it can't lapse
        // The strap can't report its broadcast state and the official app re-sends "on" periodically, so keep it armed
        // while the user has it switched on (only ever the user's own choice).
        if state.hrBroadcast == true { send(.toggleGenericHRProfile, payload: [0x01], writeType: .withResponse) }
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 || Date().timeIntervalSince(lastBatteryPollAt) > 60 { pollBattery() }   // ~every 60s
    }

    /// Battery level + pack info. Read-only; never sent mid-offload (callers check).
    private func pollBattery() {
        lastBatteryPollAt = Date()
        send(.getBatteryLevel, payload: [])
        if family == .whoop5 { requestPackInfo() }
        if let c = batteryCharacteristic { peripheral?.readValue(for: c) }   // standard 0x2A19 (also covers 5.0)
    }

    /// GET_BATTERY_PACK_INFO, remembering when and on which connection it was asked.
    private func requestPackInfo() {
        if let seq = send(.getBatteryPackInfo, payload: []) { packInfoRequests[seq] = (Date(), state.connectionId) }
    }

    /// After a history download (when polling was paused), catch up an overdue battery / pack poll at once.
    private func pollBatteryIfOverdue() {
        guard state.connected, didBond, !backfilling, !whoop5HistoryActive, !whoop5AwaitingRange,
              Date().timeIntervalSince(lastBatteryPollAt) > 60 else { return }
        log("Battery: poll was paused for the download — refreshing now")
        pollBattery()
    }

    private func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    // The ONLY door to a historical offload: checks connection state, then the rate limiter, then starts it.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded || (family == .whoop5 && didBond),
            backfilling: backfilling || whoop5HistoryActive) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        if family == .whoop5 { pullWhoop5History(automatic: true); return }
        beginBackfill()
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }

    // MARK: Helpers
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
        // The unified log can be exported (sysdiagnose, Console) — redact device identifiers there.
        BLEManager.osLog.notice("\(Redactor.redact(s), privacy: .public)")
    }

    /// Redacted name for logs: WHOOP names embed part of the strap serial, so keep only the prefix.
    private func redactedName(_ n: String) -> String {
        n.lowercased().hasPrefix("whoop") ? "WHOOP-…" : "other(\(n.count) chars)"
    }
    private static func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported (no BLE hardware)"
        case .unauthorized: return "unauthorized (grant Bluetooth in System Settings ▸ Privacy & Security)"
        case .poweredOff: return "poweredOff (turn Bluetooth on)"
        case .poweredOn: return "poweredOn"
        @unknown default: return "other(\(s.rawValue))"
        }
    }
    private static func authName(_ a: CBManagerAuthorization) -> String {
        switch a {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "other(\(a.rawValue))"
        }
    }
    private func describe(_ error: Error?) -> String {
        guard let e = error as NSError? else { return "none" }
        return "\(e.domain) code=\(e.code) \"\(e.localizedDescription)\""
    }
    private static func propsName(_ p: CBCharacteristicProperties) -> String {
        var o: [String] = []
        if p.contains(.read) { o.append("read") }
        if p.contains(.write) { o.append("write") }
        if p.contains(.writeWithoutResponse) { o.append("writeNoResp") }
        if p.contains(.notify) { o.append("notify") }
        if p.contains(.indicate) { o.append("indicate") }
        return o.joined(separator: ",")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: WHOOP 5.0 stored data (history)
    //
    // Pulls the strap's stored records and saves them to the database chunk by chunk. Each saved chunk is acked
    // (HISTORICAL_DATA_RESULT) unless `keepDataOnStrap` is on. The ack is the step after which a strap discards a
    // chunk, and the strap only sends the next chunk once the previous one is acked.
    // ASSUMPTION: the 5.0 trims only on ack, as documented for the 4.0 in this repo.

    /// Ask the strap what time span it holds (read-only).
    public func queryWhoop5DataRange() {
        guard family == .whoop5, didBond else { log("Data range: needs a bonded WHOOP 5.0"); return }
        log("History: requesting data range (read-only)")
        send(.getDataRange, payload: [])
    }

    /// Start a pull. Order: GET_CLOCK + GET_DATA_RANGE → the range fixes this session's target → SEND_HISTORICAL_DATA.
    /// Chunks are saved, then acknowledged (unless `keepDataOnStrap`); see `commitWhoop5HistoryChunk` for the rules.
    /// `automatic` pulls skip the raw-frame research file.
    public func pullWhoop5History(automatic: Bool = false) {
        guard family == .whoop5, didBond, !whoop5HistoryActive, !whoop5AwaitingRange else {
            log("History pull: needs a bonded WHOOP 5.0 and no pull already running"); return
        }
        whoop5HistoryAutomatic = automatic
        whoop5SessionID += 1
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        if !automatic, let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("whoop5-history-\(stamp).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            historyCapture = try? FileHandle(forWritingTo: url)
            state.historyCaptureFile = url.lastPathComponent
        }
        historyMetaSeen = []
        historyDecoded = []
        whoop5ChunkProblem = nil
        whoop5ChunkEvents = []
        whoop5ChunkUndecoded = []
        state.historySummary = nil
        state.historyFrames = 0
        state.historyBusy = true
        state.syncSavedRows = 0
        state.syncNewestTs = nil
        state.syncSession = nil
        state.processingStatus = nil
        state.lastSyncOutcome = nil
        historySeenTs = []
        state.historyStatus = "Checking what the strap holds…"
        whoop5AwaitingRange = true
        send(.getClock, payload: [])
        send(.getDataRange, payload: [])
        // The range normally answers in ~3 s (PENDING, then the body). Without it the pull still runs, with
        // indeterminate progress, rather than not syncing at all.
        whoop5RangeWait?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.whoop5AwaitingRange else { return }
            self.log("History: no data range within 10 s — pulling without a progress target")
            self.startWhoop5Transfer(range: nil)
        }
        whoop5RangeWait = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    /// Second half of a pull, once the range is known (or given up on).
    private func startWhoop5Transfer(range: Whoop5DataRange?) {
        guard whoop5AwaitingRange else { return }
        whoop5AwaitingRange = false
        whoop5RangeWait?.cancel()
        guard state.connected, let p = peripheral, let ch = cmdCharacteristic else { endWhoop5History("not connected"); return }
        whoop5HistoryActive = true
        if let r = range {
            var session = SyncSession(localFrom: syncedThrough, strapFrom: r.lastSyncedUnix, target: r.newestUnix)
            session.begin()
            state.syncSession = session
            if let gap = session.unavailable, gap.duration > 600 {
                log("History: \(gap.duration / 60) min between the local data and the strap's oldest unsent record cannot be fetched (already handed over or aged out)")
            }
        }
        state.historyStatus = "Downloading…"
        log(BLEManager.keepDataOnStrap
            ? "History: pull started (keep-on-strap is on: no acknowledgements; the strap keeps its data)"
            : "History: pull started (each chunk is acknowledged only after it is saved; the strap then moves its trim pointer)")
        sendWhoop5(.sendHistoricalData, payload: [], peripheral: p, characteristic: ch, writeType: .withResponse)
        armHistoryIdle()
    }

    /// Undecoded history frames archived during the current pull (for the end-of-pull log line).
    private var undecodedArchived = 0
    /// Strap time of an undecoded record, if it carries one at the same place as version 0x12 (payload @7). Used only
    /// for progress; returns nil when the value is not a plausible time.
    static func undecodedRecordTime(_ frame: [UInt8]) -> Int? {
        guard let p = whoop5Payload(frame), p.count >= 11 else { return nil }
        let t = le32u(p, 7)
        return isPlausibleUnix(t) ? t : nil
    }
    private static func le32u(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// Newest strap second stored contiguously by earlier pulls (cached from the store at bootstrap).
    private var syncedThrough: Int?

    public func cancelWhoop5History() { endWhoop5History("cancelled") }

    private func armHistoryIdle() {
        historyIdleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.endWhoop5History("no more data for \(BLEManager.historyIdleSeconds)s") }
        historyIdleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.historyIdleSeconds), execute: w)
    }

    /// End the pull. `complete` = the strap sent HISTORY_COMPLETE; anything else is an early end, and the
    /// session says so (partial / failed) instead of reporting success.
    private func endWhoop5History(_ reason: String, complete: Bool = false) {
        if whoop5AwaitingRange { whoop5AwaitingRange = false; whoop5RangeWait?.cancel() }
        guard whoop5HistoryActive || state.historyBusy else { return }
        whoop5HistoryActive = false
        whoop5SessionID += 1          // any chunk task still running for this pull will not ack
        historyIdleWork?.cancel()
        try? historyCapture?.close(); historyCapture = nil
        state.historyBusy = false
        state.historyStatus = "Captured \(state.historyFrames) frames (\(reason)). "
            + (BLEManager.keepDataOnStrap ? "Nothing was acknowledged, so the strap kept everything."
                                          : "Saved chunks were acknowledged, which moves the strap's trim pointer.")
        let leftover = historyDecoded
        historyDecoded = []
        let events = whoop5ChunkEvents
        whoop5ChunkEvents = []
        if !whoop5ChunkUndecoded.isEmpty {
            // Not acknowledged (no END followed), but archive anyway: harmless if the strap re-sends them.
            try? rawArchive?.append(whoop5ChunkUndecoded)
            whoop5ChunkUndecoded = []
        }
        if undecodedArchived > 0 { log("History: \(undecodedArchived) undecoded record(s) archived this pull (Application Support/OpenWhoop/undecoded-history)") }
        undecodedArchived = 0
        log("History: pull ended — \(reason); frames=\(state.historyFrames); chunks=\(historyMetaSeen.filter { $0 == "END" }.count)")
        if reason != "disconnected" { pollBatteryIfOverdue() }
        Task { @MainActor in
            // Records after the last END were not acknowledged (the strap re-sends them next time); save them anyway.
            _ = await self.persistWhoop5Records(leftover, events: events)
            if complete {
                self.state.syncSession?.downloadFinished()
                self.onSyncDownloadFinished?(true)
            } else {
                self.state.syncSession?.end(early: reason)
                self.state.lastSyncOutcome = "Sync stopped: \(reason)"
                self.onSyncDownloadFinished?(false)
            }
            self.onStoredDataChanged?()
        }
    }

    /// Save decoded records (+ the chunk's events) in one database transaction. Returns new heart-rate rows, nil on failure.
    private func persistWhoop5Records(_ recs: [Whoop5HistoricalRecord], events: [WhoopEvent]) async -> Int? {
        guard !recs.isEmpty || !events.isEmpty else { return 0 }
        let hr = recs.filter { (30...220).contains($0.heartRate) }.map { HRSample(ts: $0.timestamp, bpm: $0.heartRate) }
        let rr = recs.flatMap { r in r.rr.map { RRInterval(ts: r.timestamp, rrMs: $0) } }
        let grav = recs.compactMap { r in r.gravity.map { GravitySample(ts: r.timestamp, x: $0.x, y: $0.y, z: $0.z) } }
        guard let n = await collector?.persistDecodedHistory(Streams(hr: hr, rr: rr, gravity: grav, events: events)) else {
            return nil
        }
        state.syncSavedRows += n
        if !recs.isEmpty {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        }
        return n
    }

    /// HISTORY_END: the chunk since the previous END is complete. Acknowledgement rules (SAFETY_MATRIX → History acks):
    /// 1. Never ack a chunk holding a frame NOOP cannot store (unknown record version, historical IMU): the pull stops,
    ///    the strap keeps the chunk.
    /// 2. Save first: records + events in one SQLite transaction; ack only once that commit returned.
    /// 3. Ack only for the pull that received the END (session id), with end_data from this CRC-checked END frame.
    /// 4. Never ack when "keep data on strap" is on (the strap then stops after one chunk — the cost of keeping it).
    /// The ack is what lets the strap send the next chunk; it also moves the strap's trim pointer (firmware log),
    /// and whether trimmed records stay readable is UNKNOWN — so a local save is NOT a guarantee the strap keeps a copy.
    private func commitWhoop5HistoryChunk(_ frame: [UInt8]) {
        let recs = historyDecoded
        historyDecoded = []
        let events = whoop5ChunkEvents
        whoop5ChunkEvents = []
        let undecoded = whoop5ChunkUndecoded
        whoop5ChunkUndecoded = []
        var problem = whoop5ChunkProblem
        whoop5ChunkProblem = nil
        if !undecoded.isEmpty {
            do {
                guard let archive = rawArchive else { throw CocoaError(.fileNoSuchFile) }
                try archive.append(undecoded)
                undecodedArchived += undecoded.count
            } catch {
                problem = "\(undecoded.count) undecoded record(s) could not be archived (\(error.localizedDescription))"
            }
        }
        let session = whoop5SessionID
        guard case .end(_, let endData)? = Whoop5HistoryMeta.decode(frame) else {
            log("History: END frame could not be decoded — not acknowledging")
            return
        }
        if let problem {
            log("History: chunk not acknowledged — \(problem). The strap keeps it; stopping this pull.")
            Task { @MainActor in
                _ = await self.persistWhoop5Records(recs, events: events)   // keep what could be decoded
                self.endWhoop5History("unrecognised data in a chunk (\(problem))")
            }
            return
        }
        Task { @MainActor in
            guard let n = await self.persistWhoop5Records(recs, events: events) else {
                self.log("History: chunk NOT saved (store unavailable) — not acknowledging")
                self.endWhoop5History("could not save to the database")
                return
            }
            guard session == self.whoop5SessionID, self.whoop5HistoryActive else {
                self.log("History: chunk saved after its pull ended — not acknowledging (the strap re-sends it next pull)")
                return
            }
            // Archived-but-undecoded records count as accounted for in time too (the strap won't send them again).
            let times = recs.map(\.timestamp) + undecoded.compactMap(Self.undecodedRecordTime)
            self.state.syncSession?.chunkSaved(recordTimes: times, newRows: n)
            if let frontier = self.state.syncSession?.savedFrontier ?? times.max() {
                self.syncedThrough = max(self.syncedThrough ?? 0, frontier)
                await self.collector?.setCursor(BLEManager.syncedThroughCursor, self.syncedThrough ?? frontier)
            }
            self.onStoredDataChanged?()
            guard !BLEManager.keepDataOnStrap else { return }
            self.send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
            if self.historyEndLogged < 3 {
                self.historyEndLogged += 1
                self.log("History: chunk saved (\(recs.count) records, \(n) new, \(undecoded.count) archived undecoded) — acked end_data=\(self.hex(endData))")
            }
        }
    }

    /// Called for every complete, CRC-valid 5.0 frame while a pull is active.
    private func captureWhoop5HistoryFrame(_ frame: [UInt8], on characteristic: CBCharacteristic) {
        guard whoop5HistoryActive, frame.count > 12 else { return }
        let type = frame[8]
        // 47 historical data, 52 historical IMU, 49/56 metadata, 48/53/54 events, 50/55 console — everything except the live stream.
        guard [47, 52, 49, 56, 48, 53, 54, 50, 55].contains(type) else { return }
        armHistoryIdle()
        state.historyFrames += 1
        switch type {
        case 47:
            if let rec = decodeWhoop5Historical(frame) {
                // The strap re-sends an unacked chunk on retry; the DB also enforces uniqueness (deviceId, ts).
                if historySeenTs.insert(rec.timestamp).inserted {
                    historyDecoded.append(rec)
                    if rec.timestamp > (state.syncNewestTs ?? 0) { state.syncNewestTs = rec.timestamp }
                }
            } else {
                whoop5ChunkUndecoded.append(frame)   // e.g. version 0x1a: kept verbatim, decoded later
            }
        case 52:
            whoop5ChunkUndecoded.append(frame)
        case 48:
            if case .success(let e) = Whoop5Event.decode(frame) { whoop5ChunkEvents.append(storedEvent(e)) }
        case 49, 56:
            switch Whoop5HistoryMeta.decode(frame) {
            case .start?: historyMetaSeen.append("START")
            case .end?:
                historyMetaSeen.append("END")
                commitWhoop5HistoryChunk(frame)
            case .complete?:
                historyMetaSeen.append("COMPLETE")
                endWhoop5History("strap reported HISTORY_COMPLETE", complete: true)
            case .other(let k)?:
                historyMetaSeen.append("kind\(k)")
                log("History: metadata kind \(k) (not START/END/COMPLETE) — ignored")
            case nil:
                log("History: metadata frame could not be decoded (len \(frame.count))")
            }
        default:
            break
        }
        if whoop5HistoryAutomatic { return }
        if state.historyFrames <= BLEManager.historyMaxCapturedFrames {
            // Console text carries Bluetooth addresses: keep it only redacted in the research file.
            let body: String
            if type == 50 || type == 55 {
                let text = String(decoding: frame.dropFirst(19).dropLast(4).filter { $0 != 0 }, as: UTF8.self)
                body = "\"text\":\(jsonString(Redactor.redact(text)))"
            } else {
                body = "\"hex\":\"\(hex(frame))\""
            }
            let line = "{\"t\":\(Date().timeIntervalSince1970),\"ch\":\"\(characteristic.uuid.uuidString.prefix(8))\",\"type\":\(type),\"len\":\(frame.count),\(body)}\n"
            historyCapture?.write(Data(line.utf8))
        }
    }

    private func jsonString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }

    /// Strap event as a stored row: the raw body is always kept, so unknown events can be studied later.
    private func storedEvent(_ e: Whoop5Event) -> WhoopEvent {
        WhoopEvent(ts: e.unix, kind: e.kind.name,
                   payload: ["event": .int(e.number), "subsec": .int(e.subseconds), "body": .string(hex(e.body))])
    }

    /// Typed handling of a final GET_DATA_RANGE answer.
    private func handleWhoop5DataRange(_ r: Whoop5DataRange) {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        func d(_ t: Int) -> String { f.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }
        state.historyRange = "\(d(r.oldestUnix)) → \(d(r.newestUnix))"
        state.syncRangeLo = r.lastSyncedUnix
        state.syncRangeHi = r.newestUnix
        strapNewestTs = r.newestUnix
        log("History: strap holds \(d(r.oldestUnix)) → \(d(r.newestUnix)); last synced \(d(r.lastSyncedUnix)); trim page \(r.trimPage)/\(r.trimBlock)")
        if whoop5AwaitingRange { startWhoop5Transfer(range: r) }
    }

    // MARK: Alarm API (M6 — additive; does NOT touch connect/offload/sync flows)

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// Sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then SET_ALARM_TIME.
    /// The strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the guaranteed fixed-time fallback path —
    /// the smart-wake layer (`SmartAlarmController`) fires on top of this if conditions are met,
    /// but this firmware alarm always fires as the safety net.
    ///
    /// On-device verification needed: confirm the strap ACKs SET_ALARM_TIME and that the
    /// alarm persists across BLE disconnect (cannot be verified in the simulator).
    // Strap alarm: write the wake time to the strap so it buzzes without the phone.
    func armStrapAlarm(at date: Date) {
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        send(.setClock, payload: BLEManager.setClockPayload())
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        log("Alarm: armed for \(date) (epoch \(epochSec))")
    }

    // Wake-alarm commands go through `AlarmStrapLink` (below): AlarmController serializes SET / GET / RUN and matches each
    // answer by its sequence number, so nothing here reports an alarm as stored or rung.
    /// Strap seconds now, from the clock estimate.
    func strapNow() -> Int? { state.clock.map { Int($0.deviceTime(fromHost: Date().timeIntervalSince1970).rounded()) } }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// Fire an immediate alarm buzz on the strap for testing.
    ///
    /// Uses RUN_HAPTICS_PATTERN (cmd 79) with patternId=2, 3 loops — the same pattern the official
    /// WHOOP app uses for alarms (verified: patternId=2, observed for interoperability), plus RUN_ALARM
    /// (cmd 68) as a belt-and-suspenders. patternId=2 gives the characteristic graduated alarm buzz.
    ///
    /// Alternative waveform form (12-byte):
    ///   [wfe1=47, wfe2=152, 0,0,0,0,0,0, loop u16=0, overall_loop=7, dur=30]
    /// — note for future refinement; the preset id=2 form is simpler and confirmed to buzz on-device.
    ///
    /// Haptic firing cannot be verified in the simulator (no strap motor). Test on-device only.
    func testAlarmBuzz() {
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0])  // patternId=2, 3 loops
        send(.runAlarm, payload: [0x01])
        log("Alarm: test buzz fired (patternId=2, runAlarm)")
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else { return }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present.
        if !m.rr.isEmpty { state.rr = m.rr }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value.
        if m.hr >= 30 && m.hr <= 220 { state.heartRate = m.hr }
        // Record it continuously — independent of the realtime stream or the open screen.
        // 0x2A37 has no timestamp: it is stamped on arrival (Mac clock). Stored samples use the STRAP clock (history
        // records), so convert with the measured offset; otherwise the same beat lands twice, ~15 s apart, and is
        // counted twice. Without an estimate (4.0, or before GET_CLOCK) the Mac time is used as before.
        let now = Date().timeIntervalSince1970
        let ts = state.clock.map { Int($0.deviceTime(fromHost: now).rounded()) } ?? Int(now)
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: ts)
    }
}

// MARK: - Alarm link (AlarmController)
extension BLEManager: AlarmStrapLink {
    var alarmLinkReady: Bool { family == .whoop5 && didBond && state.connected }
    var alarmClock: ClockEstimate? { state.clock }
    func sendAlarmCommand(_ c: AlarmStrapCommand) -> UInt8? {
        guard alarmLinkReady else { return nil }
        switch c {
        case .set(let secs): return send(.setAlarmTime, payload: Whoop5Alarm.setPayload(strapSeconds: secs), writeType: .withResponse)
        case .get: return send(.getAlarmTime, payload: [], writeType: .withResponse)
        case .run: return send(.runAlarm, payload: [], writeType: .withResponse)
        case .disableAll: return send(.disableAlarm, payload: [], writeType: .withResponse)
        }
    }
    func acquireRealtime(owner: String) { startRealtime(owner: owner) }
    func releaseRealtime(owner: String) { stopRealtime(owner: owner) }
}

// MARK: - WHOOP 5.0 frame handling
// Every 5.0 frame goes through the typed decoders in WhoopProtocol/Whoop5Messages; nothing here indexes frames by hand.
extension BLEManager {
    func handleWhoop5Frame(_ frame: [UInt8], on characteristic: CBCharacteristic) {
        let chk = verifyFrame(frame, family: .whoop5)
        guard chk.ok else {
            // Never silently dropped: a corrupt frame is logged (counts only) and never reaches state or the store.
            log("RX 5.0 frame failed CRC on \(characteristic.uuid.uuidString.prefix(8)): len=\(frame.count) header=\(chk.crc8OK.map(String.init) ?? "?") payload=\(chk.crc32OK.map(String.init) ?? "?")")
            return
        }
        let type = frame[8]
        if let r = Whoop5CommandResponse.decode(frame) {
            handleWhoop5Response(r)
        } else if type == 48 {
            switch Whoop5Event.decode(frame) {
            case .success(let e): handleWhoop5Event(e)
            case .failure(let err): log("RX 5.0 event could not be decoded: \(err) len=\(frame.count)")
            }
        } else if type == 40 {
            handleWhoop5Realtime(frame)
        }
        captureWhoop5HistoryFrame(frame, on: characteristic)
    }

    private func handleWhoop5Response(_ r: Whoop5CommandResponse) {
        let name = WhoopCommand(rawValue: r.command)?.label ?? "cmd \(r.command)"
        if r.command != 23 || r.result != .success {      // per-chunk ack confirmations are too frequent to log
            log("RX 5.0 \(name) seq=\(r.appSeq) → \(r.result)\(r.body.count > 3 ? " (\(r.body.count) B)" : "")")
        }
        switch r.command {
        case 11:
            let sent = clockRequestSentAt.removeValue(forKey: r.appSeq)
            guard r.isFinal else { return }
            switch Whoop5Clock.decode(r) {
            case .success(let c):
                guard let sent else { return }   // another client's request: no send time to pair it with
                handleClockSample(ClockSample(hostSent: sent, hostReceived: Date().timeIntervalSince1970, device: c.seconds))
            case .failure(let e): log("Clock: reply not usable (\(e))")
            }
        case 34:
            guard r.isFinal else { return }
            switch Whoop5DataRange.decode(r) {
            case .success(let range): handleWhoop5DataRange(range)
            case .failure(let e):
                log("History: data range not usable (\(e))")
                if whoop5AwaitingRange { startWhoop5Transfer(range: nil) }
            }
        case 26:
            if let pct = whoop5BatteryPercent(r) {
                state.updateBattery(BatteryReading(percent: pct, charging: nil, at: Date().timeIntervalSince1970, source: .vendorCommand))
            }
        case Whoop5Charging.packInfoCommand:
            guard r.isFinal else { return }
            let req = packInfoRequests.removeValue(forKey: r.appSeq)
            guard let req, let reply = Whoop5Charging.packInfo(r) else { return }   // not our request: no time to bind it to
            let before = state.charging.attached(now: Date())
            state.applyPackInfo(reply, requestedAt: req.at, connection: req.connection)
            if reply != .detached { log("Battery pack: reply \(reply) — attachment left unknown") }
            else if before != .no { log("Battery pack: not attached (verified reply shape)") }
        case 3:
            if r.result != .success { state.realtimeStreaming = false }
        case 14:
            if r.result != .success { log("HR broadcast: strap answered \(r.result)") }
        case 19, 66, 67, 68, 69, 122:
            log("Alarm: \(name) → \(r.result) status=\(Whoop5Alarm.status(r).map { "\($0)" } ?? "-")")
            onAlarmResponse?(r)
        default:
            break
        }
    }

    private func handleClockSample(_ sample: ClockSample) {
        switch clockEstimator.add(sample) {
        case .accepted(let est):
            state.clock = est
            log(String(format: "Clock: strap is %.1f s %@ this Mac (±%.1f s)", abs(est.offset), est.offset >= 0 ? "behind" : "ahead of", est.uncertainty))
            persistClock(est)
        case .jumped(let from, let to):
            state.clock = to
            log(String(format: "Clock: strap clock jumped (offset %.1f s → %.1f s); new estimate in use", from.offset, to.offset))
            persistClock(to)
        case .rejected(let why):
            log("Clock: sample rejected (\(why)); keeping the previous estimate")
        }
    }

    private func persistClock(_ e: ClockEstimate) {
        Task { @MainActor in
            await collector?.setCursor(BLEManager.clockOffsetCursor, Int((e.offset * 1000).rounded()))
            await collector?.setCursor(BLEManager.clockMeasuredCursor, Int(e.measuredAt))
        }
    }

    /// Events: always recorded for diagnostics (unknown numbers included). Only events that are LIVE — stamped
    /// within two minutes of the strap's current time — change UI state; the same event replayed in a history
    /// pull hours later must not.
    private func handleWhoop5Event(_ e: Whoop5Event) {
        let line = "\(e.kind.name) at \(Date(timeIntervalSince1970: TimeInterval(e.unix)).formatted(date: .omitted, time: .standard)) body=\(e.body.count) B"
        state.record(event: line)
        state.lastEvent = e.kind.name
        // LIVE = stamped within two minutes of the strap's current time. A replayed (history) copy only enriches alarm
        // history at its original time; it never changes current state.
        let live = state.clock.map { abs($0.deviceTime(fromHost: Date().timeIntervalSince1970) - Double(e.unix)) < 120 } ?? false
        switch e.kind {
        case .alarmSet, .strapAlarmExecuted, .appAlarmExecuted, .alarmDisabled, .hapticsFired, .hapticsTerminated, .doubleTap:
            onAlarmEvent?(e, live)
        default: break
        }
        guard live, let clock = state.clock else { return }
        log("RX 5.0 live event \(e.kind.name)")
        if Whoop5Charging.isChargingEvent(e.kind) {
            let eventAt = Date(timeIntervalSince1970: clock.hostTime(fromDevice: Double(e.unix) + Double(e.subseconds) / 32768))
            state.applyChargingEvent(e.kind, eventAt: min(eventAt, Date()))
        }
        switch e.kind {
        case .hrProfileEnabled: state.hrBroadcast = true
        case .hrProfileDisabled: state.hrBroadcast = false
        case .realtimeHROff: state.realtimeStreaming = false
        default: break
        }
    }

    /// Realtime HR (type 40, CONFIRMED E04): one frame per strap second. Duplicates and implausible values are dropped;
    /// realtime HR is display-only and never written to the database (history supplies the stored series).
    private func handleWhoop5Realtime(_ frame: [UInt8]) {
        guard let rt = decodeWhoop5Realtime(frame) else {
            log("RX 5.0 realtime frame rejected (implausible timestamp) len=\(frame.count)")
            return
        }
        if let last = lastRealtimeSecond, rt.timestamp <= last { return }   // duplicate or out-of-order second
        lastRealtimeSecond = rt.timestamp
        let received = Date()
        lastRealtimeAt = received
        state.realtimeStreaming = true
        if (30...220).contains(rt.heartRate) { state.heartRate = rt.heartRate }
        // Measured at the strap second (mapped with the clock estimate); without one, stamped on arrival.
        let at = state.clock.map { Date(timeIntervalSince1970: $0.hostTime(fromDevice: Double(rt.timestamp))) } ?? received
        onRealtimeHR?(HRObservation(at: at, bpm: rt.heartRate, receivedAt: received))
    }
}

// MARK: - CBCentralManagerDelegate
// Connection lifecycle: Bluetooth state, discovery, connect/disconnect and state restoration.
extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(BLEManager.stateName(central.state)); authorization=\(BLEManager.authName(CBCentralManager.authorization))")
        rememberAuthorization()
        guard central.state == .poweredOn else { return }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                p.discoverServices([
                    BLEManager.customService, BLEManager.heartRateService, BLEManager.batteryService,
                ])
            }
        } else {
            connect()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let advSvcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if unfilteredScan {
            unfilteredSeen += 1
            // Only WHOOP-named devices are acceptable in the unfiltered scan; never connect to others.
            guard name.lowercased().hasPrefix("whoop") else { return }
        }
        let gen = advSvcs.contains(BLEManager.whoop5Service) ? "5.0 service"
            : advSvcs.contains(BLEManager.customService) ? "4.0 service" : "no WHOOP service in adv"
        log("Discovered \(redactedName(name)) rssi=\(RSSI) adv=[\(gen)] connectable=\(advertisementData[CBAdvertisementDataIsConnectable] ?? "?") (unfilteredSeen=\(unfilteredSeen))")
        adopt(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        restoredPeripheral = nil
        stalePairingFailures = 0
        state.pairingStale = false
        state.connected = true
        state.beginConnection()          // charging facts from a previous connection never carry over
        state.nextReconnectAt = nil
        log("Connected — discovering services")
        // nil = discover everything so the log shows what this strap actually exposes (4.0 vs 5.0).
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        state.connected = false
        state.bonded = false
        state.resetTelemetry()
        endWhoop5History("disconnected")
        strapFrameTotal = 0
        lastRealtimeSecond = nil
        lastRealtimeAt = nil
        packInfoRequests.removeAll()
        onLinkDropped?()
        clockRequestSentAt.removeAll()
        heartRateCharacteristic = nil
        helloWatchdog?.cancel()
        reassembler.reset()
        whoop5Chars = []
        whoop5SetupAttempts = 0
        whoop5RetryPending = false
        whoop5ExhaustedLogged = false
        whoop5ProbeSent = false
        whoop5AutoPullDone = false
        whoop5Reassemblers.removeAll()
        rxFragmentCount = 0
        whoop5SkippedLogged.removeAll()
        cmdCharacteristic = nil
        self.peripheral = nil
        didBond = false
        clockRequested = false
        connectHandshakeDone = false
        // Reset backfill state so the next connect starts a fresh offload.
        backfillStarted = false
        backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
        if !intentionalDisconnect {
            log("Disconnected: \(describe(error)); rescanning in 3s, then retrying every 15 min while the app is open")
            if reconnectTimer != nil { startReconnectTimer() }   // first periodic attempt 15 min after the loss
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect, self.peripheral == nil else { return }
                self.connect()
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        self.peripheral = nil
        if let e = error as NSError?, e.domain == CBErrorDomain,
           e.code == CBError.peerRemovedPairingInformation.rawValue {
            stalePairingFailures += 1
            if stalePairingFailures >= 2 {
                // Retrying can't fix this: macOS keeps a bond the strap no longer recognises, and
                // CoreBluetooth has no API to drop it. Stop the loop and let the UI guide the user.
                log("Failed to connect: \(describe(error)). The strap forgot its pairing with this Mac — "
                    + "toggle Bluetooth off/on (or restart bluetoothd), then retry. Auto-retry paused.")
                state.pairingStale = true
                scanFallbackWork?.cancel()
                central.stopScan()
                return
            }
        }
        log("Failed to connect: \(describe(error)); rescanning in 3s")
        guard !intentionalDisconnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.intentionalDisconnect, self.peripheral == nil else { return }
            self.connect()
        }
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        didBond = true
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        clockRequested = false
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral — re-discovering services")
            p.discoverServices([
                BLEManager.customService, BLEManager.heartRateService, BLEManager.batteryService,
            ])
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate
// Data path: service discovery, characteristic subscription and incoming notifications.
extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("Service discovery failed: \(describe(error))") }
        guard let services = peripheral.services else { return }
        log("Services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        if services.contains(where: { $0.uuid == BLEManager.whoop5Service }) {
            family = .whoop5
        } else if services.contains(where: { $0.uuid == BLEManager.customService }) {
            family = .whoop4
        } else {
            log("No WHOOP 4.0 (6108…) or 5.0 (fd4b…) service on this peripheral — not a supported WHOOP, or the strap is in a different mode")
        }
        reassembler = Reassembler(family: family)
        state.family = family.rawValue
        log("Detected family: \(family.rawValue)")
        for s in services {
            switch s.uuid {
            case BLEManager.whoop5Service:
                // nil = all characteristics, so unexpected ones (and their properties) show up in the log.
                peripheral.discoverCharacteristics(nil, for: s)
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.disService:
                // Model / firmware / hardware / serial: static, read once per connection (replaces REPORT_VERSION_INFO).
                peripheral.discoverCharacteristics(nil, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error { log("Characteristic discovery failed for \(service.uuid): \(describe(error))") }
        guard let chars = service.characteristics else { return }
        log("Characteristics of \(service.uuid): " + chars.map { "\($0.uuid.uuidString)[\(BLEManager.propsName($0.properties))]" }.joined(separator: " "))
        if service.uuid == BLEManager.whoop5Service {
            setUpWhoop5(peripheral, chars)
            return
        }
        if service.uuid == BLEManager.disService {
            for c in chars where c.properties.contains(.read) { peripheral.readValue(for: c) }
            return
        }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                if c.uuid == BLEManager.heartRateChar {
                    // The standard HR broadcast belongs to OTHER devices (bike computers, watches). A strap serves it to
                    // one listener, so NOOP stays off it unless the user opts in; our HR/R-R come from the WHOOP data channel.
                    guard BLEManager.listensToBroadcast else {
                        log("Leaving standard heart-rate broadcast (2A37) free for other devices")
                        break
                    }
                    heartRateCharacteristic = c
                }
                peripheral.setNotifyValue(true, for: c)
                if c.uuid == BLEManager.batteryChar {
                    // Notify-only fires on CHANGE; read once now so the level shows immediately.
                    batteryCharacteristic = c
                    peripheral.readValue(for: c)
                }
                log("Subscribed \(c.uuid)")
            default: break
            }
        }
    }

    /// WHOOP 5.0 session start: subscribe to every notify/indicate characteristic, then write the static
    /// CLIENT_HELLO (b-nnett/goose) to fd4b0002. Hello is written WITH response when the characteristic
    /// allows it so an encryption/pairing requirement surfaces as an ATT error we can log (and macOS can
    /// show its pairing prompt). Beyond hello, 5.0 command encoding is not implemented.
    private func setUpWhoop5(_ peripheral: CBPeripheral, _ chars: [CBCharacteristic]) {
        whoop5Chars = chars
        whoop5SetupAttempts += 1
        log("WHOOP 5.0 setup attempt \(whoop5SetupAttempts)/\(BLEManager.whoop5MaxSetupAttempts)")
        for c in chars where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: c)
        }
        guard let cmd = chars.first(where: { $0.uuid == BLEManager.whoop5CmdWriteChar }) else {
            log("WHOOP 5.0 command characteristic fd4b0002 not found — cannot send CLIENT_HELLO")
            return
        }
        cmdCharacteristic = cmd
        let props = cmd.properties
        let type: CBCharacteristicWriteType = props.contains(.write) ? .withResponse : .withoutResponse
        guard props.contains(.write) || props.contains(.writeWithoutResponse) else {
            log("fd4b0002 is not writable (props=\(BLEManager.propsName(props)))")
            return
        }
        log("WHOOP 5.0: writing CLIENT_HELLO (16 bytes, \(type == .withResponse ? "with" : "without") response)")
        peripheral.writeValue(Data(DeviceFamily.whoop5ClientHello), for: cmd, type: type)
        if type == .withoutResponse { markWhoop5Hello() }
        helloWatchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state.connected, self.family == .whoop5, self.rxFrameCount == 0 else { return }
            self.log("WHOOP 5.0: no frame received \(BLEManager.helloResponseTimeoutSeconds)s after CLIENT_HELLO — the strap may need pairing/bonding, a different hello, or it is held by another app")
        }
        helloWatchdog = w
        rxFrameCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.helloResponseTimeoutSeconds), execute: w)
    }

    /// ATT 5 (insufficient authentication) / 15 (insufficient encryption): the strap wants a bonded link.
    /// macOS starts pairing on the first protected access (a system dialog may appear) and that first
    /// access fails; retry after a delay so the now-encrypted link can succeed.
    private func isAuthError(_ error: Error?) -> Bool {
        guard let e = error as NSError?, e.domain == CBATTErrorDomain else { return false }
        return e.code == CBATTError.insufficientAuthentication.rawValue
            || e.code == CBATTError.insufficientEncryption.rawValue
    }

    private func scheduleWhoop5Retry() {
        guard family == .whoop5, !whoop5RetryPending, let p = peripheral else { return }
        guard whoop5SetupAttempts < BLEManager.whoop5MaxSetupAttempts else {
            guard !whoop5ExhaustedLogged else { return }
            whoop5ExhaustedLogged = true
            log("WHOOP 5.0: still 'authentication insufficient' after \(whoop5SetupAttempts) attempts — pairing did not complete. "
                + "Accept any macOS pairing dialog; otherwise remove the strap from System Settings ▸ Bluetooth and from your phone's WHOOP/Bluetooth pairing, then retry. "
                + "(Assumption: a strap bonded to another device may refuse a second bond.)")
            return
        }
        whoop5RetryPending = true
        log("WHOOP 5.0: link needs pairing/encryption — watch for a macOS pairing prompt; retrying in \(BLEManager.whoop5RetryDelaySeconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.whoop5RetryDelaySeconds)) { [weak self] in
            guard let self else { return }
            self.whoop5RetryPending = false
            guard self.state.connected, self.family == .whoop5, !self.didBond, !self.whoop5Chars.isEmpty else { return }
            self.setUpWhoop5(p, self.whoop5Chars)
        }
    }

    private func markWhoop5Hello() {
        guard !didBond else { return }
        didBond = true
        state.bonded = true
        log("WHOOP 5.0: CLIENT_HELLO accepted by the link (this proves the write completed, not that the strap understood it)")
        // The notify subscriptions may have been requested BEFORE the bond finished and failed with an
        // auth error. Now that the link is encrypted, re-subscribe any that aren't live, then resend the
        // hello once so its response can actually be received.
        guard let p = peripheral else { return }
        // The standard heart-rate subscription was made before the link was encrypted; toggle it again now
        // that the bond is in place (harmless, and some peripherals only start notifying after this).
        if let hr = heartRateCharacteristic {
            log("WHOOP 5.0: re-enabling standard heart-rate notifications after bonding")
            p.setNotifyValue(false, for: hr)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.state.connected, let p = self.peripheral else { return }
                p.setNotifyValue(true, for: hr)
            }
        }
        let missing = whoop5Chars.filter {
            ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) && !$0.isNotifying
        }
        guard !missing.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.whoop5Probe() }
            return
        }
        log("WHOOP 5.0: link encrypted — re-subscribing \(missing.count) characteristic(s), then resending CLIENT_HELLO")
        for c in missing { p.setNotifyValue(true, for: c) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.state.connected, self.family == .whoop5,
                  let cmd = self.cmdCharacteristic, let p = self.peripheral else { return }
            let type: CBCharacteristicWriteType = cmd.properties.contains(.write) ? .withResponse : .withoutResponse
            self.log("WHOOP 5.0: resending CLIENT_HELLO after re-subscribe")
            p.writeValue(Data(DeviceFamily.whoop5ClientHello), for: cmd, type: type)
            self.rxFrameCount = 0
            self.helloWatchdog?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.state.connected, self.family == .whoop5, self.rxFrameCount == 0 else { return }
                self.log("WHOOP 5.0: bonded and subscribed, but still no frame \(BLEManager.helloResponseTimeoutSeconds)s after hello — the hello may not be what this firmware expects")
            }
            self.helloWatchdog = w
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.helloResponseTimeoutSeconds), execute: w)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.whoop5Probe() }
        }
    }

    /// Confirmed-write completion = bonding succeeded (no error).
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write to \(characteristic.uuid) failed: \(describe(error))")
            if isAuthError(error) { scheduleWhoop5Retry() }
            return
        }
        if family == .whoop5 {
            // 4.0 handshake (HELLO_HARVARD / SET_CLOCK / historical offload) is 4.0-framed — never run it here.
            markWhoop5Hello()
            return
        }
        if !didBond {
            didBond = true
            state.bonded = true
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor re-fires on EVERY
        // .withResponse write — the bond write, every SEND_HISTORICAL, every HISTORY_END ack. Without
        // this guard those re-entries re-sent hello/SET_CLOCK at the strap *during* the offload and
        // stopped it from streaming type-47. This was THE iOS-side root cause: the Mac prototype pulls
        // type-47 fine because it runs the sequence once on a stable connection; the app stormed it.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        send(.setClock, payload: BLEManager.setClockPayload())
        if clockRef == nil && !clockRequested {
            clockRequested = true
            send(.getClock, payload: [])   // the strap expects GET_CLOCK with an EMPTY payload;
                                           // the app's old default [0x00] is a wrong length the strap ignores.
                                           // (Offload no longer depends on this — Backfiller falls back to an
                                           // identity clockRef — but a real correlation helps realtime decode.)
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
    }

    /// SET_CLOCK(10) payload = the strap's 8-byte form: [seconds u32 LE][subseconds
    /// u32 LE], subseconds in 1/32768 s (0 is fine). NOT the old 9-byte [u32 + 5 pad] — a wrong-length
    /// SET_CLOCK is ack-received but NOT latched, leaving the RTC lost so the strap won't serve type-47.
    // SET_CLOCK payload: current unix time, little-endian, so the strap's timestamps line up with ours.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { newest = max(newest ?? 0, w) }
            i += 4
        }
        return newest
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification
        // UI telemetry (throttled to ~1 Hz so it can't flood SwiftUI): when did data last arrive?
        if state.lastDataAt.map({ lastDataAt.timeIntervalSince($0) >= 1 }) ?? true { state.lastDataAt = lastDataAt }

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            state.hrPackets += 1
            if state.hrPackets == 1 { log("First standard heart-rate packet received (\(bytes.count) bytes)") }
            parseStandardHR(bytes)
        case BLEManager.batteryChar:
            if let pct = bytes.first, pct <= 100 {                    // 0x2A19 = percent
                state.updateBattery(BatteryReading(percent: Int(pct), charging: nil,
                                                   at: Date().timeIntervalSince1970, source: .standardLevel))
            }
        case _ where characteristic.service?.uuid == BLEManager.disService:
            handleDeviceInfo(characteristic.uuid.uuidString, bytes)
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar,
             _ where family == .whoop5 && characteristic.service?.uuid == BLEManager.whoop5Service:
            // 5.0: each characteristic is its own byte stream, so reassemble per characteristic.
            let asm: Reassembler
            if family == .whoop5 {
                if let existing = whoop5Reassemblers[characteristic.uuid] { asm = existing }
                else { asm = Reassembler(family: .whoop5); whoop5Reassemblers[characteristic.uuid] = asm }
                if rxFragmentCount < 10 {
                    rxFragmentCount += 1
                    log("RX 5.0 fragment on \(characteristic.uuid.uuidString.prefix(8)): \(bytes.count) bytes")
                }
            } else { asm = reassembler }
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            for frame in asm.feed(bytes) {
                strapFrameTotal += 1
                if strapFrameTotal <= 20 || strapFrameTotal % 10 == 0 { state.strapFrames = strapFrameTotal }
                if family == .whoop5 {
                    rxFrameCount += 1
                    handleWhoop5Frame(frame, on: characteristic)
                    continue
                }
                router.handle(frame: frame)                       // UI (always)
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue,
                   let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                    strapNewestTs = newest                        // feeds the liveness watchdog
                }
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            send(.setClock, payload: BLEManager.setClockPayload())
                        }
                    }
                }
                if backfilling {
                    // Historical offload path: route ONLY genuine offload frames (47/48/49/50)
                    // through the serial drain (preserves START/data/END chunk order) and re-arm the
                    // idle watchdog on them. The live type-40/43 flood (esp. the ~2/s, ~1.9 KB type-43
                    // raw) is IGNORED by extractHistoricalStreams, so feeding it to the drain only
                    // delays each chunk's insert→trim-ack — the strap then stalls waiting for the ack
                    // and the 20 s watchdog fires (the residual timeout). Drop the flood during offload.
                    if BLEManager.isOffloadFrame(frame) {
                        armBackfillTimeout()
                        routeBackfillFrame(frame)
                    }
                } else {
                    // Live path (unchanged): synchronous ingest preserves delegate arrival order.
                    collector?.ingest(frame)
                }
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(describe(error))")
            if isAuthError(error) { scheduleWhoop5Retry() }
        } else {
            if characteristic.uuid == BLEManager.heartRateChar { state.hrSubscribed = characteristic.isNotifying }
            log("Notify \(characteristic.isNotifying ? "ON" : "OFF") for \(characteristic.uuid)")
        }
    }
}

// MARK: - Device Information (180A)
extension BLEManager {
    func handleDeviceInfo(_ uuid: String, _ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        var info = state.deviceInfo ?? DeviceInfo()
        switch uuid {
        case "2A29": info.manufacturer = text
        case "2A24": info.model = text
        case "2A26": info.firmware = text
        case "2A27": info.hardware = text
        case "2A25": Redactor.register(secret: text); return   // serial: only registered for redaction, never stored or logged
        default: return
        }
        info.readAt = Date()
        if info != state.deviceInfo {
            state.deviceInfo = info
            info.save()
            if uuid == "2A26" { log("Device: firmware \(text)") }
        }
    }
}
