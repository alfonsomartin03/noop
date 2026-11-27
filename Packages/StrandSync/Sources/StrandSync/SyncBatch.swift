import Foundation
import CryptoKit
import WhoopProtocol

/// One phone → Mac transfer unit (#77): decoded strap rows plus the mandatory undecoded-history lines collected in
/// one stretch, identified by the phone (`sourceId`), a monotonic `sequence` and a random `batchId`.
public struct SyncBatch: Equatable, Codable {
    public let formatVersion: Int
    public let batchId: String
    public let sourceId: String
    public let sequence: Int64
    /// Strap identity the rows belong to on the Mac (today always `my-whoop`).
    public let deviceId: String
    public let createdAt: Int
    public let streams: Streams
    /// Position of each `streams.rr` beat within its second (same order); empty = let the Mac align by value.
    public let rrSeq: [Int]
    /// `RawHistoryArchive` JSONL lines for history NOOP could not decode; never dropped.
    public let undecoded: [String]

    public init(formatVersion: Int = SyncFormat.current, batchId: String = UUID().uuidString, sourceId: String,
                sequence: Int64, deviceId: String, createdAt: Int, streams: Streams, rrSeq: [Int] = [],
                undecoded: [String] = []) {
        self.formatVersion = formatVersion; self.batchId = batchId; self.sourceId = sourceId; self.sequence = sequence
        self.deviceId = deviceId; self.createdAt = createdAt; self.streams = streams; self.rrSeq = rrSeq
        self.undecoded = undecoded
    }

    /// Records carried (rows + undecoded lines), for status and logs.
    public var recordCount: Int {
        streams.hr.count + streams.rr.count + streams.spo2.count + streams.skinTemp.count + streams.resp.count
            + streams.gravity.count + streams.events.count + streams.battery.count + streams.steps.count + undecoded.count
    }
}

public enum SyncFormat {
    /// Bump when the envelope or batch layout changes incompatibly.
    public static let current = 1
    public static func accepts(_ version: Int) -> Bool { version == current }
}

/// A batch with its SHA-256 digest, as sent over the wire. The digest covers the batch's canonical JSON encoding, so the
/// Mac can tell a replay (same id, same digest) from a corrupted or different batch (same id, other digest).
public struct SyncEnvelope: Equatable, Codable {
    public let batch: SyncBatch
    public let digest: String

    public static func seal(_ batch: SyncBatch) throws -> SyncEnvelope {
        SyncEnvelope(batch: batch, digest: try digest(of: batch))
    }

    public static func digest(of batch: SyncBatch) throws -> String {
        let data = try canonicalEncoder.encode(batch)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func encoded() throws -> Data { try Self.canonicalEncoder.encode(self) }

    static var canonicalEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

public enum SyncError: Error, Equatable {
    case unreadable
    case unsupportedVersion(Int)
    case digestMismatch
}

extension SyncEnvelope {
    /// Decodes and checks an envelope before anything is written: format version first, then the digest.
    public static func open(_ data: Data) throws -> SyncEnvelope {
        struct Probe: Decodable { struct B: Decodable { let formatVersion: Int }; let batch: B }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { throw SyncError.unreadable }
        guard SyncFormat.accepts(probe.batch.formatVersion) else {
            throw SyncError.unsupportedVersion(probe.batch.formatVersion)
        }
        guard let env = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else { throw SyncError.unreadable }
        guard try digest(of: env.batch) == env.digest else { throw SyncError.digestMismatch }
        return env
    }
}
