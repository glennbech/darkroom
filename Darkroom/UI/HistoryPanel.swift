import SwiftUI

/// Dockable panel showing the ordered history of committed edits.
/// Clicking a row jumps the document to that state (registers as one undo unit).
struct HistoryPanel: View {
    let document: StarDocument
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        entries
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: document.history.currentIndex) { _, newIndex in
                    scroll(proxy: proxy, to: newIndex)
                }
            }
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow))
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { note in
            guard let obj = note.object as AnyObject?, obj === document else { return }
            refreshTick &+= 1
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("History")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(document.history.entries.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VisualEffect(material: .titlebar, blending: .withinWindow))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var entries: some View {
        let list = document.history.entries
        let current = document.history.currentIndex
        return ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
            HistoryRow(entry: entry, isCurrent: index == current) {
                document.history.restore(to: index)
            }
            .id(entry.id)
        }
    }

    private func scroll(proxy: ScrollViewProxy, to index: Int) {
        guard document.history.entries.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(document.history.entries[index].id, anchor: .center)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                marker
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.82))
                        .lineLimit(1)
                    Text(relativeTime)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var marker: some View {
        Circle()
            .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 6, height: 6)
    }

    @ViewBuilder private var rowBackground: some View {
        if isCurrent {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .padding(.horizontal, 6)
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.timestamp, relativeTo: Date())
    }
}
