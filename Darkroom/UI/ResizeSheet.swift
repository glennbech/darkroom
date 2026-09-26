import SwiftUI

struct ResizeSheet: View {
    let current: CGSize
    let onCancel: () -> Void
    let onApply: (CGSize, ResizeMethod) -> Void

    @State private var widthText: String
    @State private var heightText: String
    @State private var linked: Bool = true
    @State private var method: ResizeMethod = .lanczos
    @State private var unit: Unit = .pixels

    enum Unit: String, CaseIterable, Identifiable {
        case pixels = "px"
        case percent = "%"
        var id: String { rawValue }
    }

    init(current: CGSize, onCancel: @escaping () -> Void, onApply: @escaping (CGSize, ResizeMethod) -> Void) {
        self.current = current
        self.onCancel = onCancel
        self.onApply = onApply
        _widthText = State(initialValue: String(Int(current.width)))
        _heightText = State(initialValue: String(Int(current.height)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Image")
                .font(.headline)

            HStack {
                Text("Current:")
                    .foregroundStyle(.secondary)
                Text("\(Int(current.width)) × \(Int(current.height)) px")
                    .monospacedDigit()
            }
            .font(.subheadline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit(applyLinkFromWidth)
                    Toggle("", isOn: $linked)
                        .toggleStyle(.button)
                        .help("Link aspect ratio")
                        .labelsHidden()
                }
                GridRow {
                    Text("Height")
                    TextField("", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit(applyLinkFromHeight)
                    Picker("", selection: $unit) {
                        ForEach(Unit.allCases) { u in Text(u.rawValue).tag(u) }
                    }
                    .labelsHidden()
                    .frame(width: 60)
                }
                GridRow {
                    Text("Method")
                    Picker("", selection: $method) {
                        ForEach(ResizeMethod.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Resize") {
                    if let size = resolvedSize() { onApply(size, method) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360, height: 240)
    }

    private func applyLinkFromWidth() {
        guard linked, let w = Double(widthText), current.width > 0 else { return }
        let ratio = current.height / current.width
        heightText = String(Int((w * ratio).rounded()))
    }

    private func applyLinkFromHeight() {
        guard linked, let h = Double(heightText), current.height > 0 else { return }
        let ratio = current.width / current.height
        widthText = String(Int((h * ratio).rounded()))
    }

    private func resolvedSize() -> CGSize? {
        guard let w = Double(widthText), let h = Double(heightText), w > 0, h > 0 else { return nil }
        switch unit {
        case .pixels:
            return CGSize(width: w, height: h)
        case .percent:
            return CGSize(width: current.width * w / 100, height: current.height * h / 100)
        }
    }
}
