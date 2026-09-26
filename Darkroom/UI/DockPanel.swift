import SwiftUI

/// Identity for a side-dock panel and its rail button.
/// Add a new panel here → RightRail picks it up automatically → wire it in
/// ContentView's `dockContent(for:)` switch.
enum DockPanel: String, CaseIterable, Identifiable {
    case adjustments
    case crop
    case masks
    case history

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .adjustments: return "slider.horizontal.3"
        case .crop:        return "crop"
        case .masks:       return "circle.dotted"
        case .history:     return "clock.arrow.circlepath"
        }
    }

    var title: String {
        switch self {
        case .adjustments: return "Adjustments"
        case .crop:        return "Crop and Rotate"
        case .masks:       return "Masks"
        case .history:     return "History"
        }
    }

    var shortcutDigit: String {
        switch self {
        case .adjustments: return "1"
        case .crop:        return "2"
        case .masks:       return "3"
        case .history:     return "4"
        }
    }
}
