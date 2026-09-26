import SwiftUI

/// The "Amount" slider for a mask — Lightroom's global intensity multiplier.
/// 0 = mask has no effect, 100 = full effect. Live-drags mutate the model;
/// drag-end commits one history entry.
struct MaskAmountSlider: View {
    let document: StarDocument
    let maskID: UUID

    @State private var amount: Double
    @State private var snapshot: Double?

    init(document: StarDocument, maskID: UUID) {
        self.document = document
        self.maskID = maskID
        let initial = document.canvas.state.masks.first(where: { $0.id == maskID })?.amount ?? 1.0
        _amount = State(initialValue: initial)
    }

    var body: some View {
        AdjustmentSlider(
            label: "Amount",
            value: binding,
            range: 0...1,
            defaultValue: 1.0,
            onEditingChanged: handleEditing
        )
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidChange)) { note in
            guard let obj = note.object as AnyObject?, obj === document else { return }
            let modelValue = document.canvas.state.masks.first(where: { $0.id == maskID })?.amount ?? 1.0
            if modelValue != amount { amount = modelValue }
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: { amount },
            set: { newValue in
                amount = newValue
                write(newValue)
                NotificationCenter.default.post(name: .canvasDidChange, object: document)
            }
        )
    }

    private func handleEditing(_ editing: Bool) {
        if editing {
            snapshot = read()
            document.canvas.maskOverlayHidden = true
            NotificationCenter.default.post(name: .canvasDidChange, object: document)
            return
        }
        document.canvas.maskOverlayHidden = false
        let now = read()
        guard let snap = snapshot, snap != now else {
            snapshot = nil
            NotificationCenter.default.post(name: .canvasDidChange, object: document)
            return
        }
        let delta = now - snap
        let sign = delta >= 0 ? "+" : ""
        document.commitAdjustments(named: "Mask Amount \(sign)\(String(format: "%.2f", delta))")
        snapshot = nil
    }

    private func read() -> Double {
        document.canvas.state.masks.first(where: { $0.id == maskID })?.amount ?? 1.0
    }

    private func write(_ value: Double) {
        guard let index = document.canvas.state.masks.firstIndex(where: { $0.id == maskID }) else { return }
        document.canvas.state.masks[index].amount = value
    }
}
