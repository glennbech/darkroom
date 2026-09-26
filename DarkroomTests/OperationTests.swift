import XCTest
import CoreImage
@testable import Darkroom

final class OperationTests: XCTestCase {

    // MARK: - Resize

    func test_resize_transformSize_returnsRequestedDimensions() {
        let op = Operation.resize(width: 1000, height: 500, method: .lanczos)
        let result = op.transformSize((width: 4000, height: 3000))
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.height, 500)
    }

    func test_resize_apply_lanczos_producesTargetExtent() {
        let source = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let op = Operation.resize(width: 50, height: 25, method: .lanczos)
        let result = op.apply(to: source)
        XCTAssertEqual(Int(result.extent.width), 50)
        XCTAssertEqual(Int(result.extent.height), 25)
    }

    func test_resize_apply_nearest_producesTargetExtent() {
        let source = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 300))
        let op = Operation.resize(width: 100, height: 150, method: .nearest)
        let result = op.apply(to: source)
        XCTAssertEqual(Int(result.extent.width), 100)
        XCTAssertEqual(Int(result.extent.height), 150)
    }

    // MARK: - Crop

    func test_crop_transformSize_scalesByRect() {
        let op = Operation.crop(NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.25))
        let result = op.transformSize((width: 1000, height: 800))
        XCTAssertEqual(result.width, 500)
        XCTAssertEqual(result.height, 200)
    }

    func test_crop_fullRect_isNoOp() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let op = Operation.crop(.full)
        let result = op.apply(to: source)
        XCTAssertEqual(result.extent, source.extent)
    }

    func test_crop_producesExpectedExtent() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let op = Operation.crop(NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let result = op.apply(to: source)
        XCTAssertEqual(Int(result.extent.width), 50)
        XCTAssertEqual(Int(result.extent.height), 50)
    }

    // MARK: - Rotate 90°

    func test_rotate90_evenCountsKeepDimensions() {
        let op = Operation.rotate90(count: 2)
        let result = op.transformSize((width: 100, height: 200))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 200)
    }

    func test_rotate90_oddCountsSwapDimensions() {
        let op = Operation.rotate90(count: 1)
        let result = op.transformSize((width: 100, height: 200))
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    func test_rotate90_negativeCountsBehaveLikePositive() {
        let op = Operation.rotate90(count: -1)
        let result = op.transformSize((width: 100, height: 200))
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    // MARK: - Flip

    func test_flip_preservesDimensions() {
        let op = Operation.flip(horizontal: true, vertical: false)
        let result = op.transformSize((width: 100, height: 200))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 200)
    }

    // MARK: - Straighten

    func test_straighten_zeroIsIdentity() {
        let result = Operation.straighten(degrees: 0).transformSize((width: 100, height: 200))
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 200)
    }

    func test_straighten_90DegreesSwapsDimensions() {
        // A 90° straighten produces a swapped bounding box, matching rotate90.
        let result = Operation.straighten(degrees: 90).transformSize((width: 100, height: 200))
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    func test_straighten_45DegreesExpandsBySqrt2ForSquare() {
        // A 45° straighten of a square grows both sides by √2 ≈ 1.414.
        let result = Operation.straighten(degrees: 45).transformSize((width: 100, height: 100))
        XCTAssertEqual(result.width, 141)
        XCTAssertEqual(result.height, 141)
    }

    func test_straighten_negativeAndPositiveProduceSameBoundingBox() {
        let a = Operation.straighten(degrees:  15).transformSize((width: 400, height: 300))
        let b = Operation.straighten(degrees: -15).transformSize((width: 400, height: 300))
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
    }

    func test_straighten_zeroIsNoOp() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let result = Operation.straighten(degrees: 0).apply(to: source)
        XCTAssertEqual(result.extent, source.extent)
    }

    // MARK: - Action names

    func test_actionName_isHumanReadable() {
        XCTAssertEqual(Operation.resize(width: 2400, height: 1600, method: .lanczos).actionName,
                       "Resize to 2400 × 1600")
        XCTAssertEqual(Operation.crop(.full).actionName, "Crop")
        XCTAssertEqual(Operation.rotate90(count: 1).actionName, "Rotate 90°")
        XCTAssertEqual(Operation.rotate90(count: 2).actionName, "Rotate 180°")
        XCTAssertEqual(Operation.flip(horizontal: true, vertical: false).actionName, "Flip Horizontal")
        XCTAssertEqual(Operation.flip(horizontal: false, vertical: true).actionName, "Flip Vertical")
    }

    // MARK: - Codable

    func test_codable_roundTripsAllCases() throws {
        let cases: [Darkroom.Operation] = [
            .resize(width: 1920, height: 1080, method: .lanczos),
            .crop(NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)),
            .straighten(degrees: 7.5),
            .rotate90(count: 3),
            .flip(horizontal: true, vertical: false),
        ]
        for op in cases {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(Darkroom.Operation.self, from: data)
            XCTAssertEqual(op, decoded)
        }
    }

    func test_resizeMethod_isStringRawValue() {
        XCTAssertEqual(ResizeMethod.lanczos.rawValue, "Lanczos")
        XCTAssertEqual(ResizeMethod.nearest.rawValue, "Nearest")
    }
}

final class NormalizedRectConstraintTests: XCTestCase {

    // MARK: - Corners

    func test_constrained_topRightCorner_widthDrives_anchorsBottomLeft() {
        // Original 0.4×0.4. Stretched to 0.6 wide via top-right corner.
        // Width delta > height delta → width drives.
        // ratio = 1 → new size 0.6×0.6, anchored bottom-left of ORIGINAL.
        let original = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)
        let stretched = NormalizedRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        let result = stretched.constrained(toRatio: 1.0, handle: .topRight, original: original)

