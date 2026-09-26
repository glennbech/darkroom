import SwiftUI

/// The Light + Detail slider stack, routed to either the global adjustments
/// or a specific mask's adjustments. Shared by AdjustmentsPanel and MasksPanel.
///
/// The view keeps a local mirror (`current`) of the model value so live drag
/// is silky; on drag-end it commits one history entry. It also re-syncs
/// whenever the model changes externally (undo / redo / history jumps / a
/// switch to a different target).
struct AdjustmentSlidersView: View {
    let document: StarDocument
    let target: AdjustmentTarget

    @State private var current: Adjustments
    @State private var dragSnapshot: Adjustments?
    @State private var syncTick: Int = 0

    init(document: StarDocument, target: AdjustmentTarget) {
        self.document = document
        self.target = target
        _current = State(initialValue: Self.read(document: document, target: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CollapsibleSection("Light") {
                slider("Exposure",   \.exposure,   range: -1...1)
                slider("Contrast",   \.contrast,   range: -1...1)
                slider("Highlights", \.highlights, range: -1...1)
                slider("Shadows",    \.shadows,    range: -1...1)
                slider("Whites",     \.whites,     range: -1...1)
                slider("Blacks",     \.blacks,     range: -1...1)
            }
            CollapsibleSection("Effects") {
                slider("Texture", \.texture, range: -1...1)
                slider("Clarity", \.clarity, range: -1...1)
                slider("Dehaze",  \.dehaze,  range: -1...1)
                slider("Grain",   \.grain,   range:  0...1)
            }
            CollapsibleSection("Detail") {
                slider("Sharpness",       \.sharpness,      range: 0...1)
                slider("Noise Reduction", \.noiseReduction, range: 0...1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidChange)) { note in
            guard let obj = note.object as AnyObject?, obj === document else { return }
            resync()
        }
    }

    // MARK: - Slider row

    private func slider(_ label: String,
                        _ keyPath: WritableKeyPath<Adjustments, Double>,
                        range: ClosedRange<Double>) -> some View {
        AdjustmentSlider(
            label: label,
            value: binding(for: keyPath),
            range: range,
            defaultValue: 0,
            onEditingChanged: { editing in handleEditing(editing, keyPath: keyPath, label: label) }
        )
        .id(syncTick)
    }

    private func binding(for keyPath: WritableKeyPath<Adjustments, Double>) -> Binding<Double> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                current[keyPath: keyPath] = newValue
                write(current)
                NotificationCenter.default.post(name: .canvasDidChange, object: document)
            }
        )
    }

    // MARK: - Drag commit

    private func handleEditing(_ editing: Bool,
                               keyPath: WritableKeyPath<Adjustments, Double>,
                               label: String) {
        if editing {
            dragSnapshot = read()
            // Hide the red mask tint while the user is actively adjusting so
            // they can see the actual effect on the pixels.
            document.canvas.maskOverlayHidden = true
            NotificationCenter.default.post(name: .canvasDidChange, object: document)
            return
        }
        document.canvas.maskOverlayHidden = false
        let modelNow = read()
        guard let snap = dragSnapshot, snap != modelNow else {
            dragSnapshot = nil
            NotificationCenter.default.post(name: .canvasDidChange, object: document)
            return
        }
        let delta = modelNow[keyPath: keyPath] - snap[keyPath: keyPath]
        let sign = delta >= 0 ? "+" : ""
        let scope = target == .global ? label : "Mask \(label)"
        document.commitAdjustments(named: "\(scope) \(sign)\(String(format: "%.2f", delta))")
        dragSnapshot = nil
    }

    // MARK: - Read / write

    private func read() -> Adjustments {
        Self.read(document: document, target: target)
    }

    private static func read(document: StarDocument, target: AdjustmentTarget) -> Adjustments {
        switch target {
        case .global: return document.canvas.state.adjustments
        case .mask(let id):
            return document.canvas.state.masks.first(where: { $0.id == id })?.adjustments ?? .identity
        }
    }

    private func write(_ value: Adjustments) {
        switch target {
        case .global:
            document.canvas.state.adjustments = value
        case .mask(let id):
            guard let index = document.canvas.state.masks.firstIndex(where: { $0.id == id }) else { return }
            document.canvas.state.masks[index].adjustments = value
        }
    }

    private func resync() {
        let modelValue = read()
        guard modelValue != current else { return }
        current = modelValue
        syncTick &+= 1
    }
}
