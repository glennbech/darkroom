import SwiftUI

/// Luminance histogram of the current preview output.
///
/// The bars ARE the tone-curve visualization — as you drag Exposure or Contrast
/// the distribution stretches and shifts in real time. No overlaid curve line
/// is needed (or wanted): the histogram is the ground truth.
struct HistogramView: View {
    let histogram: [Float]

    var body: some View {
        Canvas { context, size in
            drawGrid(in: context, size: size)
            drawHistogram(in: context, size: size)
        }
        .aspectRatio(1.6, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Drawing

    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        let color = Color.primary.opacity(0.08)
        for i in 1..<4 {
            let x = size.width * CGFloat(i) / 4
            let y = size.height * CGFloat(i) / 4
            context.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: size.height)) },
                           with: .color(color), lineWidth: 0.5)
            context.stroke(Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: size.width, y: y)) },
                           with: .color(color), lineWidth: 0.5)
        }
    }

    private func drawHistogram(in context: GraphicsContext, size: CGSize) {
        guard !histogram.isEmpty else { return }
        let maxValue = max(histogram.max() ?? 1, 0.0001)
        let barWidth = size.width / CGFloat(histogram.count)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, value) in histogram.enumerated() {
            let normalized = min(1, sqrt(CGFloat(value / maxValue)))
            path.addLine(to: CGPoint(x: CGFloat(i) * barWidth,
                                     y: size.height * (1 - normalized)))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(.secondary.opacity(0.7)))
    }
}
