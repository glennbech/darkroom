import Foundation

/// The geometric shape and gradient parameters of a mask.
///
/// All coordinates are normalized to the image's effective extent (0…1), and
/// use CI Y-up convention (y = 0 at the bottom edge). Radii for radial masks
/// are normalized to the shortest image dimension so a mask keeps its visual
/// size across aspect ratios.
enum MaskKind: Codable, Equatable {
    case radial(centerX: Double, centerY: Double,
                radiusInner: Double, radiusOuter: Double)
    case linear(startX: Double, startY: Double,
                endX: Double, endY: Double)

    var label: String {
        switch self {
        case .radial: return "Radial"
        case .linear: return "Linear Gradient"
        }
    }

    /// Sensible default placed roughly in the middle of the canvas.
    /// Wide feather band (0.08 → 0.35 of shortest dim = 27% of the image)
    /// so the falloff is visibly smooth out of the box.
    static func defaultRadial() -> MaskKind {
        .radial(centerX: 0.5, centerY: 0.5,
                radiusInner: 0.08, radiusOuter: 0.35)
    }

    /// Sky-darkening default: 100% at the top of the image (and above),
    /// falling to 0% at the middle. Start = fully-affected end, End = unaffected end.
    static func defaultLinear() -> MaskKind {
        .linear(startX: 0.5, startY: 0.9, endX: 0.5, endY: 0.5)
    }
}
