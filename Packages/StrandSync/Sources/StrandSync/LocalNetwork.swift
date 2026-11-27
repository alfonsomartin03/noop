import Foundation
import Network

// LocalNetwork.swift — TCP plumbing for the sync session (#79). Encryption and authentication are the session's job
// (`SecureChannel.swift`); this file only moves bytes. The Mac listens only while the user has started the receiver;
// the phone connects to an address the user entered. No discovery is advertised.

/// A `ByteStream` over an `NWConnection`.
public final class NWByteStream: ByteStream {
    let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) { self.connection = connection }

    /// Opens a TCP connection to `host:port` (the Mac's address on the local network).
    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> NWByteStream {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await ready(c, timeout: timeout)
        return NWByteStream(connection: c)
    }

    static func ready(_ c: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { k.resume() }
                case .failed(let e): once.run { k.resume(throwing: e) }
                case .waiting(let e): once.run { c.cancel(); k.resume(throwing: e) }
                case .cancelled: once.run { k.resume(throwing: ChannelError.closed) }
                default: break
                }
            }
            c.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { c.cancel(); k.resume(throwing: ChannelError.closed) }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { e in
                if let e { k.resume(throwing: e) } else { k.resume() }
            })
        }
    }

    public func read(_ count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { k in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(count - buffer.count, 65_536)) {
                    data, _, done, error in
                    if let error { k.resume(throwing: error) }
                    else if let data, !data.isEmpty { k.resume(returning: data) }
                    else if done { k.resume(throwing: ChannelError.closed) }
                    else { k.resume(returning: Data()) }
                }
            }
            buffer += chunk
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    public func close() { connection.cancel() }
}

/// The Mac's receiver: listens on a TCP port and hands each connection to the endpoint.
public final class MacSyncListener {
    let endpoint: MacSyncEndpoint
    let requestedPort: UInt16
    private var listener: NWListener?

    /// `port` 0 picks a free port (tests); the app uses a fixed one so the phone can remember it.
    public init(endpoint: MacSyncEndpoint, port: UInt16 = MacSyncListener.defaultPort) {
        self.endpoint = endpoint; requestedPort = port
    }

    public static let defaultPort: UInt16 = 47_800

    /// Starts listening; returns the bound port.
    public func start() async throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: requestedPort)!)
        listener = l
        l.newConnectionHandler = { [endpoint] c in
            c.start(queue: .global(qos: .utility))
            Task { await endpoint.serve(NWByteStream(connection: c)) }
        }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { k.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): once.run { k.resume(throwing: e) }
                case .cancelled: once.run { k.resume(throwing: ChannelError.closed) }
                default: break
                }
            }
            l.start(queue: .global(qos: .utility))
        }
    }

    public func stop() { listener?.cancel(); listener = nil }
}

/// Runs a block at most once (continuations must be resumed exactly once).
final class Once {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}
