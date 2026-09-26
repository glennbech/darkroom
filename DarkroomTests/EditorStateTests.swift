import XCTest
import CoreImage
@testable import Darkroom

final class EditorStateTests: XCTestCase {

    // MARK: - Size derivation

    func test_effectiveSize_emptyState_returnsSourceDimensions() {
        let state = EditorState.empty
        let size = state.effectiveSize(sourceWidth: 4000, sourceHeight: 3000)
        XCTAssertEqual(size.width, 4000)
        XCTAssertEqual(size.height, 3000)
    }

    func test_effectiveSize_singleResize_returnsResizedDimensions() {
        var state = EditorState.empty
        state.operations.append(.resize(width: 800, height: 600, method: .lanczos))
        let size = state.effectiveSize(sourceWidth: 4000, sourceHeight: 3000)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func test_effectiveSize_multipleResizes_returnsLastDimensions() {
        var state = EditorState.empty
        state.operations.append(.resize(width: 2000, height: 1500, method: .lanczos))
        state.operations.append(.resize(width: 500, height: 375, method: .lanczos))
        let size = state.effectiveSize(sourceWidth: 4000, sourceHeight: 3000)
        XCTAssertEqual(size.width, 500)
        XCTAssertEqual(size.height, 375)
    }

    // MARK: - Purity

    func test_evaluate_isDeterministic() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var state = EditorState.empty
        state.adjustments.exposure = 0.3
        state.operations.append(.resize(width: 50, height: 50, method: .lanczos))

        let a = state.evaluate(source: source)
        let b = state.evaluate(source: source)
        XCTAssertEqual(a.extent, b.extent)
    }

    // MARK: - Schema versioning

    func test_schema_defaultsToOne() {
        XCTAssertEqual(EditorState().schema, 1)
    }

    func test_codable_roundTripsFullState() throws {
        var input = EditorState()
        input.adjustments.exposure = 0.2
        input.adjustments.sharpness = 0.5
        input.operations.append(.resize(width: 640, height: 480, method: .nearest))

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)
        XCTAssertEqual(input, decoded)
    }

    // MARK: - upserting (idempotency per CLAUDE.md antipattern rule)

    func test_upserting_crop_replacesExistingCrop() {
        let first  = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let second = NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let state = EditorState.empty
            .upserting(.crop(first))
            .upserting(.crop(second))
        XCTAssertEqual(state.operations.count, 1)
        XCTAssertEqual(state.operations.first, .crop(second))
    }

    func test_upserting_straighten_replacesExistingStraighten() {
        let state = EditorState.empty
            .upserting(.straighten(degrees: 5))
            .upserting(.straighten(degrees: -12.5))
        XCTAssertEqual(state.operations.count, 1)
        XCTAssertEqual(state.operations.first, .straighten(degrees: -12.5))
    }

    func test_upserting_rotate90_accumulatesCounts() {
        let state = EditorState.empty
            .upserting(.rotate90(count: 1))
            .upserting(.rotate90(count: 1))
        XCTAssertEqual(state.operations, [.rotate90(count: 2)])
    }

    func test_upserting_rotate90_removesWhenNet360() {
        let state = EditorState.empty
            .upserting(.rotate90(count: 1))
            .upserting(.rotate90(count: 3))
        XCTAssertTrue(state.operations.isEmpty)
    }

    func test_upserting_flip_togglesRepeatedApplications() {
        let state1 = EditorState.empty.upserting(.flip(horizontal: true, vertical: false))
        XCTAssertEqual(state1.operations, [.flip(horizontal: true, vertical: false)])

        let state2 = state1.upserting(.flip(horizontal: true, vertical: false))
        XCTAssertTrue(state2.operations.isEmpty, "Flipping horizontal twice must cancel out")
    }

    func test_upserting_flip_combinesAxesXOR() {
        let state = EditorState.empty
            .upserting(.flip(horizontal: true,  vertical: false))
            .upserting(.flip(horizontal: false, vertical: true))
        XCTAssertEqual(state.operations, [.flip(horizontal: true, vertical: true)])
    }

    func test_upserting_resize_appendsRatherThanReplacing() {
        let state = EditorState.empty
            .upserting(.resize(width: 1000, height: 1000, method: .lanczos))
            .upserting(.resize(width:  500, height:  500, method: .lanczos))
        XCTAssertEqual(state.operations.count, 2)
    }

    func test_upserting_isPure() {
        // Confirm the receiver is not mutated (value-type sanity check).
        let original = EditorState.empty
        _ = original.upserting(.straighten(degrees: 45))
        XCTAssertTrue(original.operations.isEmpty)
    }

    // MARK: - effectiveSize skipCrop

    func test_effectiveSize_skipCrop_ignoresCropOperations() {
        var state = EditorState.empty
        state.operations.append(.crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let full = state.effectiveSize(sourceWidth: 1000, sourceHeight: 1000, skipCrop: true)
        XCTAssertEqual(full.width, 1000)
        XCTAssertEqual(full.height, 1000)
    }

    func test_effectiveSize_skipCrop_stillAppliesResizeAndRotate() {
        var state = EditorState.empty
        state.operations.append(.crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        state.operations.append(.rotate90(count: 1))
        let size = state.effectiveSize(sourceWidth: 400, sourceHeight: 200, skipCrop: true)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 400)
    }
}
