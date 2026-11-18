import Foundation

/// Decides which WHOOP 5.0 HISTORY_END frames may be acknowledged within one pull (#38).
///
/// The strap only sends the next chunk after an ack, so an END that arrives while an earlier END of the same pull is
/// still being saved is a REPEAT of that chunk's END, carrying the same end_data. Saving is asynchronous, so without
/// this gate a repeat could be acked before the first END's save failed — acknowledging (and letting the strap trim)
/// a chunk NOOP refused. Rules, per pull session:
/// 1. Only one END at a time holds the ack slot; ENDs arriving meanwhile are saved but never acked.
/// 2. Once any chunk of the pull is refused (unstorable frame, archive failure, failed save), no later END is acked.
/// A new session id (each pull start/end bumps it) clears both.
struct HistoryAckGate: Equatable {
    private var session = Int.min
    private var refused = false
    private var holder = false

    /// Called when a HISTORY_END arrives. True = this END holds the ack slot and may be acked once saved
    /// (call `finish` when its handling ends, acked or not). False = save only, never ack.
    mutating func begin(session s: Int) -> Bool {
        if s != session { session = s; refused = false; holder = false }
        guard !refused, !holder else { return false }
        holder = true
        return true
    }

    /// A chunk of this pull was refused: nothing later in the pull may be acked.
    mutating func refuse(session s: Int) {
        if s != session { session = s; holder = false }
        refused = true
    }

    /// The slot holder's handling ended (acked, refused, or abandoned).
    mutating func finish(session s: Int) {
        if s == session { holder = false }
    }

    /// Final check right before the ack write.
    func mayAck(session s: Int) -> Bool { s == session && !refused }
}
