import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandSync

/// In-memory duplex pipe; `tamper` alters bytes written in one direction (to test record authentication).
final class MemoryPipe: ByteStream {
    private var buffer = Data()
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    weak var peer: MemoryPipe?
    var tamper: ((Data) -> Data)?

    static func pair() -> (MemoryPipe, MemoryPipe) {
        let a = MemoryPipe(), b = MemoryPipe(); a.peer = b; b.peer = a; return (a, b)
    }

    fileprivate func deliver(_ d: Data) {
        lock.lock(); buffer += d; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }

    fileprivate func shut() {
        lock.lock(); closed = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }

    func write(_ data: Data) async throws {
        guard let peer, !closed else { throw ChannelError.closed }
        peer.deliver(tamper?(data) ?? data)
    }

    func read(_ count: Int) async throws -> Data {
        while true {
            lock.lock()
            if buffer.count >= count {
                let out = buffer.prefix(count); buffer.removeFirst(count); lock.unlock(); return Data(out)
            }
            if closed { lock.unlock(); throw ChannelError.closed }
            lock.unlock()
            await withCheckedContinuation { k in
                lock.lock()
                if buffer.count >= count || closed { lock.unlock(); k.resume() } else { waiters.append(k); lock.unlock() }
            }
        }
    }

    func close() { shut(); peer?.shut() }
}

final class TransportTests: XCTestCase {
    var macStore: WhoopStore!
    var phoneStore: WhoopStore!
    let macID = DeviceIdentity(), phoneID = DeviceIdentity()
    var macTrust: InMemoryTrustStore!, phoneTrust: InMemoryTrustStore!
    var macConfirms = true, phoneConfirms = true
    var shownOnMac: String?, shownOnPhone: String?

    override func setUp() async throws {
        macStore = try await WhoopStore.inMemory(); phoneStore = try await WhoopStore.inMemory()
        macTrust = InMemoryTrustStore(); phoneTrust = InMemoryTrustStore()
        macConfirms = true; phoneConfirms = true; shownOnMac = nil; shownOnPhone = nil
    }

    func makeMac() -> MacSyncEndpoint {
        MacSyncEndpoint(identity: macID, trust: macTrust, ingestor: MacArchiveIngestor(store: macStore) { _, _ in },
                        macName: "Test Mac") { [unowned self] code in shownOnMac = code; return macConfirms }
    }

    /// A phone client whose every connection is served by `mac` over a fresh in-memory pipe.
    func makePhone(_ mac: MacSyncEndpoint, tamper: ((Data) -> Data)? = nil) -> PhoneSyncClient {
        PhoneSyncClient(identity: phoneID, trust: phoneTrust) {
            let (p, m) = MemoryPipe.pair()
            p.tamper = tamper
            Task { await mac.serve(m) }
            return p
        }
    }

    func pairBoth(_ mac: MacSyncEndpoint, _ phone: PhoneSyncClient) async throws {
        mac.openPairingWindow()
        _ = try await phone.pair(phoneName: "Test iPhone") { [unowned self] code in shownOnPhone = code; return phoneConfirms }
    }

    func collect(_ n: Int) async throws {
        try await phoneStore.insert(Streams(hr: (1...n).map { HRSample(ts: $0, bpm: 60) }), deviceId: "my-whoop")
    }

    // MARK: pairing

    func testPairingShowsTheSameCodeAndPinsBothSides() async throws {
        let mac = makeMac(), phone = makePhone(mac)
        try await pairBoth(mac, phone)
        XCTAssertNotNil(shownOnMac)
        XCTAssertEqual(shownOnMac, shownOnPhone)
        XCTAssertEqual(shownOnMac?.count, 6)
        XCTAssertTrue(macTrust.isTrusted(phoneID.publicKey))
        XCTAssertTrue(phoneTrust.isTrusted(macID.publicKey))
        XCTAssertEqual(try macTrust.peers().first?.name, "Test iPhone")
        XCTAssertEqual(try phoneTrust.peers().first?.name, "Test Mac")
    }

