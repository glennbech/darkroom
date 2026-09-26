import SwiftUI
import AppKit

/// Top-level document window content.
///
/// Layout (Lightroom-style):
///  ┌──────────────────────────────────────────────────┐
///  │ TopBar (zoom controls, file title)               │
///  ├───────────────────────────────┬──────────┬───────┤
///  │                               │          │       │
///  │           Canvas              │  Dock    │ Rail  │
///  │        (MTKView surface)      │ (300px)  │(44px) │
///  │                               │          │       │
///  ├───────────────────────────────┴──────────┴───────┤
///  │ Info HUD (dimensions, cursor)                    │
///  └──────────────────────────────────────────────────┘
///
/// The canvas MTKView is NEVER torn down across renders — it stays as a stable
/// AppKit view, and redraws itself when it receives .canvasDidChange.
struct ContentView: View {
    let document: StarDocument

    @State private var activePanel: DockPanel? = nil
    @State private var zoom: CGFloat = 1.0
    @State private var viewOffset: CGSize = .zero
    @State private var cursorInImage: CGPoint? = nil
    @State private var showRulers: Bool = false

    private static let dockWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            topBar
            mainRow
            InfoHUD(document: document, cursorInImage: cursorInImage)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: .togglePanel), perform: handleTogglePanel)
        .onReceive(NotificationCenter.default.publisher(for: .toggleRulers)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { showRulers.toggle() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Spacer()
            ZoomControls(zoom: zoom)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider().opacity(0.6), alignment: .bottom)
    }

    // MARK: - Main content

    private var mainRow: some View {
        HStack(spacing: 0) {
            canvasWithOptionalRulers
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let panel = activePanel {
                Divider().opacity(0.5)
                dockContent(for: panel)
                    .frame(width: Self.dockWidth)
                    .transition(.move(edge: .trailing))
            }

            RightRail(active: $activePanel)
        }
        .clipped()
    }

    @ViewBuilder
    private var canvasWithOptionalRulers: some View {
        if showRulers {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Rectangle().fill(.bar).frame(width: RulerMetrics.thickness,
                                                 height: RulerMetrics.thickness)
                        .overlay(Divider().opacity(0.5), alignment: .bottom)
                        .overlay(Divider().opacity(0.5), alignment: .trailing)
                    HorizontalRuler(zoom: zoom,
                                    viewOffset: viewOffset,
                                    imageWidthPx: document.canvas.width,
                                    dpi: document.canvas.dpi)
                        .frame(height: RulerMetrics.thickness)
                }
                HStack(spacing: 0) {
                    VerticalRuler(zoom: zoom,
                                  viewOffset: viewOffset,
                                  imageHeightPx: document.canvas.height,
                                  dpi: document.canvas.dpi)
                        .frame(width: RulerMetrics.thickness)
                    canvas
                }
            }
        } else {
            canvas
        }
    }

    private var canvas: some View {
        CanvasView(document: document,
                   zoom: $zoom,
                   viewOffset: $viewOffset,
                   cursorInImage: $cursorInImage,
                   activePanel: activePanel)
    }

    @ViewBuilder
    private func dockContent(for panel: DockPanel) -> some View {
        switch panel {
        case .adjustments: AdjustmentsPanel(document: document)
        case .crop:        CropPanel(document: document)
        case .masks:       MasksPanel(document: document)
        case .history:     HistoryPanel(document: document)
        }
    }

    // MARK: - Notifications

    private func handleTogglePanel(_ note: Notification) {
        guard let obj = note.object as AnyObject?, obj === document,
              let raw = note.userInfo?["panel"] as? String,
              let panel = DockPanel(rawValue: raw) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            activePanel = activePanel == panel ? nil : panel
        }
    }
}

// MARK: - Zoom controls

private struct ZoomControls: View {
    let zoom: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            iconButton("minus.magnifyingglass", help: "Zoom Out (⌘−)") {
                NotificationCenter.default.post(name: .zoomOut, object: nil)
            }
            Text("\(Int((zoom * 100).rounded()))%")
                .monospacedDigit()
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 44)
            iconButton("plus.magnifyingglass", help: "Zoom In (⌘+)") {
                NotificationCenter.default.post(name: .zoomIn, object: nil)
            }
            Divider().frame(height: 18).padding(.horizontal, 8).opacity(0.5)
            pillButton("Fit", help: "Fit on Screen (⌘0)") {
                NotificationCenter.default.post(name: .zoomFit, object: nil)
            }
            pillButton("100%", help: "Actual Size (⌘1)") {
                NotificationCenter.default.post(name: .zoomActual, object: nil)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func pillButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Info HUD

private struct InfoHUD: View {
    let document: StarDocument
    let cursorInImage: CGPoint?

    var body: some View {
        HStack(spacing: 16) {
            Label("\(document.canvas.width) × \(document.canvas.height)", systemImage: "photo")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let p = cursorInImage {
                Label("\(Int(p.x)), \(Int(p.y))", systemImage: "scope")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Spacer()
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, minHeight: 26)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(Divider().opacity(0.6), alignment: .top)
        .animation(.easeInOut(duration: 0.15), value: cursorInImage != nil)
    }
}
