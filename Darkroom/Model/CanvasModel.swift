import Foundation
import CoreImage
import CoreGraphics

/// Live document model — immutable source pixels + mutable edit state.
///
/// This split is load-bearing:
/// - `source` is set once at open time and never mutated (non-destructive).
/// - `state` (operations + adjustments) is what the user changes; it's a
///   small value type that HistoryManager snapshots for undo/redo.
///
/// Two-tier rendering (as CLAUDE.md requires for 500GB-scale images):
/// - `evaluate()`         → full-resolution pipeline (used only at export).
/// - `evaluatePreview()`  → runs the same pipeline against a cached, size-capped
///                          proxy of the source. Massively cheaper for the
///                          on-screen canvas; visually equivalent at fit-zoom.
///
/// Both paths cache their last output CIImage. As long as `state` is unchanged
/// (e.g. during a pan gesture), the cached CIImage is returned so Core Image's
/// internal graph cache stays warm — no redundant kernel execution per frame.
final class CanvasModel {

    // MARK: - Constants

    /// Longest-edge cap for the preview source. Chosen so that panning and
    /// slider drags stay 120 Hz on modern hardware even for 100+ MP sources.
    /// Trades: preview sharpness kernel behaves slightly differently than
    /// full-res; export re-renders at true size so that's a preview-only
    /// artifact.
    private static let previewMaxDimension: Int = 4096

    // MARK: - Immutable inputs

    let source: CIImage
    let sourceWidth: Int
    let sourceHeight: Int
    let colorSpace: CGColorSpace
    let sourceUTI: String
    /// Image resolution in dots per inch. Used by the on-canvas rulers to
    /// display real-world centimetres. Defaults to 72 (screen resolution).
    let dpi: Double

    /// Size-capped source used for on-screen rendering. Same content, fewer
    /// pixels — built lazily by Core Image the first time it renders.
    private let previewSource: CIImage

    // MARK: - Mutable state

    var state: EditorState = .empty {
        didSet { invalidateCaches() }
    }

    /// Uncommitted operation currently being previewed (e.g. a live straighten
    /// slider mid-drag). Applied AFTER `state.operations` but BEFORE
    /// `state.adjustments`. Never persisted to history — the caller commits
    /// it into `state` via the document's commit helpers on drag-end.
    var pendingOperation: Operation? {
        didSet { invalidateCaches() }
    }

    /// When true, the render pipeline skips any committed `.crop` operation.
    /// Used by the Crop panel so the user can see the full image while
    /// dragging a new crop draft; committing the draft flips this back off.
    var cropSuppressed: Bool = false {
        didSet { invalidateCaches() }
    }

    /// UUID of a mask whose region should be tinted red on the preview render
    /// to show the user which pixels it affects. Preview-only — export ignores it.
    var highlightedMaskID: UUID? {
        didSet { cachedPreviewEvaluation = nil }
    }

    /// When true, the red mask-tint overlay is suppressed even if a mask is
    /// highlighted. Used by the slider drag path: while the user is actively
    /// adjusting a mask's parameters, show the real effect, not the tint.
    var maskOverlayHidden: Bool = false {
        didSet { cachedPreviewEvaluation = nil }
    }

    private var cachedFullEvaluation: CIImage?
    private var cachedPreviewEvaluation: CIImage?

    /// Flattened snapshot of the preview render taken at the start of a live
    /// interaction. While set, `evaluatePreview()` applies only the pending
    /// operation to this baked image — the rest of the pipeline is frozen.
    /// Turns straighten drags from "re-run full CI pipeline per frame" into
    /// "one affine sample on a texture per frame."
    private var interactionSnapshot: CIImage?

    // MARK: - Init

    init(source: CIImage,
         width: Int,
         height: Int,
         colorSpace: CGColorSpace,
         sourceUTI: String,
         dpi: Double = 72) {
        self.source = source
        self.sourceWidth = width
        self.sourceHeight = height
        self.colorSpace = colorSpace
        self.sourceUTI = sourceUTI
        self.dpi = dpi
        // Bake the preview to a flat GPU-friendly CIImage so every pan/zoom
        // frame is a single sampler read instead of re-executing the HEIC
        // decode + Lanczos resize chain. One-time ~30ms cost at doc open;
        // every frame afterwards is dramatically cheaper.
        let recipe = Self.makePreviewSource(source: source, width: width, height: height)
        self.previewSource = Self.bakeToFlat(recipe, colorSpace: colorSpace)
    }

    /// Placeholder used while no document is open.
    static func empty() -> CanvasModel {
        let img = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CanvasModel(source: img, width: 1, height: 1, colorSpace: space, sourceUTI: "public.png")
    }

    // MARK: - Derived dimensions

    var width: Int  { effectiveSize.width }
    var height: Int { effectiveSize.height }

    var effectiveSize: (width: Int, height: Int) {
        var size = state.effectiveSize(sourceWidth: sourceWidth,
                                       sourceHeight: sourceHeight,
                                       skipCrop: cropSuppressed)
        if let pending = pendingOperation { size = pending.transformSize(size) }
        return size
    }

