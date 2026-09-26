import Foundation
import AppKit

/// The single source of truth for edit history.
///
/// Owns the ordered list of committed `EditorState` snapshots, the pointer to
/// the current one, and the bridge to `NSUndoManager` so ⌘Z / ⌘⇧Z work.
///
/// Responsibility is intentionally narrow: it manages a list and an index.
/// It does not know about UI, files, or rendering. Callers do the mutation on
/// the model then hand the new state here to be recorded.
///
/// Behavior:
/// - `seed(with:)` initializes the timeline with an "Initial" entry.
/// - `commit(newState:name:)` truncates any redo tail, appends the new entry,
///   moves current to the tip, and registers an undo that walks back one step.
/// - `restore(to:)` jumps to any index (used by undo, redo, and panel clicks).
///   Every restore registers the inverse so ⌘Z keeps working through jumps.
/// - `canUndo` / `canRedo` are derived from the index — always in sync.
final class HistoryManager {

    // MARK: - Delegates

    /// Called whenever the timeline or current index changes so the UI
    /// (canvas, history panel) can refresh. Kept as a plain closure to keep
    /// the manager UI-agnostic and easy to unit-test.
    var onChange: (() -> Void)?

    /// Called when the current state pointer moves. Handed the new state so
    /// the document can push it into the model. Also kept as a closure so the
    /// manager doesn't need a document reference at construction time.
    var applyState: ((EditorState) -> Void)?

    /// Weak reference to the undo manager. Optional so tests can drive the
    /// manager without an NSDocument.
    weak var undoManager: UndoManager?

    // MARK: - State

    private(set) var entries: [HistoryEntry] = []
    private(set) var currentIndex: Int = -1

    var current: HistoryEntry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < entries.count - 1 }

    // MARK: - Lifecycle

    func seed(with state: EditorState, name: String = "Initial") {
        entries = [HistoryEntry(name: name, state: state)]
        currentIndex = 0
        onChange?()
    }

    // MARK: - Commit

    /// Record `newState` as the new tip of the timeline. If we're mid-history
    /// (user jumped back), the redo tail is truncated first — matching
    /// Photoshop behavior. If `newState` equals the current state, it's a no-op.
    func commit(newState: EditorState, name: String) {
        guard entries.indices.contains(currentIndex) else {
            seed(with: newState, name: name)
            return
        }
        guard entries[currentIndex].state != newState else { return }

        let restoreTarget = currentIndex
        truncateRedoTail()
        entries.append(HistoryEntry(name: name, state: newState))
        currentIndex = entries.count - 1
        applyState?(newState)
        registerUndo(returningTo: restoreTarget)
        onChange?()
    }

    // MARK: - Restore

    /// Jump to `targetIndex`. Used by undo, redo, and history-panel clicks.
    /// Registers an inverse so the previous position is one ⌘Z away.
    func restore(to targetIndex: Int) {
        guard entries.indices.contains(targetIndex) else { return }
        guard targetIndex != currentIndex else { return }
        let previousIndex = currentIndex
        currentIndex = targetIndex
        applyState?(entries[targetIndex].state)
        registerUndo(returningTo: previousIndex)
        onChange?()
    }

    // MARK: - Private

    private func truncateRedoTail() {
        let tailStart = currentIndex + 1
        guard tailStart < entries.count else { return }
        entries.removeSubrange(tailStart..<entries.count)
    }

    private func registerUndo(returningTo index: Int) {
        undoManager?.registerUndo(withTarget: self) { manager in
            manager.restore(to: index)
        }
        if let name = entries[safe: currentIndex]?.name {
            undoManager?.setActionName(name)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
