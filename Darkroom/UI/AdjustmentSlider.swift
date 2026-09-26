import SwiftUI

/// A labeled slider row with numeric readout and reset-on-double-click.
/// Uses the native macOS Slider (proper handle + accessibility for free)
/// with a subtle center tick for bipolar ranges.
struct AdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let onEditingChanged: (Bool) -> Void

    private var displayValue: Int {
        Int((value * 100).rounded())
    }

    private var readout: String {
        if range.lowerBound < 0 {
            return displayValue > 0 ? "+\(displayValue)" : "\(displayValue)"
        }
        return "\(displayValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onEditingChanged(true)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            value = defaultValue
                        }
                        onEditingChanged(false)
                    }
                    .help("Double-click to reset")

                Spacer()

                Text(readout)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(displayValue == 0 ? .secondary : .primary)
                    .frame(minWidth: 34, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.05), value: displayValue)
            }

            ZStack {
                // Bipolar center tick, drawn behind the native slider.
                if range.lowerBound < 0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 1, height: 8)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
                Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                    .controlSize(.small)
            }
            .frame(height: 20)
        }
    }
}