        XCTAssertEqual(result.width,  0.6, accuracy: 0.001)
        XCTAssertEqual(result.height, 0.6, accuracy: 0.001)
        XCTAssertEqual(result.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.3, accuracy: 0.001)
    }

    func test_constrained_bottomLeftCorner_heightDrives_anchorsTopRight() {
        // Original 0.4×0.4 with top-right at (0.7, 0.7). Height stretched to 0.55.
        let original = NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let stretched = NormalizedRect(x: 0.3, y: 0.15, width: 0.4, height: 0.55)
        let result = stretched.constrained(toRatio: 1.0, handle: .bottomLeft, original: original)

        XCTAssertEqual(result.height, 0.55, accuracy: 0.001)
        XCTAssertEqual(result.width,  0.55, accuracy: 0.001)
        // Top-right of ORIGINAL is (0.7, 0.7) — preserved.
        XCTAssertEqual(result.x + result.width,  0.7, accuracy: 0.001)
        XCTAssertEqual(result.y + result.height, 0.7, accuracy: 0.001)
    }

    // MARK: - Edges

    func test_constrained_rightEdge_widthDrives_centersHeight() {
        let original = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)
        let stretched = NormalizedRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        let result = stretched.constrained(toRatio: 1.0, handle: .right, original: original)

        XCTAssertEqual(result.width,  0.6, accuracy: 0.001)
        XCTAssertEqual(result.height, 0.6, accuracy: 0.001)
        // Left edge preserved
        XCTAssertEqual(result.x, 0.2, accuracy: 0.001)
        // Height centered around the ORIGINAL vertical center (0.3 + 0.2 = 0.5)
        XCTAssertEqual(result.y + result.height / 2, 0.5, accuracy: 0.001)
    }

    func test_constrained_topEdge_heightDrives_centersWidth() {
        let original = NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let stretched = NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.6)
        let result = stretched.constrained(toRatio: 1.0, handle: .top, original: original)

        XCTAssertEqual(result.height, 0.6, accuracy: 0.001)
        XCTAssertEqual(result.width,  0.6, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.3, accuracy: 0.001)
        XCTAssertEqual(result.x + result.width / 2, 0.5, accuracy: 0.001)
    }

    // MARK: - Ratios other than 1:1

    func test_constrained_16by9_widthDrivesHeightFromRatio() {
        let original = NormalizedRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
        let stretched = NormalizedRect(x: 0.1, y: 0.4, width: 0.9, height: 0.2)
        let result = stretched.constrained(toRatio: 16.0 / 9.0,
                                           handle: .right,
                                           original: original)
        XCTAssertEqual(result.width, 0.9, accuracy: 0.001)
        XCTAssertEqual(result.height, 0.9 * 9.0 / 16.0, accuracy: 0.001)
    }

    // MARK: - Clamping

    func test_constrained_isClampedToUnitSquare() {
        // Force a scenario where derived height would push y below 0.
        let original = NormalizedRect(x: 0, y: 0.1, width: 0.4, height: 0.2)
        let stretched = NormalizedRect(x: 0, y: 0.1, width: 0.9, height: 0.2)
        let result = stretched.constrained(toRatio: 1.0, handle: .right, original: original)
        // Height would be 0.9; y centered around 0.2 means y = -0.25.
        // Clamping keeps y >= 0.
        XCTAssertGreaterThanOrEqual(result.y, 0)
        XCTAssertLessThanOrEqual(result.y + result.height, 1.0)
    }

    // MARK: - No-op cases

    func test_constrained_interiorHandle_noChange() {
        let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8)
        let result = rect.constrained(toRatio: 1.0, handle: .interior, original: rect)
        XCTAssertEqual(result, rect)
    }

    func test_constrained_zeroRatio_noChange() {
        let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8)
        let result = rect.constrained(toRatio: 0, handle: .topLeft, original: rect)
        XCTAssertEqual(result, rect)
    }
}

final class NormalizedRectTests: XCTestCase {

    func test_full_isDefault() {
        XCTAssertTrue(NormalizedRect.full.isFull)
    }

    func test_rectInExtent_scalesCorrectly() {
        let n = NormalizedRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let rect = n.rect(in: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(rect.origin.x, 100)
        XCTAssertEqual(rect.origin.y, 200)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 100)
    }

    // MARK: - Aspect matching

    func test_centeredRect_matchesWiderAspectByPillarBoxingHeight() {
        // Source 4:3 (400×300), request 16:9 → height must shrink.
        let rect = NormalizedRect.centeredRect(matching: 16.0 / 9.0,
                                               in: CGSize(width: 400, height: 300))
        XCTAssertEqual(rect.width, 1.0, accuracy: 0.001)
        XCTAssertLessThan(rect.height, 1.0)
        XCTAssertEqual(rect.x, 0, accuracy: 0.001)
        XCTAssertGreaterThan(rect.y, 0)
    }

    func test_centeredRect_matchesTallerAspectByLetterboxingWidth() {
        // Source 16:9 (1600×900), request 4:3 → width must shrink.
        let rect = NormalizedRect.centeredRect(matching: 4.0 / 3.0,
                                               in: CGSize(width: 1600, height: 900))
        XCTAssertLessThan(rect.width, 1.0)
        XCTAssertEqual(rect.height, 1.0, accuracy: 0.001)
    }

    func test_centeredRect_sameAspectIsFullRect() {
        let rect = NormalizedRect.centeredRect(matching: 3.0 / 2.0,
                                               in: CGSize(width: 3000, height: 2000))
        XCTAssertEqual(rect.width, 1.0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1.0, accuracy: 0.001)
    }
}
