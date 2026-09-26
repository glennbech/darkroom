import Foundation
import CoreImage

/// Computes a 256-bin luminance histogram from a CIImage.
///
/// Uses CIAreaHistogram (GPU-accelerated) and rasterizes the result to RGBAf.
/// The luminance channel is derived as a weighted RGB average, close enough to
/// perceptual luminance for a UI display.
enum Histogram {

    /// Returns 256 non-negative Floats. Empty array on failure.
    static func luminance(from image: CIImage) -> [Float] {
        guard let filter = CIFilter(name: "CIAreaHistogram") else { return [] }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: "inputExtent")
        filter.setValue(256, forKey: "inputCount")
        filter.setValue(1.0, forKey: "inputScale")

        guard let output = filter.outputImage else { return [] }
        var pixels = [Float](repeating: 0, count: 256 * 4)
        SharedRenderer.shared.context.render(
            output,
            toBitmap: &pixels,
            rowBytes: 256 * 4 * MemoryLayout<Float>.size,
            bounds: output.extent,
            format: .RGBAf,
            colorSpace: nil
        )

        var result = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let r = pixels[i * 4]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            result[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return result
    }
}
