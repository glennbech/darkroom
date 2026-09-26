import SwiftUI

/// Vertical icon rail — always visible on the right edge, like Lightroom.
/// Clicking an icon toggles its panel; clicking the active one collapses.
struct RightRail: View {
    @Binding var active: DockPanel?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(DockPanel.allCases) { panel in
                RailButton(panel: panel, isActive: active == panel) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        active = active == panel ? nil : panel
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 44)
        .background(.bar)
        .overlay(Divider().opacity(0.5), alignment: .leading)
    }
}

private struct RailButton: View {
    let panel: DockPanel
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
                Image(systemName: panel.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(panel.title) (⌘⌥\(panel.shortcutDigit))")
    }
}
