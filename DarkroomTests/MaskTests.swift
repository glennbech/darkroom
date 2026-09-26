import XCTest
@testable import Darkroom

final class MaskTests: XCTestCase {

    // MARK: - Defaults

    func test_defaultRadial_isCentered() {
        guard case .radial(let cx, let cy, let r0, let r1) = MaskKind.defaultRadial() else {
            return XCTFail("Expected radial")
        }
        XCTAssertEqual(cx, 0.5, accuracy: 0.001)
        XCTAssertEqual(cy, 0.5, accuracy: 0.001)
        XCTAssertLessThan(r0, r1, "Inner radius must be less than outer for a valid feather")
    }

    func test_defaultLinear_definesADirectionalGradient() {
        guard case .linear(let sx, let sy, let ex, let ey) = MaskKind.defaultLinear() else {
            return XCTFail("Expected linear")
        }
        XCTAssertNotEqual(NSPoint(x: sx, y: sy), NSPoint(x: ex, y: ey),
                          "Start and end must differ for a directional gradient")
    }

    func test_maskKind_hasHumanReadableLabels() {
        XCTAssertEqual(MaskKind.defaultRadial().label, "Radial")
        XCTAssertEqual(MaskKind.defaultLinear().label, "Linear Gradient")
    }

    // MARK: - Codable

    func test_mask_roundTripsThroughJSON() throws {
        var m = Mask(kind: .defaultRadial(), name: "Sky")
        m.adjustments.exposure = 0.3
        m.isInverted = true

        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Mask.self, from: data)

