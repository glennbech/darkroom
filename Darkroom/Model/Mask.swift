import Foundation

/// A local adjustment mask — a shape + its own copy of the adjustment stack.
/// Applied on top of the global pipeline; multiple masks compose in order.
struct Mask: Codable, Equatable, Identifiable {
    let id: UUID
    var kind: MaskKind
    var adjustments: Adjustments
    var isInverted: Bool
    var name: String
    /// Intensity multiplier for the mask's effect, 0…1. Matches Lightroom's
    /// "Amount" slider — scales the mask image before blending, so at 0 the
    /// mask has no effect and at 1 the mask applies its adjustments fully.
    var amount: Double

    init(id: UUID = UUID(),
         kind: MaskKind,
         adjustments: Adjustments = .identity,
         isInverted: Bool = false,
         name: String,
         amount: Double = 1.0) {
        self.id = id
        self.kind = kind
        self.adjustments = adjustments
        self.isInverted = isInverted
        self.name = name
        self.amount = amount
    }

    // MARK: - Codable (forward-compat: missing fields fall back to defaults)

    private enum CodingKeys: String, CodingKey {
        case id, kind, adjustments, isInverted, name, amount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self,        forKey: .id)          ?? UUID()
        kind        = try c.decode(MaskKind.self,             forKey: .kind)
        adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments) ?? .identity
        isInverted  = try c.decodeIfPresent(Bool.self,        forKey: .isInverted)  ?? false
        name        = try c.decodeIfPresent(String.self,      forKey: .name)        ?? "Mask"
        amount      = try c.decodeIfPresent(Double.self,      forKey: .amount)      ?? 1.0
    }
}
