import Foundation

/// Where an `AdjustmentSlidersView` writes its slider values — the document's
/// global `Adjustments`, or a specific mask's `Adjustments`.
enum AdjustmentTarget: Equatable, Hashable {
    case global
    case mask(UUID)
}
