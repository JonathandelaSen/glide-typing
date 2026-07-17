import Foundation

/// Owns the latest reversible snapshot. One apply replaces the previous
/// snapshot; the store is in-memory only, so logout or termination clears it.
final class WorkspaceUndoStore {
    private(set) var latest: WorkspaceUndoSnapshot?

    func replace(_ snapshot: WorkspaceUndoSnapshot?) {
        latest = snapshot
    }

    func clear() {
        latest = nil
    }
}
