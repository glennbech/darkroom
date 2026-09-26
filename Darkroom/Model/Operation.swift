import Foundation
import CoreImage

/// A single non-destructive transformation in the pipeline.
///
/// Cases are additive-only. Never remove or reorder. Codable synthesis uses
/// case names as JSON keys so we're safe against reordering source declarations.
enum Operation: Codable, Equatable {
    case resize(width: Int, height: Int, method: ResizeMethod)
    case crop(NormalizedRect)
    case straighten(degrees: Double)
    case rotate90(count: Int)          // count % 4: 0 = none, 1 = 90° CW, 2 = 180°, 3 = 270°
    case flip(horizontal: Bool, vertical: Bool)

    var actionName: String {
        switch self {
        case .resize(let w, let h, _):     return "Resize to \(w) × \(h)"
        case .crop:                        return "Crop"
        case .straighten(let d):           return "Straighten \(String(format: "%.1f", d))°"
        case .rotate90(let count):         return "Rotate \(((count % 4) + 4) % 4 * 90)°"
        case .flip(let h, let v):
            if h && v { return "Flip Both" }
            if h { return "Flip Horizontal" }
            if v { return "Flip Vertical" }
            return "Flip"
        }
    }

    func transformSize(_ size: (width: Int, height: Int)) -> (width: Int, height: Int) {
        switch self {
        case .resize(let w, let h, _):
            return (w, h)
        case .crop(let rect):
            return (
                max(1, Int((Double(size.width)  * rect.width).rounded())),
                max(1, Int((Double(size.height) * rect.height).rounded()))
            )
        case .rotate90(let count) where (((count % 4) + 4) % 4) % 2 == 1:
            return (size.height, size.width)
        case .rotate90, .flip:
            return size
        case .straighten(let degrees):
            return Self.rotatedBoundingBox(size, degrees: degrees)
        }
    }

    /// Axis-aligned bounding box of a rectangle rotated by `degrees`.
    /// Grows with angle so the crop rectangle can stay screen-aligned atop the
    /// rotated image (Lightroom-style straighten).
    static func rotatedBoundingBox(_ size: (width: Int, height: Int), degrees: Double) -> (width: Int, height: Int) {
        guard degrees != 0 else { return size }
        let radians = abs(degrees) * .pi / 180
        let w = Double(size.width), h = Double(size.height)
        let cosA = abs(cos(radians)), sinA = abs(sin(radians))
        return (
            max(1, Int((w * cosA + h * sinA).rounded())),
            max(1, Int((w * sinA + h * cosA).rounded()))
        )
    }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .resize(let width, let height, let method):
            return ResizeOperation.apply(to: image, width: width, height: height, method: method)
        case .crop(let rect):
            return CropOperation.apply(to: image, rect: rect)
        case .straighten(let degrees):
            return StraightenOperation.apply(to: image, degrees: degrees)
        case .rotate90(let count):
            return Rotate90Operation.apply(to: image, count: count)
        case .flip(let horizontal, let vertical):
            return FlipOperation.apply(to: image, horizontal: horizontal, vertical: vertical)
        }
    }
}

enum ResizeMethod: String, Codable, CaseIterable, Identifiable, Equatable {
    case lanczos = "Lanczos"
    case nearest = "Nearest"
    var id: String { rawValue }
}

// MARK: - Resize

/// Isolated resize logic. Kept as a namespace enum so it's obvious it holds no state.
///
/// CILanczosScaleTransform's `inputScale` scales the vertical axis; `inputAspectRatio`
/// is an additional horizontal multiplier. So target (W, H) from source (w, h) →
/// scale = H/h, aspectRatio = (W/w)/(H/h).
enum ResizeOperation {
    static func apply(to image: CIImage, width: Int, height: Int, method: ResizeMethod) -> CIImage {
        let normalized = normalizeOrigin(image)
        let sourceSize = normalized.extent.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        switch method {
        case .lanczos: return lanczos(normalized, targetWidth: width, targetHeight: height)
        case .nearest: return nearest(normalized, targetWidth: width, targetHeight: height)
        }
    }

    private static func normalizeOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    private static func lanczos(_ image: CIImage, targetWidth: Int, targetHeight: Int) -> CIImage {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        let sourceSize = image.extent.size
        let verticalScale = CGFloat(targetHeight) / sourceSize.height
        let horizontalScale = CGFloat(targetWidth) / sourceSize.width
        let aspectRatio = horizontalScale / verticalScale
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(verticalScale, forKey: kCIInputScaleKey)
        filter.setValue(aspectRatio, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }

    private static func nearest(_ image: CIImage, targetWidth: Int, targetHeight: Int) -> CIImage {
        let sourceSize = image.extent.size
        let scaleX = CGFloat(targetWidth) / sourceSize.width
        let scaleY = CGFloat(targetHeight) / sourceSize.height
        return image.samplingNearest().transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}

// MARK: - Crop

enum CropOperation {
    static func apply(to image: CIImage, rect: NormalizedRect) -> CIImage {
        guard !rect.isFull else { return image }
        let extent = image.extent
        let cropRect = rect.rect(in: extent)
        return image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
    }
}

// MARK: - Straighten

/// Plain rotation (no inscribed-rect crop) — matches Lightroom's straighten
/// behavior where the image rotates behind an axis-aligned crop rectangle.
/// The result extent is the rotated bounding box (transparent corners).
enum StraightenOperation {
    static func apply(to image: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0 else { return image }
        let radians = degrees * .pi / 180
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        let origin = rotated.extent.origin
        return rotated.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}

// MARK: - Rotate 90°

enum Rotate90Operation {
    static func apply(to image: CIImage, count: Int) -> CIImage {
        let normalized = ((count % 4) + 4) % 4
        guard normalized != 0 else { return image }
        let radians = Double(normalized) * .pi / 2
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        let origin = rotated.extent.origin
        return rotated.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}

// MARK: - Flip

enum FlipOperation {
    static func apply(to image: CIImage, horizontal: Bool, vertical: Bool) -> CIImage {
        switch (horizontal, vertical) {
        case (false, false): return image
        case (true,  false): return image.oriented(.upMirrored)
        case (false, true):  return image.oriented(.downMirrored)
        case (true,  true):  return image.oriented(.down)
        }
    }
}
