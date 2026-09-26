import XCTest
import CoreImage
@testable import Darkroom

final class AdjustmentsTests: XCTestCase {

    // MARK: - Identity

    func test_identity_isDefault() {
        XCTAssertEqual(Adjustments(), Adjustments.identity)
        XCTAssertTrue(Adjustments.identity.isIdentity)
    }

    func test_isIdentity_falseWhenAnyFieldChanged() {
        let cases: [(String, WritableKeyPath<Adjustments, Double>)] = [
            ("exposure",       \.exposure),
            ("contrast",       \.contrast),
            ("highlights",     \.highlights),
            ("shadows",        \.shadows),
            ("whites",         \.whites),
            ("blacks",         \.blacks),
            ("texture",        \.texture),
            ("clarity",        \.clarity),
            ("dehaze",         \.dehaze),
            ("grain",          \.grain),
            ("sharpness",      \.sharpness),
            ("noiseReduction", \.noiseReduction),
        ]
        for (name, kp) in cases {
            var a = Adjustments()
            a[keyPath: kp] = 0.3
            XCTAssertFalse(a.isIdentity, "Setting \(name) should defeat identity")
        }
    }

    // MARK: - Codable

    func test_codable_roundTripsAllFields() throws {
        var input = Adjustments()
        input.exposure       = 0.42
        input.contrast       = -0.17
        input.highlights     = -0.5
        input.shadows        = 0.33
        input.whites         = 0.11
        input.blacks         = -0.22
        input.texture        = 0.55
        input.clarity        = -0.31
        input.dehaze         = 0.19
        input.grain          = 0.4
        input.sharpness      = 0.66
        input.noiseReduction = 0.28

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: data)
        XCTAssertEqual(input, decoded)
    }

    func test_codable_missingFieldsDecodeToDefaults() throws {
        // Simulates an older on-disk version that lacked the Effects/Detail fields.
        let json = #"{"exposure":0.5,"contrast":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Adjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 0.5)
        XCTAssertEqual(decoded.contrast, 0)
        XCTAssertEqual(decoded.highlights, 0)
        XCTAssertEqual(decoded.shadows, 0)
        XCTAssertEqual(decoded.whites, 0)
        XCTAssertEqual(decoded.blacks, 0)
        XCTAssertEqual(decoded.sharpness, 0)
        XCTAssertEqual(decoded.texture, 0)
        XCTAssertEqual(decoded.clarity, 0)
        XCTAssertEqual(decoded.dehaze, 0)
        XCTAssertEqual(decoded.grain, 0)
        XCTAssertEqual(decoded.noiseReduction, 0)
    }

    // MARK: - Tone curve

    func test_toneCurve_identityReturnsIdentityCurve() {
        let curve = Adjustments.identity.toneCurvePoints
        XCTAssertEqual(curve.count, 5)
        for (index, point) in curve.enumerated() {
            let expected = Double(index) * 0.25
            XCTAssertEqual(point.x, expected, accuracy: 0.001)
            XCTAssertEqual(point.y, expected, accuracy: 0.001)
        }
    }

    func test_toneCurve_positiveShadowsLiftsPoint1() {
        var a = Adjustments(); a.shadows = 1.0
        let point1 = a.toneCurvePoints[1]
        XCTAssertGreaterThan(point1.y, 0.25)
    }

    func test_toneCurve_positiveHighlightsRecoversPoint3() {
        var a = Adjustments(); a.highlights = 1.0
        let point3 = a.toneCurvePoints[2 + 1]
        XCTAssertLessThan(point3.y, 0.75)
    }

    func test_toneCurve_alwaysClampedBetweenZeroAndOne() {
        var a = Adjustments()
        a.blacks = -1; a.shadows = -1; a.highlights = 1; a.whites = -1
        for point in a.toneCurvePoints {
            XCTAssertGreaterThanOrEqual(point.y, 0.0)
            XCTAssertLessThanOrEqual(point.y, 1.0)
        }
    }

    // MARK: - Apply preserves extent

    func test_apply_identityReturnsEquivalentExtent() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let result = Adjustments.identity.apply(to: source)
        XCTAssertEqual(result.extent, source.extent)
    }
}
