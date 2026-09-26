import SwiftUI

/// Per-mask "Invert" toggle. Flips which side of the gradient is the affected
/// side — outside becomes inside for radials, start becomes end for linears.
/// Commits one history entry per click.
struct MaskInvertToggle: View {
    let document: StarDocument
    let maskID: UUID

    @State private var isInverted: Bool

    init(document: StarDocument, maskID: UUID) {
        self.document = document
        self.maskID = maskID
        let initial = document.canvas.state.masks.first(where: { $0.id == maskID })?.isInverted ?? false
        _isInverted = State(initialValue: initial)
    }

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                Text("Invert mask")
                    .font(.system(size: 10))
            }
        }
        .toggleStyle(.checkbox)
        .help("Flip the affected and unaffected regions of the mask")
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidChange)) { note in
            guard let obj = note.object as AnyObject?, obj === document else { return }
            let modelValue = document.canvas.state.masks.first(where: { $0.id == maskID })?.isInverted ?? false
            if modelValue != isInverted { isInverted = modelValue }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isInverted },
            set: { newValue in
                isInverted = newValue
                write(newValue)
                document.commitAdjustments(named: newValue ? "Invert Mask" : "Uninvert Mask")
            }
        )
    }

    private func write(_ value: Bool) {
        guard let index = document.canvas.state.masks.firstIndex(where: { $0.id == maskID }) else { return }
        document.canvas.state.masks[index].isInverted = value
    }
}
