import SwiftUI
import AppKit

/// Global (whole-image) adjustments — histogram + Light + Detail.
/// Per-mask adjustments live in `MasksPanel`, which reuses the same
/// `AdjustmentSlidersView` under the hood.
struct AdjustmentsPanel: View {
    let document: StarDocument

    @State private var histogram: [Float] = []
    @State private var histogramTask: Task<Void, Never>?

    init(document: StarDocument) {
        self.document = document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    CollapsibleSection("Histogram") {
                        HistogramView(histogram: histogram)
                            .frame(height: 120)
                    }
                    AdjustmentSlidersView(document: document, target: .global)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            Divider().opacity(0.5)
            footer
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow))
        .onAppear { scheduleHistogramRecompute() }
        .onDisappear { histogramTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidChange)) { note in
            guard let obj = note.object as AnyObject?, obj === document else { return }
            scheduleHistogramRecompute()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Adjustments")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if document.canvas.state.adjustments != .identity {
                Button("Reset") { resetGlobal() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                    .help("Reset all global adjustments")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VisualEffect(material: .titlebar, blending: .withinWindow))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(document.canvas.state.adjustments == .identity
                      ? Color.secondary.opacity(0.4)
                      : Color.accentColor)
                .frame(width: 6, height: 6)
            Text(document.canvas.state.adjustments == .identity ? "Original" : "Edited")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func resetGlobal() {
        guard document.canvas.state.adjustments != .identity else { return }
        document.canvas.state.adjustments = .identity
        document.commitAdjustments(named: "Reset Adjustments")
    }

    // MARK: - Histogram

    /// Recompute the histogram of the CURRENT preview output — including any
    /// pending or committed operations and all adjustments and masks. Cancels
    /// any in-flight compute; each new state change owns the visualization.
    private func scheduleHistogramRecompute() {
        histogramTask?.cancel()
        let image = document.canvas.evaluatePreview()
        histogramTask = Task.detached(priority: .userInitiated) {
            let values = Histogram.luminance(from: image)
            if Task.isCancelled { return }
            await MainActor.run { self.histogram = values }
        }
    }
}

/// Bridges NSVisualEffectView so panels get translucent native chrome.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
