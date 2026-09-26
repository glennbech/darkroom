import Foundation
import CoreImage

/// Applies local-adjustment masks on top of an already-processed image.
///
/// For each mask:
/// 1. Build the adjusted variant by running the mask's own Adjustments on
///    the current pipeline output.
/// 2. Generate a grayscale mask image (radial or linear gradient) at the
///    current image's extent.
/// 3. Blend the adjusted variant onto the current output using the mask as
///    an alpha selector (`CIBlendWithMask`).
///
/// Masks compose in list order — each mask sees the result of the previous
/// mask, matching Lightroom's layered masking behaviour.
enum MaskCompositor {

    /// Apply every mask to `image` in order. No-op if `masks` is empty.
    static func apply(masks: [Mask], to image: CIImage) -> CIImage {
        guard !masks.isEmpty else { return image }
        var result = image
        for mask in masks {
            result = apply(mask: mask, to: result)
        }
        return result
    }

    /// Overlay the current pipeline output with a coloured tint everywhere
    /// the mask is active — used to visualize a selected mask on the canvas.
    /// Returns `image` unchanged if `mask` is nil.
    ///
    /// Uses the SAME pipeline as `apply()` and `debugMaskImage()`: raw generate
    /// → soften → scale by amount. If these ever diverge, the tint the user
    /// sees stops being an honest preview of the actual mask effect.
    static func overlay(mask: Mask?, on image: CIImage, tint: CIColor) -> CIImage {
        guard let mask else { return image }
        let extent = image.extent
        let raw = generate(kind: mask.kind, extent: extent, inverted: mask.isInverted)
        let soft = soften(raw, extent: extent)
        let scaled = scale(soft, by: mask.amount, extent: extent)
        let tintLayer = CIImage(color: tint).cropped(to: extent)
        return blend(background: image, foreground: tintLayer, mask: scaled)
    }

    // MARK: - Private

    private static func apply(mask: Mask, to image: CIImage) -> CIImage {
        // amount == 0 → nothing to do.
        guard mask.amount > 0.001 else { return image }
        let adjusted = mask.adjustments.apply(to: image)
        let rawMask = generate(kind: mask.kind, extent: image.extent, inverted: mask.isInverted)
        let softMask = soften(rawMask, extent: image.extent)
        let scaledMask = scale(softMask, by: mask.amount, extent: image.extent)
        return blend(background: image, foreground: adjusted, mask: scaledMask)
    }

    /// Widen the perceptual falloff of a mask with a gaussian blur.
    /// Radius scales with image size so masks feel equally soft across
    /// preview vs full-resolution renders. 8% of the shortest dim gives a
    /// wide, atmospheric falloff — like Lightroom's default feather.
    private static func soften(_ mask: CIImage, extent: CGRect) -> CIImage {
        let radius = min(extent.width, extent.height) * 0.08
        guard radius > 0.5, let filter = CIFilter(name: "CIGaussianBlur") else { return mask }
        filter.setValue(mask, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return (filter.outputImage ?? mask).cropped(to: extent)
    }

    /// Multiply a grayscale mask by `amount` — 0 → fully black (no effect),
    /// 1 → unchanged. Implemented via CIColorMatrix scaling of RGB channels
    /// (CIBlendWithMask samples luminance, so scaling RGB is equivalent).
    private static func scale(_ maskImage: CIImage, by amount: Double, extent: CGRect) -> CIImage {
        guard amount < 1.0 else { return maskImage }
        guard let filter = CIFilter(name: "CIColorMatrix") else { return maskImage }
        let a = CGFloat(max(0, min(1, amount)))
        filter.setValue(maskImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: a, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: a, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: a, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return (filter.outputImage ?? maskImage).cropped(to: extent)
    }

    private static func generate(kind: MaskKind, extent: CGRect, inverted: Bool) -> CIImage {
        switch kind {
        case .radial(let cx, let cy, let r0, let r1):
            return radial(centerX: cx, centerY: cy,
                          radiusInner: r0, radiusOuter: r1,
                          extent: extent, inverted: inverted)
        case .linear(let sx, let sy, let ex, let ey):
            return linear(startX: sx, startY: sy, endX: ex, endY: ey,
                          extent: extent, inverted: inverted)
        }
    }

    /// Custom radial mask kernel — guarantees LINEAR interpolation from
    /// `radiusInner` (mask=1) to `radiusOuter` (mask=0). CIRadialGradient uses
    /// Hermite (smoothstep) interpolation, which visibly flattens near both
    /// ends of the transition band and makes the mask look like it ends well
    /// inside the outer ring. Linear gives a truthful, ring-to-ring falloff.
    private static let linearRadialKernel: CIColorKernel = {
        let source = """
        kernel vec4 linearRadial(float cx, float cy, float r0, float r1, float invert) {
            vec2 p = destCoord();
            float d = distance(p, vec2(cx, cy));
            float span = max(0.0001, r1 - r0);
            float t = clamp((d - r0) / span, 0.0, 1.0);
            float m = 1.0 - t;
            if (invert > 0.5) { m = t; }
            return vec4(m, m, m, 1.0);
        }
        """
        guard let kernel = CIColorKernel(source: source) else {
            fatalError("linearRadial kernel failed to compile — check CIKL syntax")
        }
        return kernel
    }()

    private static func radial(centerX: Double, centerY: Double,
                               radiusInner: Double, radiusOuter: Double,
                               extent: CGRect, inverted: Bool) -> CIImage {
        let shortestDim = min(extent.width, extent.height)
        let r0CG: CGFloat = max(1, CGFloat(radiusInner) * shortestDim)
        let r1CG: CGFloat = max(r0CG + 1, CGFloat(radiusOuter) * shortestDim)
        let cx = Float(extent.origin.x + CGFloat(centerX) * extent.width)
        let cy = Float(extent.origin.y + CGFloat(centerY) * extent.height)
        let r0 = Float(r0CG)
        let r1 = Float(r1CG)
        let inv: Float = inverted ? 1.0 : 0.0

        let output = linearRadialKernel.apply(extent: extent, arguments: [cx, cy, r0, r1, inv])
            ?? CIImage(color: .white).cropped(to: extent)
        return output.cropped(to: extent)
    }

    private static func linear(startX: Double, startY: Double,
                               endX: Double, endY: Double,
                               extent: CGRect, inverted: Bool) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: .white).cropped(to: extent)
        }
        let start = CIVector(x: extent.origin.x + CGFloat(startX) * extent.width,
                             y: extent.origin.y + CGFloat(startY) * extent.height)
        let end   = CIVector(x: extent.origin.x + CGFloat(endX)   * extent.width,
                             y: extent.origin.y + CGFloat(endY)   * extent.height)
        filter.setValue(start, forKey: "inputPoint0")
        filter.setValue(end,   forKey: "inputPoint1")
        // Convention: mask is 100% at `start` (and beyond, extending infinitely
        // away from `end`), falls linearly to 0% at `end` (and beyond). Invert flips.
        filter.setValue(inverted ? CIColor.black : CIColor.white, forKey: "inputColor0")
        filter.setValue(inverted ? CIColor.white : CIColor.black, forKey: "inputColor1")
        let output = filter.outputImage ?? CIImage(color: .white).cropped(to: extent)
        return output.cropped(to: extent)
    }

    private static func blend(background: CIImage, foreground: CIImage, mask: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return background }
        filter.setValue(foreground,  forKey: kCIInputImageKey)
        filter.setValue(background,  forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask,        forKey: kCIInputMaskImageKey)
        return filter.outputImage ?? background
    }
}
