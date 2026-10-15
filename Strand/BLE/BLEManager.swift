import Foundation
import CoreBluetooth
import os
import WhoopProtocol
import WhoopStore

/// CoreBluetooth engine for WHOOP 4.0 (full path) and WHOOP 5.0 (connect + hello + frame
/// validation only; 5.0 command encoding / biometric decode are not implemented):  scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
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
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    // WHOOP 5.0 ("puffin") service; source: b-nnett/goose via DeviceFamily. UNVERIFIED on hardware here.
    static let whoop5Service = CBUUID(string: DeviceFamily.whoop5.serviceUUIDString)
    static let whoop5CmdWriteChar = CBUUID(string: DeviceFamily.whoop5.commandCharacteristicUUIDString)

    /// UserDefaults key: when true (the default) NOOP stores strap history but never acknowledges it,
    /// so the strap does not delete anything. The strap discards a chunk only once an app acks it.
    static let keepDataOnStrapKey = "noop.keepDataOnStrap"
    static var keepDataOnStrap: Bool {
        UserDefaults.standard.object(forKey: keepDataOnStrapKey) as? Bool ?? true
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
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// True while the Live screen wants the (heavy) realtime stream; keep-alive re-arms it.
    private var wantsRealtime = false
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
    private var central: CBCentralManager!
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
    private var historyIdleWork: DispatchWorkItem?
    private var historyMetaSeen: [String] = []
    private var historyDecoded: [Whoop5HistoricalRecord] = []
    static let historyMaxCapturedFrames = 600
    static let historyIdleSeconds = 20
    private var realtimeDecodeLogged = 0
    private var lastRealtimeTs: UInt32?
    private var heartRateCharacteristic: CBCharacteristic?
    private var whoop5SetupAttempts = 0
    private var whoop5RetryPending = false
    private var whoop5ExhaustedLogged = false
    static let whoop5MaxSetupAttempts = 6
    static let whoop5RetryDelaySeconds = 5

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
        central = CBCentralManager(delegate: self, queue: .main)
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
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
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture)
        backfiller?.acknowledgesChunks = { !BLEManager.keepDataOnStrap }
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
        central = CBCentralManager(delegate: self, queue: .main)
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    // MARK: Public API
    public func connect() {
        intentionalDisconnect = false
        guard central.state == .poweredOn else {
            log("Bluetooth not ready: \(BLEManager.stateName(central.state)); authorization=\(BLEManager.authName(CBCentralManager.authorization))")
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
        guard central.state == .poweredOn, !intentionalDisconnect, peripheral == nil else { return }
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
        central.stopScan()
        peripheral = p
        p.delegate = self
        log("Connecting (peripheral state=\(p.state.rawValue))…")
        central.connect(p, options: nil)
    }

    /// Start pairing over after a stale-bond failure. CoreBluetooth cannot unpair a device, so the user
    /// resets Bluetooth first; this clears the app-side state and rescans.
    public func restartPairing() {
        stalePairingFailures = 0
        state.pairingStale = false
        restoredPeripheral = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        central.stopScan()
        log("Restarting pairing from scratch")
        connect()
    }

    public func disconnect() {
        intentionalDisconnect = true
        scanFallbackWork?.cancel()
        helloWatchdog?.cancel()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
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
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        guard let p = peripheral, let ch = cmdCharacteristic else {
            log("send(\(command.label)) ignored — not connected")
            return
        }
        if family == .whoop5 {
            sendWhoop5(command, payload: payload, peripheral: p, characteristic: ch, writeType: writeType)
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Commands verified (from the Goose reverse-engineering) to share their command NUMBER with the 4.0
    /// and to be read-only or trivially reversible. 5.0 payloads: Goose sends these with the payloads below.
    /// Everything else (alarm, haptics, historical, raw streams) stays blocked: payloads differ or are unverified.
    private static let whoop5Allowed: [WhoopCommand: (_ payload: [UInt8]) -> [UInt8]] = [
        .toggleRealtimeHR:   { $0.isEmpty ? [0] : [$0[0]] },   // [1] on / [0] off
        .reportVersionInfo:  { _ in [] },
        .getClock:           { _ in [] },
        .getDataRange:       { _ in [] },
        .sendHistoricalData: { _ in [] },   // history pull (safe mode only — see pullWhoop5History)
    ]
    private var whoop5SkippedLogged = Set<UInt8>()

    private func sendWhoop5(_ command: WhoopCommand, payload: [UInt8], peripheral p: CBPeripheral,
                            characteristic ch: CBCharacteristic, writeType: CBCharacteristicWriteType) {
        guard let map = BLEManager.whoop5Allowed[command] else {
            if whoop5SkippedLogged.insert(command.rawValue).inserted {
                log("send(\(command.label)) not sent on WHOOP 5.0 — its 5.0 payload/encoding is unverified (logged once)")
            }
            return
        }
        guard didBond else {
            log("send(\(command.label)) deferred — WHOOP 5.0 link not bonded yet")
            return
        }
        seq = seq &+ 1
        let data = map(payload)
        let frame = buildWhoop5CommandFrame(seq: seq, command: command.rawValue, data: data)
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? writeType : .withResponse
        p.writeValue(Data(frame), for: ch, type: type)
        log("→ 5.0 \(command.label) seq=\(seq) payload=\(hex(data))")
    }

    /// One-shot, read-only probe once the 5.0 link is bonded + subscribed: proves the command channel works
    /// (responses show up as "RX 5.0 … cmd-response" lines). GET_CLOCK and REPORT_VERSION_INFO only read.
    private func whoop5Probe() {
        guard family == .whoop5, !whoop5ProbeSent else { return }
        whoop5ProbeSent = true
        log("WHOOP 5.0: sending read-only probe (GET_CLOCK, REPORT_VERSION_INFO)")
        send(.getClock, payload: [])
        send(.reportVersionInfo, payload: [])
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
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
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
    public func startRealtime() { wantsRealtime = true; send(.toggleRealtimeHR, payload: [0x01]) }
    /// Stop the realtime stream. The lightweight 0x2A37 HR keeps recording continuously regardless.
    public func stopRealtime() { wantsRealtime = false; send(.toggleRealtimeHR, payload: [0x00]) }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        if Date().timeIntervalSince(lastDataAt) > 120 {
            log("No data for >120s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        if wantsRealtime { send(.toggleRealtimeHR, payload: [0x01]) }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
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
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
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
        BLEManager.osLog.notice("\(s, privacy: .public)")
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

    // MARK: WHOOP 5.0 stored data (history) — SAFE MODE
    //
    // Reads the strap's stored records WITHOUT acknowledging them. The ack (HISTORICAL_DATA_RESULT) is the step
    // after which a strap discards a chunk, so we never send it here: nothing is deleted. Raw frames are saved to
    // a local file so the record layout can be worked out before any data is stored or trimmed.
    // ASSUMPTION: the 5.0 trims only on ack, as documented for the 4.0 in this repo.

    /// Ask the strap what time span it holds (read-only).
    public func queryWhoop5DataRange() {
        guard family == .whoop5, didBond else { log("Data range: needs a bonded WHOOP 5.0"); return }
        log("History: requesting data range (read-only)")
        send(.getDataRange, payload: [])
    }

    /// Start a safe-mode pull: request history, capture raw frames to a local file, never acknowledge.
    public func pullWhoop5History() {
        guard family == .whoop5, didBond, !whoop5HistoryActive else {
            log("History pull: needs a bonded WHOOP 5.0 and no pull already running"); return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("whoop5-history-\(stamp).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            historyCapture = try? FileHandle(forWritingTo: url)
            state.historyCaptureFile = url.lastPathComponent
        }
        whoop5HistoryActive = true
        historyMetaSeen = []
        historyDecoded = []
        state.historySummary = nil
        state.historyFrames = 0
        state.historyBusy = true
        state.historyStatus = "Requesting stored data…"
        log("History: SAFE-MODE pull started (no acknowledgement will be sent; the strap keeps its data)")
        guard let p = peripheral, let ch = cmdCharacteristic else { endWhoop5History("not connected"); return }
        sendWhoop5(.sendHistoricalData, payload: [], peripheral: p, characteristic: ch, writeType: .withResponse)
        armHistoryIdle()
    }

    public func cancelWhoop5History() { endWhoop5History("cancelled") }

    private func armHistoryIdle() {
        historyIdleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.endWhoop5History("no more data for \(BLEManager.historyIdleSeconds)s") }
        historyIdleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.historyIdleSeconds), execute: w)
    }

    private func endWhoop5History(_ reason: String) {
        guard whoop5HistoryActive else { return }
        whoop5HistoryActive = false
        historyIdleWork?.cancel()
        try? historyCapture?.close(); historyCapture = nil
        state.historyBusy = false
        state.historyStatus = "Captured \(state.historyFrames) frames (\(reason)). Nothing was cleared from the strap."
        saveDecodedHistory()
        log("History: pull ended — \(reason); frames=\(state.historyFrames); kinds=\(historyMetaSeen.joined(separator: ","))")
    }

    /// Decode + persist the stored records captured in this pull (heart rate, R-R, gravity). Safe to repeat.
    private func saveDecodedHistory() {
        let recs = historyDecoded
        historyDecoded = []
        guard !recs.isEmpty else { return }
        let hr = recs.filter { (30...220).contains($0.heartRate) }.map { HRSample(ts: $0.timestamp, bpm: $0.heartRate) }
        let rr = recs.flatMap { r in r.rr.map { RRInterval(ts: r.timestamp, rrMs: $0) } }
        let grav = recs.compactMap { r in r.gravity.map { GravitySample(ts: r.timestamp, x: $0.x, y: $0.y, z: $0.z) } }
        let lo = recs.map(\.timestamp).min()!, hi = recs.map(\.timestamp).max()!
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm:ss"
        let avg = hr.isEmpty ? nil : hr.map(\.bpm).reduce(0, +) / hr.count
        let base = "\(recs.count) records · \(f.string(from: Date(timeIntervalSince1970: TimeInterval(lo)))) → \(f.string(from: Date(timeIntervalSince1970: TimeInterval(hi))))"
            + (avg.map { " · avg \($0) bpm" } ?? "") + " · \(rr.count) R-R"
        state.historySummary = base
        log("History: decoded \(base)")
        Task { @MainActor in
            if let n = await collector?.persistDecodedHistory(Streams(hr: hr, rr: rr, gravity: grav)) {
                state.historySummary = base + " · saved (\(n) new heart-rate rows)"
                log("History: saved decoded records (\(n) new heart-rate rows)")
            } else {
                state.historySummary = base + " · NOT saved (database unavailable)"
                log("History: could not save decoded records (store unavailable)")
            }
        }
    }

    /// Called for every complete 5.0 frame while a pull is active.
    private func captureWhoop5HistoryFrame(_ frame: [UInt8], on characteristic: CBCharacteristic) {
        guard whoop5HistoryActive, frame.count > 12 else { return }
        let type = frame[8]
        // 47 historical data, 52 historical IMU, 49/56 metadata, 48/53/54 events, 50 console — everything except the live flood.
        guard [47, 52, 49, 56, 48, 53, 54, 50, 55].contains(type) else { return }
        armHistoryIdle()
        state.historyFrames += 1
        if type == 47, let rec = decodeWhoop5Historical(frame) { historyDecoded.append(rec) }
        if type == 49 || type == 56 {
            let kind = type == 49 ? Int(frame[10]) : (Int(frame[10]) | Int(frame[11]) << 8)
            let name = kind == 1 ? "START" : kind == 2 ? "END" : kind == 3 ? "COMPLETE" : "kind\(kind)"
            historyMetaSeen.append(name)
            log("History: metadata \(name) (frame \(state.historyFrames))")
            if name == "COMPLETE" { endWhoop5History("strap reported HISTORY_COMPLETE") }
        } else if state.historyFrames <= 3 || state.historyFrames % 50 == 0 {
            log("History: frame \(state.historyFrames) type=\(type) len=\(frame.count) on \(characteristic.uuid.uuidString.prefix(8))")
        }
        if state.historyFrames <= BLEManager.historyMaxCapturedFrames {
            let line = "{\"t\":\(Date().timeIntervalSince1970),\"ch\":\"\(characteristic.uuid.uuidString.prefix(8))\",\"type\":\(type),\"len\":\(frame.count),\"hex\":\"\(hex(frame))\"}\n"
            historyCapture?.write(Data(line.utf8))
        } else if state.historyFrames == BLEManager.historyMaxCapturedFrames + 1 {
            endWhoop5History("capture limit reached (\(BLEManager.historyMaxCapturedFrames) frames)")
        }
    }

    /// Decode the data-range response: list plausible unix timestamps found in the body (layout not published).
    private func logWhoop5DataRange(_ frame: [UInt8]) {
        let end = min((Int(frame[2]) | Int(frame[3]) << 8) + 8 - 4, frame.count)
        guard end > 13 else { return }
        var found: [(Int, Int)] = []
        var o = 13
        while o + 4 <= end {
            let w = Int(frame[o]) | Int(frame[o+1]) << 8 | Int(frame[o+2]) << 16 | Int(frame[o+3]) << 24
            if w >= 1_600_000_000 && w <= 2_100_000_000 { found.append((o - 13, w)) }
            o += 1
        }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let desc = found.map { "body+\($0.0)=\(f.string(from: Date(timeIntervalSince1970: TimeInterval($0.1))))" }
        log("History: data range response body=\(end - 13) bytes; timestamps: \(desc.isEmpty ? "none recognised" : desc.joined(separator: " | "))")
        if let lo = found.map({ $0.1 }).min(), let hi = found.map({ $0.1 }).max() {
            state.historyRange = lo == hi ? f.string(from: Date(timeIntervalSince1970: TimeInterval(lo)))
                : "\(f.string(from: Date(timeIntervalSince1970: TimeInterval(lo)))) → \(f.string(from: Date(timeIntervalSince1970: TimeInterval(hi))))"
        }
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
    func armStrapAlarm(at date: Date) {
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        send(.setClock, payload: BLEManager.setClockPayload())
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        log("Alarm: armed for \(date) (epoch \(epochSec))")
    }

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
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(BLEManager.stateName(central.state)); authorization=\(BLEManager.authName(CBCentralManager.authorization))")
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
        realtimeDecodeLogged = 0
        lastRealtimeTs = nil
        heartRateCharacteristic = nil
        helloWatchdog?.cancel()
        reassembler.reset()
        whoop5Chars = []
        whoop5SetupAttempts = 0
        whoop5RetryPending = false
        whoop5ExhaustedLogged = false
        whoop5ProbeSent = false
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
            log("Disconnected: \(describe(error)); rescanning in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
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
                if c.uuid == BLEManager.heartRateChar { heartRateCharacteristic = c }
                peripheral.setNotifyValue(true, for: c)
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
            if let pct = bytes.first { state.setBattery(Double(pct)) } // 0x2A19 = percent
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
                    // 5.0: validate + route to UI state only. Biometric offsets / historical offload / clock
                    // correlation are 4.0-only. Log metadata (never payload bytes).
                    rxFrameCount += 1
                    let chk = verifyFrame(frame, family: .whoop5)
                    let parsed = parseFrame(frame, family: .whoop5)
                    if frame.count > 12, parsed.typeName == "COMMAND_RESPONSE" {
                        // metadata only: [8]=type [9]=seq [10]=responded-to cmd [11]=origin seq [12]=result code
                        log("RX 5.0 cmd-response to=\(frame[10]) originSeq=\(frame[11]) result=\(frame[12]) len=\(frame.count) crc=\(chk.ok)")
                    } else if rxFrameCount <= 20 {
                        log("RX 5.0 on \(characteristic.uuid.uuidString.prefix(8)): type=\(parsed.typeName) len=\(frame.count) hdrCRC=\(chk.crc8OK.map(String.init) ?? "?") crc32=\(chk.crc32OK.map(String.init) ?? "?")")
                    }
                    router.handle(frame: frame, family: .whoop5)
                    if chk.ok, frame.count > 12, parsed.typeName == "COMMAND_RESPONSE", frame[10] == WhoopCommand.getDataRange.rawValue, frame[12] == 1 {
                        logWhoop5DataRange(frame)
                    }
                    if chk.ok { captureWhoop5HistoryFrame(frame, on: characteristic) }
                    if let rt = decodeWhoop5Realtime(frame), realtimeDecodeLogged < 10 {
                        // Layout validation (first 10 only): timestamps should step ~1 s, HR should be steady.
                        let dt = lastRealtimeTs.map { Int(rt.timestamp) - Int($0) }
                        lastRealtimeTs = rt.timestamp
                        realtimeDecodeLogged += 1
                        log("5.0 realtime decode check: hr=\(rt.heartRate) rrCount=\(rt.rr.count) tsStep=\(dt.map(String.init) ?? "-")")
                    }
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
