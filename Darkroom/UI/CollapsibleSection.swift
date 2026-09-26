import SwiftUI

/// A section with a chevron-toggled disclosure, styled to match Lightroom's
/// panel groups. Independent expanded state per section instance.
struct CollapsibleSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool = true
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .transition(.opacity)
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
