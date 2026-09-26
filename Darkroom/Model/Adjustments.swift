import Foundation
import CoreImage

/// Non-destructive parameter stack applied as the terminal step of the render graph.
///
/// UI-normalized ranges (-1...1 bipolar, 0...1 unipolar) keep the panel semantic
/// and version-stable; mapping to filter units happens inside `apply(to:)`.
///
/// Pure value type. `apply(to:)` is a pure function of `(self, image)` — no side
/// effects, no external state — so it is trivially testable and cacheable.
struct Adjustments: Codable, Equatable {

    // MARK: - Light (Lightroom parity)

    var exposure: Double = 0     // -1 ... +1  → ×0 at -1 (black), ×4 at +1
    var contrast: Double = 0     // -1 ... +1  → tone curve S/inverse-S bend
    var highlights: Double = 0   // -1 ... +1  → curve control at 0.75 (+ recovers)
    var shadows: Double = 0      // -1 ... +1  → curve control at 0.25 (+ lifts)
    var whites: Double = 0       // -1 ... +1  → curve control at 1.0 (- recovers)
    var blacks: Double = 0       // -1 ... +1  → curve control at 0.0 (+ lifts)

    // MARK: - Effects

    var texture: Double = 0      // -1 ... +1  → CIUnsharpMask (r≈5) / CIGaussianBlur
    var clarity: Double = 0      // -1 ... +1  → CIUnsharpMask (r≈40) / CIGaussianBlur
    var dehaze: Double = 0       // -1 ... +1  → CIColorControls (contrast+saturation) + CIVibrance
    var grain: Double = 0        //  0 ... +1  → CIRandomGenerator + CIOverlayBlendMode

    // MARK: - Detail

    var sharpness: Double = 0    //  0 ... +1  → CISharpenLuminance sharpness 0 ... 2
    var noiseReduction: Double = 0 // 0 ... +1 → CINoiseReduction

    // MARK: - Identity

    static let identity = Adjustments()
    var isIdentity: Bool { self == .identity }

