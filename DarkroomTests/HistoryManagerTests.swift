import XCTest
@testable import Darkroom

/// HistoryManager is UI-free and NSDocument-free by design, so it's fully
/// testable in isolation. Each test builds a manager, wires a fake applyState
/// sink, drives commit/restore, and asserts invariants.
final class HistoryManagerTests: XCTestCase {

    private func makeManager() -> (HistoryManager, [EditorState]) {
        let manager = HistoryManager()
        var applied: [EditorState] = []
        manager.applyState = { applied.append($0) }
        return (manager, applied)
    }

    private func state(exposure: Double) -> EditorState {
        var s = EditorState.empty
        s.adjustments.exposure = exposure
        return s
    }

    // MARK: - Seeding

    func test_seed_startsWithOneEntry_atIndexZero() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        XCTAssertEqual(m.entries.count, 1)
        XCTAssertEqual(m.currentIndex, 0)
        XCTAssertFalse(m.canUndo)
        XCTAssertFalse(m.canRedo)
    }

    // MARK: - Commit

    func test_commit_appendsAndMovesTip() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        m.commit(newState: state(exposure: 0.3), name: "Exposure +0.30")

        XCTAssertEqual(m.entries.count, 2)
        XCTAssertEqual(m.currentIndex, 1)
        XCTAssertEqual(m.current?.name, "Exposure +0.30")
        XCTAssertTrue(m.canUndo)
        XCTAssertFalse(m.canRedo)
    }

    func test_commit_noOpWhenStateUnchanged() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        m.commit(newState: .empty, name: "no-op")
        XCTAssertEqual(m.entries.count, 1)
    }

    func test_commit_truncatesRedoTailBeforeAppending() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        m.commit(newState: state(exposure: 0.1), name: "A")
        m.commit(newState: state(exposure: 0.2), name: "B")
        m.commit(newState: state(exposure: 0.3), name: "C")

        // Jump back to A (index 1) then commit a new branch — B and C are discarded.
        m.restore(to: 1)
        m.commit(newState: state(exposure: 0.9), name: "D")

        XCTAssertEqual(m.entries.count, 3)              // Initial, A, D
        XCTAssertEqual(m.current?.name, "D")
        XCTAssertFalse(m.canRedo)
    }

    // MARK: - Restore

    func test_restore_movesCurrentAndApplies() {
        let (m, applied) = makeManager()
        var log = applied
        m.applyState = { log.append($0) }
        m.seed(with: .empty)
        m.commit(newState: state(exposure: 0.5), name: "A")

        m.restore(to: 0)

        XCTAssertEqual(m.currentIndex, 0)
        XCTAssertEqual(log.last, .empty)
    }

    func test_restore_noOpWhenAlreadyAtTarget() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        var applyCount = 0
        m.applyState = { _ in applyCount += 1 }
        m.restore(to: 0)
        XCTAssertEqual(applyCount, 0)
    }

    func test_restore_outOfRangeIsIgnored() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        m.restore(to: 99)
        XCTAssertEqual(m.currentIndex, 0)
    }

    // MARK: - canUndo / canRedo

    func test_undoRedoFlags_trackIndexPosition() {
        let (m, _) = makeManager()
        m.seed(with: .empty)
        m.commit(newState: state(exposure: 0.1), name: "A")
        m.commit(newState: state(exposure: 0.2), name: "B")

        XCTAssertTrue(m.canUndo)
        XCTAssertFalse(m.canRedo)

        m.restore(to: 0)
        XCTAssertFalse(m.canUndo)
        XCTAssertTrue(m.canRedo)

        m.restore(to: 1)
        XCTAssertTrue(m.canUndo)
        XCTAssertTrue(m.canRedo)
    }

    // MARK: - Callbacks

    func test_onChange_firedForCommitAndRestore() {
        let m = HistoryManager()
        var count = 0
        m.onChange = { count += 1 }
        m.seed(with: .empty)
        XCTAssertEqual(count, 1)

        m.commit(newState: state(exposure: 0.1), name: "A")
        XCTAssertEqual(count, 2)

        m.restore(to: 0)
        XCTAssertEqual(count, 3)
    }
}
