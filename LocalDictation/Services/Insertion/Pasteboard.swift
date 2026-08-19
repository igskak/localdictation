import AppKit

/// What the app took off the pasteboard before it wrote to it.
///
/// Only the string is captured. `docs/PHASE_4.md` promises best-effort
/// restoration of the standard text types and says plainly that exotic types
/// may not survive — promising to restore an arbitrary multi-representation
/// item faithfully would be a promise this cannot keep.
struct PasteboardSnapshot: Sendable, Equatable {
    let string: String?
    let changeCount: Int
}

/// The pasteboard, behind a protocol so the insertion service can be built
/// without touching the user's real clipboard in a test.
@MainActor
protocol Pasteboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    /// Replaces the contents and returns the new change count.
    @discardableResult func write(_ string: String) -> Int
    /// Puts a snapshot back, and only if nothing else has written since.
    ///
    /// Guarded by the change count rather than by a timer: if another
    /// application wrote to the pasteboard while the paste was in flight, its
    /// content is newer than ours and overwriting it would be the app
    /// destroying something the user did.
    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int)
}

@MainActor
final class SystemPasteboard: Pasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(string: pasteboard.string(forType: .string), changeCount: pasteboard.changeCount)
    }

    @discardableResult
    func write(_ string: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) {
        guard pasteboard.changeCount == expected else {
            Log.insertion.debug("Pasteboard changed underneath the paste; leaving it alone")
            return
        }
        pasteboard.clearContents()
        guard let string = snapshot.string else { return }
        pasteboard.setString(string, forType: .string)
    }
}
