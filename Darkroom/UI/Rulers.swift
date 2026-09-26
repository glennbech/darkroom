import SwiftUI
import AppKit

/// Rulers along the top and left edges of the canvas, in centimetres.
///
/// Ticks are drawn against the current view zoom + offset, so they always
/// mark real-world positions on the source image. The origin (0 cm) is the
/// image's top-left. No inches — ever.
enum RulerMetrics {
    static let thickness: CGFloat = 20
    /// Convert image pixels to centimetres via the document DPI.
    /// 1 inch = 2.54 cm, so cm-per-pixel = 2.54 / DPI.
    static func pointsPerCm(zoom: CGFloat, dpi: Double) -> CGFloat {
        CGFloat(dpi / 2.54) * zoom
    }
}

// MARK: - Horizontal ruler

struct HorizontalRuler: View {
    let zoom: CGFloat
    let viewOffset: CGSize
    let imageWidthPx: Int
    let dpi: Double

    var body: some View {
        Canvas { context, size in
            let ppc = RulerMetrics.pointsPerCm(zoom: zoom, dpi: dpi)
            guard ppc > 0.5 else { return }
            let imgWidth = CGFloat(imageWidthPx) * zoom
            let imageOriginX = (size.width - imgWidth) / 2 + viewOffset.width
            let stride = tickStride(pointsPerCm: ppc)
            let startCm = max(0, -imageOriginX / ppc)
            let endCm = min(CGFloat(imageWidthPx) / CGFloat(dpi / 2.54),
                            (size.width - imageOriginX) / ppc)
            drawHorizontal(context: context, size: size,
                           origin: imageOriginX, ppc: ppc,
                           stride: stride, startCm: startCm, endCm: endCm)
        }
        .background(rulerBackground)
        .allowsHitTesting(false)
    }

    private func drawHorizontal(context: GraphicsContext, size: CGSize,
                                origin: CGFloat, ppc: CGFloat,
                                stride: Double, startCm: CGFloat, endCm: CGFloat) {
        let first = (Double(startCm) / stride).rounded(.down) * stride
        let last  = (Double(endCm)   / stride).rounded(.up)   * stride
        var value = first
        while value <= last + 0.001 {
            let x = origin + CGFloat(value) * ppc
            let isMajor = isMajorTick(value: value, stride: stride)
            let tickLen: CGFloat = isMajor ? 8 : 4
            var path = Path()
            path.move(to: CGPoint(x: x, y: size.height))
            path.addLine(to: CGPoint(x: x, y: size.height - tickLen))
            context.stroke(path, with: .color(tickColor), lineWidth: 0.5)
            if isMajor && ppc * CGFloat(stride) > 24 {
                let label = Text(labelString(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: x + 2, y: 5), anchor: .leading)
            }
            value += stride
        }
    }
}

// MARK: - Vertical ruler

struct VerticalRuler: View {
    let zoom: CGFloat
    let viewOffset: CGSize
    let imageHeightPx: Int
    let dpi: Double

    var body: some View {
        Canvas { context, size in
            let ppc = RulerMetrics.pointsPerCm(zoom: zoom, dpi: dpi)
            guard ppc > 0.5 else { return }
            let imgHeight = CGFloat(imageHeightPx) * zoom
            // View is Y-up (isFlipped=false); ruler shows 0 at TOP of image,
            // increasing downward — so we invert the ruler y coord vs the view.
            let imageOriginYBottom = (size.height - imgHeight) / 2 - viewOffset.height
            let stride = tickStride(pointsPerCm: ppc)
            let heightCm = CGFloat(imageHeightPx) / CGFloat(dpi / 2.54)
            let startCm = max(0, -imageOriginYBottom / ppc)
            let endCm = min(heightCm, (size.height - imageOriginYBottom) / ppc)
            drawVertical(context: context, size: size,
                         origin: imageOriginYBottom, ppc: ppc,
                         stride: stride, startCm: startCm, endCm: endCm,
                         imageHeightCm: heightCm)
        }
        .background(rulerBackground)
        .allowsHitTesting(false)
    }

    private func drawVertical(context: GraphicsContext, size: CGSize,
                              origin: CGFloat, ppc: CGFloat,
                              stride: Double, startCm: CGFloat, endCm: CGFloat,
                              imageHeightCm: CGFloat) {
        let first = (Double(startCm) / stride).rounded(.down) * stride
        let last  = (Double(endCm)   / stride).rounded(.up)   * stride
        var value = first
        while value <= last + 0.001 {
            // Y from the TOP of the image, increasing downward.
            let y = origin + (imageHeightCm - CGFloat(value)) * ppc
            let isMajor = isMajorTick(value: value, stride: stride)
            let tickLen: CGFloat = isMajor ? 8 : 4
            var path = Path()
            path.move(to: CGPoint(x: size.width, y: y))
            path.addLine(to: CGPoint(x: size.width - tickLen, y: y))
            context.stroke(path, with: .color(tickColor), lineWidth: 0.5)
            if isMajor && ppc * CGFloat(stride) > 24 {
                context.drawLayer { layer in
                    layer.rotate(by: .degrees(-90))
                    layer.translateBy(x: -y, y: 0)
                    let label = Text(labelString(value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    layer.draw(label, at: CGPoint(x: 0, y: 5), anchor: .leading)
                }
            }
            value += stride
        }
    }
}

// MARK: - Shared helpers

private var tickColor: Color { Color.primary.opacity(0.45) }

private var rulerBackground: some View {
    Rectangle().fill(.bar)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .overlay(Divider().opacity(0.5), alignment: .trailing)
}

/// Choose a tick spacing that keeps labels legible at the current scale.
private func tickStride(pointsPerCm: CGFloat) -> Double {
    switch pointsPerCm {
    case 60...:       return 0.5
    case 20..<60:     return 1
    case 8..<20:      return 5
    case 3..<8:       return 10
    default:          return 50
    }
}

private func isMajorTick(value: Double, stride: Double) -> Bool {
    // Every tick is major when stride >= 1; sub-cm strides get major every whole cm.
    if stride >= 1 { return true }
    return abs(value - value.rounded()) < 0.001
}

private func labelString(_ value: Double) -> String {
    if value == value.rounded() { return String(Int(value)) }
    return String(format: "%.1f", value)
}