        XCTAssertEqual(m.id, decoded.id)
        XCTAssertEqual(m.kind, decoded.kind)
        XCTAssertEqual(m.adjustments, decoded.adjustments)
        XCTAssertEqual(m.isInverted, decoded.isInverted)
        XCTAssertEqual(m.name, decoded.name)
    }

    func test_mask_missingFieldsDecodeToDefaults() throws {
        // Minimal JSON — only kind is required.
        let json = """
        {"kind":{"radial":{"centerX":0.5,"centerY":0.5,"radiusInner":0.1,"radiusOuter":0.2}}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Mask.self, from: json)
        XCTAssertEqual(decoded.adjustments, .identity)
        XCTAssertFalse(decoded.isInverted)
        XCTAssertEqual(decoded.name, "Mask")
    }

    // MARK: - EditorState integration

    func test_editorState_startsWithNoMasks() {
        XCTAssertTrue(EditorState.empty.masks.isEmpty)
    }

    func test_editorState_codableSurvivesRoundTripWithMasks() throws {
        var state = EditorState.empty
        state.masks.append(Mask(kind: .defaultRadial(), name: "One"))
        state.masks.append(Mask(kind: .defaultLinear(), name: "Two"))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditorState.self, from: data)
        XCTAssertEqual(state.masks.count, decoded.masks.count)
        XCTAssertEqual(state.masks[0].name, decoded.masks[0].name)
        XCTAssertEqual(state.masks[1].kind, decoded.masks[1].kind)
    }

    func test_editorState_missingMasksFieldDecodesEmpty() throws {
        // Older on-disk version without the masks field.
        let json = #"{"schema":1,"operations":[],"adjustments":{}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorState.self, from: json)
        XCTAssertTrue(decoded.masks.isEmpty)
    }

    // MARK: - Handle positions (pure geometry)

    func test_radial_handlePositions_includeCenterAndOuterEdge() {
        let kind = MaskKind.radial(centerX: 0.5, centerY: 0.5,
                                   radiusInner: 0.1, radiusOuter: 0.2)
        let positions = kind.handlePositions(imageWidth: 400, imageHeight: 400)
        XCTAssertEqual(positions[.center], CGPoint(x: 200, y: 200))
        XCTAssertNotNil(positions[.radiusEdge])
        // At outer radius (0.2 * 400 = 80) along +X from center.
        XCTAssertEqual(positions[.radiusEdge], CGPoint(x: 280, y: 200))
    }

    func test_linear_handlePositions_includeEndpointsAndMidpoint() {
        let kind = MaskKind.linear(startX: 0.2, startY: 0.8, endX: 0.8, endY: 0.2)
        let positions = kind.handlePositions(imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(positions[.startPoint], CGPoint(x: 20, y: 80))
        XCTAssertEqual(positions[.endPoint],   CGPoint(x: 80, y: 20))
        XCTAssertEqual(positions[.midpoint],   CGPoint(x: 50, y: 50))
    }

    // MARK: - Kind mutations

    func test_translated_shiftsRadialCenterAndClampsToUnitSquare() {
        let kind = MaskKind.radial(centerX: 0.5, centerY: 0.5,
                                   radiusInner: 0.1, radiusOuter: 0.2)
        guard case .radial(let cx, let cy, _, _) =
                kind.translated(byNormalizedDelta: 0.3, dy: -0.2) else {
            return XCTFail("Should still be radial")
        }
        XCTAssertEqual(cx, 0.8, accuracy: 0.001)
        XCTAssertEqual(cy, 0.3, accuracy: 0.001)

        guard case .radial(let cx2, let cy2, _, _) =
                kind.translated(byNormalizedDelta: 5, dy: -5) else {
            return XCTFail("Should still be radial")
        }
        XCTAssertEqual(cx2, 1.0)
        XCTAssertEqual(cy2, 0.0)
    }

    func test_translated_shiftsLinearStartAndEndTogether() {
        let kind = MaskKind.linear(startX: 0.2, startY: 0.2, endX: 0.4, endY: 0.6)
        guard case .linear(let sx, let sy, let ex, let ey) =
                kind.translated(byNormalizedDelta: 0.1, dy: 0.1) else {
            return XCTFail("Should still be linear")
        }
        XCTAssertEqual(sx, 0.3, accuracy: 0.001)
        XCTAssertEqual(sy, 0.3, accuracy: 0.001)
        XCTAssertEqual(ex, 0.5, accuracy: 0.001)
        XCTAssertEqual(ey, 0.7, accuracy: 0.001)
    }

    func test_settingRadius_preservesFeatherRatio() {
        let kind = MaskKind.radial(centerX: 0.5, centerY: 0.5,
                                   radiusInner: 0.1, radiusOuter: 0.2)  // ratio 0.5
        guard case .radial(_, _, let r0, let r1) = kind.settingRadius(0.4) else {
            return XCTFail("Should still be radial")
        }
        XCTAssertEqual(r1, 0.4, accuracy: 0.001)
        XCTAssertEqual(r0, 0.2, accuracy: 0.001)  // 0.4 * 0.5
    }

    func test_settingLinearEndpoint_updatesOnlyThatEnd() {
        let kind = MaskKind.linear(startX: 0.2, startY: 0.8, endX: 0.8, endY: 0.2)
        guard case .linear(let sx, let sy, let ex, let ey) =
                kind.settingLinearEndpoint(.endPoint, to: (x: 0.9, y: 0.1)) else {
            return XCTFail("Should still be linear")
        }
        XCTAssertEqual(sx, 0.2, accuracy: 0.001)
        XCTAssertEqual(sy, 0.8, accuracy: 0.001)
        XCTAssertEqual(ex, 0.9, accuracy: 0.001)
        XCTAssertEqual(ey, 0.1, accuracy: 0.001)
    }

    func test_settingRadius_isNoOpForLinear() {
        let kind = MaskKind.defaultLinear()
        XCTAssertEqual(kind.settingRadius(0.5), kind)
    }

    // MARK: - Amount

    func test_mask_defaultAmountIsOne() {
        let mask = Mask(kind: .defaultRadial(), name: "test")
        XCTAssertEqual(mask.amount, 1.0)
    }

    func test_mask_codable_missingAmountDecodesToOne() throws {
        // Simulates a pre-Amount on-disk mask.
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111",
         "kind":{"radial":{"centerX":0.5,"centerY":0.5,"radiusInner":0.1,"radiusOuter":0.2}},
         "adjustments":{},"isInverted":false,"name":"legacy"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Mask.self, from: json)
        XCTAssertEqual(decoded.amount, 1.0)
    }

    func test_mask_codable_roundTripsAmount() throws {
        var mask = Mask(kind: .defaultLinear(), name: "test")
        mask.amount = 0.42
        let data = try JSONEncoder().encode(mask)
        let decoded = try JSONDecoder().decode(Mask.self, from: data)
        XCTAssertEqual(decoded.amount, 0.42, accuracy: 0.001)
    }
}