    // MARK: - Rendering

    /// Full-resolution pipeline. Used at export.
    func evaluate() -> CIImage {
        if let cached = cachedFullEvaluation { return cached }
        let result = compose(source: source)
        cachedFullEvaluation = result
        return result
    }

    /// Preview pipeline. Runs the same operations + adjustments against a
    /// size-capped proxy of the source. Used by the on-screen canvas.
    ///
    /// When an interaction snapshot is active, only the pending operation is
    /// applied to that flat snapshot — the committed pipeline is frozen for
    /// the duration of the gesture.
    func evaluatePreview() -> CIImage {
        if let cached = cachedPreviewEvaluation { return cached }
        let base: CIImage
        if let snapshot = interactionSnapshot {
            base = pendingOperation?.apply(to: snapshot) ?? snapshot
        } else {
            base = compose(source: previewSource)
        }
        let result = overlayHighlightedMask(on: base)
        cachedPreviewEvaluation = result
        return result
    }

    private func overlayHighlightedMask(on image: CIImage) -> CIImage {
        guard !maskOverlayHidden,
              let id = highlightedMaskID,
              let mask = state.masks.first(where: { $0.id == id }) else { return image }
        return MaskCompositor.overlay(mask: mask,
                                      on: image,
                                      tint: CIColor(red: 1, green: 0.15, blue: 0.15, alpha: 0.45))
    }

    // MARK: - Interaction snapshot

    /// Freeze the current preview pipeline output into a flat CIImage. During
    /// the interaction, `evaluatePreview()` will apply only `pendingOperation`
    /// to this frozen base — orders of magnitude cheaper than re-executing
    /// the graph. Call `endInteraction()` on drag-end.
    func beginInteraction() {
        interactionSnapshot = bakePreview()
        invalidateCaches()
    }

    /// Release the interaction snapshot. Preview goes back to the full
    /// pipeline against `previewSource`.
    func endInteraction() {
        interactionSnapshot = nil
        invalidateCaches()
    }

    /// Render `previewSource` through the current committed state (respecting
    /// `cropSuppressed`) and return a CIImage backed by a rasterized CGImage —
    /// i.e. a flat texture, no filter graph.
    private func bakePreview() -> CIImage {
        var img = previewSource
        for op in state.operations {
            if cropSuppressed, case .crop = op { continue }
            img = op.apply(to: img)
        }
        img = state.adjustments.apply(to: img)
        let context = SharedRenderer.shared.context
        guard let cgImage = context.createCGImage(img,
                                                  from: img.extent,
                                                  format: .RGBA8,
                                                  colorSpace: colorSpace) else {
            return img
        }
        return CIImage(cgImage: cgImage)
    }

    /// Compose the full render for a given source: committed operations,
    /// pending operation (live preview), then global adjustments, then masks.
    /// Skips any committed `.crop` when `cropSuppressed` is true (see field).
    private func compose(source: CIImage) -> CIImage {
        var img = source
        for op in state.operations {
            if cropSuppressed, case .crop = op { continue }
            img = op.apply(to: img)
        }
        if let pending = pendingOperation { img = pending.apply(to: img) }
        img = state.adjustments.apply(to: img)
        img = MaskCompositor.apply(masks: state.masks, to: img)
        return img
    }

    /// Longest edge of the preview source in source-image pixels. Useful for
    /// deciding whether preview quality is adequate at a given zoom level.
    var previewSourceLongestEdge: Int {
        Int(max(previewSource.extent.width, previewSource.extent.height))
    }

    // MARK: - Private

    private func invalidateCaches() {
        cachedFullEvaluation = nil
        cachedPreviewEvaluation = nil
    }

    /// True while an interaction snapshot is active. Used by tests and by
    /// callers that need to know whether the preview path is frozen.
    var isInteracting: Bool { interactionSnapshot != nil }

    private static func makePreviewSource(source: CIImage, width: Int, height: Int) -> CIImage {
        let longest = max(width, height)
        guard longest > previewMaxDimension else { return source }
        let scale = Double(previewMaxDimension) / Double(longest)
        let targetWidth = Int((Double(width) * scale).rounded())
        let targetHeight = Int((Double(height) * scale).rounded())
        return ResizeOperation.apply(to: source,
                                     width: targetWidth,
                                     height: targetHeight,
                                     method: .lanczos)
    }

    /// Rasterize a CIImage recipe to a flat CGImage-backed CIImage so every
    /// subsequent render is a single sampler read. This is what turns
    /// pipeline-per-frame into texture-blit-per-frame during pan/zoom.
    private static func bakeToFlat(_ image: CIImage, colorSpace: CGColorSpace) -> CIImage {
        let context = SharedRenderer.shared.context
        guard let cg = context.createCGImage(image,
                                              from: image.extent,
                                              format: .RGBA8,
                                              colorSpace: colorSpace) else {
            return image
        }
        return CIImage(cgImage: cg)
    }
}