    func testUnknownPhoneIsRefusedWithoutAPairingWindow() async throws {
        let mac = makeMac()
        try phoneTrust.pin(TrustedPeer(publicKey: macID.publicKey, name: "Mac", pairedAt: 0))   // phone trusts the Mac
        try await collect(3)
        let r = try await PhoneOutbox(store: phoneStore).sync(over: makePhone(mac))
        XCTAssertEqual(r.stoppedAt, 1)
        let counts = try await macStore.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 0)
    }

    func testPhoneRefusesAMacItHasNotPaired() async throws {
        let mac = makeMac()
        try macTrust.pin(TrustedPeer(publicKey: phoneID.publicKey, name: "iPhone", pairedAt: 0))   // only the Mac trusts
        try await collect(3)
        let r = try await PhoneOutbox(store: phoneStore).sync(over: makePhone(mac))
        XCTAssertEqual(r.stoppedAt, 1)
        let counts = try await macStore.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 0)
    }

    func testDecliningOnEitherDevicePinsNothing() async throws {
        for (macSays, phoneSays) in [(false, true), (true, false)] {
            try await setUp()
            macConfirms = macSays; phoneConfirms = phoneSays
            let mac = makeMac(), phone = makePhone(mac)
            do { try await pairBoth(mac, phone); XCTFail("pairing should fail") } catch {}
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(macTrust.isTrusted(phoneID.publicKey), "mac \(macSays) phone \(phoneSays)")
            XCTAssertFalse(phoneTrust.isTrusted(macID.publicKey), "mac \(macSays) phone \(phoneSays)")
        }
    }

    func testPairingWindowAllowsOneAttemptOnly() async throws {
        let mac = makeMac()
        let window = mac.openPairingWindow()
        macConfirms = false
        do { _ = try await makePhone(mac).pair(phoneName: "x") { _ in true }; XCTFail() } catch {}
        XCTAssertFalse(window.isOpen())
        macConfirms = true
        do { _ = try await makePhone(mac).pair(phoneName: "x") { _ in true }; XCTFail("window is used up") } catch {
            XCTAssertEqual(error as? ChannelError, .unknownPeer)
        }
    }

    func testExpiredPairingWindowRefuses() async throws {
        let mac = makeMac()
        mac.openPairingWindow(lifetime: -1)
        do { _ = try await makePhone(mac).pair(phoneName: "x") { _ in true }; XCTFail() } catch {
            XCTAssertEqual(error as? ChannelError, .unknownPeer)
        }
    }

    func testDifferentSessionsShowDifferentCodes() async throws {
        var codes: Set<String> = []
        for _ in 0..<5 {
            try await setUp()
            let mac = makeMac(); try await pairBoth(mac, makePhone(mac))
            codes.insert(shownOnMac!)
        }
        XCTAssertGreaterThan(codes.count, 1)
    }

    // MARK: uploads

    func testPairedPhoneUploadsEverythingOnce() async throws {
        let mac = makeMac(), phone = makePhone(mac)
        try await pairBoth(mac, phone)
        try await collect(10)
        let r = try await PhoneOutbox(store: phoneStore, maxRowsPerTable: 4).sync(over: phone)
        XCTAssertEqual(r.confirmed, [1, 2, 3])
        let counts = try await macStore.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 10)
    }

    func testRevokedPhoneIsRefused() async throws {
        let mac = makeMac(), phone = makePhone(mac)
        try await pairBoth(mac, phone)
        try macTrust.revoke(publicKey: phoneID.publicKey)
        try await collect(2)
        let r = try await PhoneOutbox(store: phoneStore).sync(over: phone)
        XCTAssertEqual(r.stoppedAt, 1)
        let counts = try await macStore.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 0)
    }

    func testAlteredBytesEndTheSessionAndNothingIsStored() async throws {
        let mac = makeMac()
        try await pairBoth(mac, makePhone(mac))
        // Flip one byte in every large frame the phone sends (the encrypted upload).
        let phone = makePhone(mac, tamper: { d in
            guard d.count > 200 else { return d }
            var m = d; m[m.startIndex + 100] ^= 0x01; return m
        })
        try await collect(3)
        let r = try await PhoneOutbox(store: phoneStore).sync(over: phone)
        XCTAssertEqual(r.stoppedAt, 1)
        let counts = try await macStore.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 0)
    }

    func testRecordsCannotBeReadWithoutTheKeys() async throws {
        let mac = makeMac()
        try await pairBoth(mac, makePhone(mac))
        var wire = Data()
        let phone = makePhone(mac, tamper: { d in wire += d; return d })
        try await phoneStore.insert(Streams(hr: [HRSample(ts: 1, bpm: 173)]), deviceId: "my-whoop")
        _ = try await PhoneOutbox(store: phoneStore).sync(over: phone)
        XCTAssertNil(wire.range(of: Data("\"bpm\"".utf8)), "row content never appears in clear on the wire")
        XCTAssertNil(wire.range(of: Data("my-whoop".utf8)))
    }

    // MARK: real TCP on loopback

    func testPairAndUploadOverLoopbackTCP() async throws {
        let mac = makeMac()
        let listener = MacSyncListener(endpoint: mac, port: 0)
        let port = try await listener.start()
        defer { listener.stop() }
        let phone = PhoneSyncClient(identity: phoneID, trust: phoneTrust) {
            try await NWByteStream.connect(host: "127.0.0.1", port: port)
        }
        try await pairBoth(mac, phone)
        try await collect(5)
        let r = try await PhoneOutbox(store: phoneStore).sync(over: phone)
        XCTAssertEqual(r.confirmed, [1])
        let counts = try await macStore.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 5)
        phone.disconnect()
    }

    // MARK: Keychain

    func testKeychainKeepsIdentityAndPeers() throws {
        let store = KeychainTrustStore(service: "com.noopapp.noop.sync.test.\(UUID().uuidString)")
        defer { store.deleteAllForTests() }
        let id: DeviceIdentity
        do { id = try store.identity() } catch let e as KeychainTrustStore.KeychainError {
            throw XCTSkip("no Keychain access in this test runner (status \(e.status))")
        }
        XCTAssertEqual(try store.identity().publicKey, id.publicKey, "the same identity comes back")
        let peer = TrustedPeer(publicKey: Data(repeating: 7, count: 32), name: "Mac", pairedAt: 1)
        try store.pin(peer)
        XCTAssertTrue(store.isTrusted(peer.publicKey))
        try store.revoke(publicKey: peer.publicKey)
        XCTAssertFalse(store.isTrusted(peer.publicKey))
    }

    // MARK: scores sent back (#79)

    private func score(_ days: [String], recovery: Double) async throws {
        _ = try await macStore.upsertDailyMetrics(days.map {
            DailyMetric(day: $0, totalSleepMin: 430, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: 54, avgHrv: nil, recovery: recovery, strain: 11.2, exerciseCount: nil)
        }, deviceId: "my-whoop-noop")
    }

    func testPhoneGetsTheMacsScoresAndThenOnlyChanges() async throws {
        let mac = makeMac(), phone = makePhone(mac)
        try await pairBoth(mac, phone)
        try await collect(5)
        _ = try await PhoneOutbox(store: phoneStore).sync(over: phone)
        var changed = try await phone.refreshScores(into: phoneStore)
        XCTAssertEqual(changed, 0, "nothing scored yet: the phone shows no score, not zero")
        try await score(["2026-11-25", "2026-11-26"], recovery: 66)          // the Mac's scheduled scoring ran
        changed = try await phone.refreshScores(into: phoneStore)
        XCTAssertEqual(changed, 2)
        changed = try await phone.refreshScores(into: phoneStore)
        XCTAssertEqual(changed, 0)
        try await score(["2026-11-26"], recovery: 71)                         // a late batch re-scored one day
        changed = try await phone.refreshScores(into: phoneStore)
        XCTAssertEqual(changed, 1)
        let shown = try await phoneStore.cachedSummaries()
        XCTAssertEqual(shown.map(\.day), ["2026-11-25", "2026-11-26"])
        XCTAssertEqual(shown.last?.values["recovery"], 71)
        XCTAssertEqual(shown.last?.values["strain"], 11.2)
    }

    func testScoresStayOnThePhoneWhenTheMacIsGone() async throws {
        let mac = makeMac(), phone = makePhone(mac)
        try await pairBoth(mac, phone)
        try await score(["2026-11-25"], recovery: 66)
        try await phone.refreshScores(into: phoneStore)
        try macTrust.revoke(publicKey: phoneID.publicKey)      // the Mac is unreachable / no longer answers
        phone.disconnect()
        do { try await phone.refreshScores(into: phoneStore); XCTFail("expected failure") } catch {}
        let shown = try await phoneStore.cachedSummaries()
        XCTAssertEqual(shown.first?.values["recovery"], 66, "the cached score is still shown")
    }

    func testUnpairedPhoneGetsNoScores() async throws {
        let mac = makeMac()
        try phoneTrust.pin(TrustedPeer(publicKey: macID.publicKey, name: "Mac", pairedAt: 0))
        try await score(["2026-11-25"], recovery: 66)
        do { try await makePhone(mac).refreshScores(into: phoneStore); XCTFail("expected refusal") } catch {}
        let shown = try await phoneStore.cachedSummaries()
        XCTAssertTrue(shown.isEmpty)
    }

    func testManyDaysArriveAcrossPages() async throws {
        let mac = makeMac(), phone = makePhone(mac)
        try await pairBoth(mac, phone)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let days = (0..<450).map { f.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 86_400)) }
        try await score(days, recovery: 50)
        let changed = try await phone.refreshScores(into: phoneStore)
        XCTAssertEqual(changed, 450)
    }
}