    // MARK: - Codable (forward-compat: missing fields default to 0)

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, grain
        case sharpness, noiseReduction
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure       = try c.decodeIfPresent(Double.self, forKey: .exposure)       ?? 0
        contrast       = try c.decodeIfPresent(Double.self, forKey: .contrast)       ?? 0
        highlights     = try c.decodeIfPresent(Double.self, forKey: .highlights)     ?? 0
        shadows        = try c.decodeIfPresent(Double.self, forKey: .shadows)        ?? 0
        whites         = try c.decodeIfPresent(Double.self, forKey: .whites)         ?? 0
        blacks         = try c.decodeIfPresent(Double.self, forKey: .blacks)         ?? 0
        texture        = try c.decodeIfPresent(Double.self, forKey: .texture)        ?? 0
        clarity        = try c.decodeIfPresent(Double.self, forKey: .clarity)        ?? 0
        dehaze         = try c.decodeIfPresent(Double.self, forKey: .dehaze)         ?? 0
        grain          = try c.decodeIfPresent(Double.self, forKey: .grain)          ?? 0
        sharpness      = try c.decodeIfPresent(Double.self, forKey: .sharpness)      ?? 0
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
    }

    // MARK: - Apply
    //
    // Pipeline order matches Lightroom's Develop module:
    //   Exposure → Tone curve → Noise reduction → Sharpen → Texture → Clarity
    //   → Dehaze → Grain
    // Noise reduction runs BEFORE sharpen so we don't amplify noise. Grain is
    // last so it's not sharpened or noise-reduced away.

    func apply(to image: CIImage) -> CIImage {
        var img = image
        let originalExtent = image.extent
        img = applyExposure(to: img)
        img = applyToneCurve(to: img)
        img = applyNoiseReduction(to: img, croppedTo: originalExtent)
        img = applySharpness(to: img, croppedTo: originalExtent)
        img = applyTexture(to: img, croppedTo: originalExtent)
        img = applyClarity(to: img, croppedTo: originalExtent)
        img = applyDehaze(to: img)
        img = applyGrain(to: img, extent: originalExtent)
        return img
    }

    // MARK: - Tone curve visualization

    /// Five control points on the tone curve, each normalized to (0...1, 0...1).
    /// Guarantees curve-in-UI == curve-in-render.
    var toneCurvePoints: [(x: Double, y: Double)] {
        let s = 0.15
        let c = 0.10
        return [
            (0.00, clamp01(0.00 + blacks * s)),
            (0.25, clamp01(0.25 + shadows * s - contrast * c)),
            (0.50, 0.50),
            (0.75, clamp01(0.75 - highlights * s + contrast * c)),
            (1.00, clamp01(1.00 - max(0, -whites) * s))
        ]
    }

    // MARK: - Private filter application

    /// Exposure with an intuitive floor: negative side is a linear multiplier
    /// so -1.0 = ×0 = true black; positive side is photographic gain (2^N stops).
    private func applyExposure(to image: CIImage) -> CIImage {
        guard exposure != 0, let filter = CIFilter(name: "CIColorMatrix") else { return image }
        let factor: CGFloat = exposure >= 0
            ? CGFloat(pow(2.0, exposure * 2.0))
            : CGFloat(1.0 + exposure)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: factor, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: factor, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: factor, w: 0), forKey: "inputBVector")
        return filter.outputImage ?? image
    }

    private func applyToneCurve(to image: CIImage) -> CIImage {
        let points = toneCurvePoints
        guard needsToneCurve, let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (index, point) in points.enumerated() {
            filter.setValue(CIVector(x: point.x, y: point.y), forKey: "inputPoint\(index)")
        }
        return filter.outputImage ?? image
    }

    private func applyNoiseReduction(to image: CIImage, croppedTo extent: CGRect) -> CIImage {
        guard noiseReduction > 0, let filter = CIFilter(name: "CINoiseReduction") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(0.02 + noiseReduction * 0.13, forKey: "inputNoiseLevel")
        filter.setValue(0.4, forKey: "inputSharpness")
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    private func applySharpness(to image: CIImage, croppedTo extent: CGRect) -> CIImage {
        guard sharpness > 0, let filter = CIFilter(name: "CISharpenLuminance") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(sharpness * 2.0, forKey: "inputSharpness")
        filter.setValue(2.5, forKey: "inputRadius")
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    /// Medium-frequency detail. Positive uses CIUnsharpMask with small radius;
    /// negative smooths medium detail via a slight gaussian blur.
    private func applyTexture(to image: CIImage, croppedTo extent: CGRect) -> CIImage {
        guard texture != 0 else { return image }
        if texture > 0 {
            guard let filter = CIFilter(name: "CIUnsharpMask") else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(5.0, forKey: kCIInputRadiusKey)
            filter.setValue(texture * 1.5, forKey: kCIInputIntensityKey)
            return (filter.outputImage ?? image).cropped(to: extent)
        }
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(-texture * 3.0, forKey: kCIInputRadiusKey)
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    /// Large-radius local contrast — the "punch" slider. Positive sharpens
    /// medium-scale features; negative softens them (dreamy look).
    private func applyClarity(to image: CIImage, croppedTo extent: CGRect) -> CIImage {
        guard clarity != 0 else { return image }
        if clarity > 0 {
            guard let filter = CIFilter(name: "CIUnsharpMask") else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(40.0, forKey: kCIInputRadiusKey)
            filter.setValue(clarity * 1.0, forKey: kCIInputIntensityKey)
            return (filter.outputImage ?? image).cropped(to: extent)
        }
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(-clarity * 8.0, forKey: kCIInputRadiusKey)
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    /// Dehaze — bumps contrast and vibrance for a "cut through the haze" feel.
    /// Negative pushes the image toward flatter, hazier tones.
    private func applyDehaze(to image: CIImage) -> CIImage {
        guard dehaze != 0 else { return image }
        var img = image
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(img, forKey: kCIInputImageKey)
            colorControls.setValue(0.0, forKey: "inputBrightness")
            colorControls.setValue(1.0 + dehaze * 0.3, forKey: "inputContrast")
            colorControls.setValue(1.0 + dehaze * 0.2, forKey: "inputSaturation")
            img = colorControls.outputImage ?? img
        }
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(img, forKey: kCIInputImageKey)
            vibrance.setValue(dehaze * 0.5, forKey: "inputAmount")
            img = vibrance.outputImage ?? img
        }
        return img
    }

    /// Grain — synthesized film grain via CIRandomGenerator overlaid onto the
    /// image. Grayscale, subtle by default; amplitude scales with the slider.
    private func applyGrain(to image: CIImage, extent: CGRect) -> CIImage {
        guard grain > 0 else { return image }
        guard let randomImage = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }

        // Desaturate so the grain is monochrome.
        guard let desat = CIFilter(name: "CIColorMatrix") else { return image }
        desat.setValue(randomImage.cropped(to: extent), forKey: kCIInputImageKey)
        desat.setValue(CIVector(x: 0.333, y: 0.333, z: 0.334, w: 0), forKey: "inputRVector")
        desat.setValue(CIVector(x: 0.333, y: 0.333, z: 0.334, w: 0), forKey: "inputGVector")
        desat.setValue(CIVector(x: 0.333, y: 0.333, z: 0.334, w: 0), forKey: "inputBVector")
        desat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        guard let gray = desat.outputImage else { return image }

        // Dial contrast on the grain so amplitude scales with the slider.
        guard let contrast = CIFilter(name: "CIColorControls") else { return image }
        contrast.setValue(gray, forKey: kCIInputImageKey)
        contrast.setValue(0.0, forKey: "inputBrightness")
        contrast.setValue(grain * 0.4, forKey: "inputContrast")
        contrast.setValue(1.0, forKey: "inputSaturation")
        guard let grainLayer = contrast.outputImage?.cropped(to: extent) else { return image }

        // Overlay it. CIOverlayBlendMode gives a filmic look — darkens shadows
        // and brightens highlights based on grain value.
        guard let blend = CIFilter(name: "CIOverlayBlendMode") else { return image }
        blend.setValue(grainLayer, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    private var needsToneCurve: Bool {
        contrast != 0 || highlights != 0 || shadows != 0 || whites != 0 || blacks != 0
    }

    private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
}
