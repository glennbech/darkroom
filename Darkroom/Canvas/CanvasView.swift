import SwiftUI
import AppKit
import MetalKit
import CoreImage
import os.signpost

/// SwiftUI wrapper for the Metal-backed canvas.
struct CanvasView: NSViewRepresentable {
    let document: StarDocument
    @Binding var zoom: CGFloat
    @Binding var viewOffset: CGSize
    @Binding var cursorInImage: CGPoint?
    let activePanel: DockPanel?

    func makeNSView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: SharedRenderer.shared.device)
        view.document = document
        view.zoomBinding = $zoom
        view.offsetBinding = $viewOffset
        view.cursorBinding = $cursorInImage
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.installObservers()
        return view
    }

    func updateNSView(_ nsView: CanvasMTKView, context: Context) {
        // Redraws are driven by canvasDidChange / view state didSets, not by
        // SwiftUI re-bodies. Calling setNeedsDisplay here would cause a full
        // Metal redraw on every cursor tick — silky-smooth killer.
        let documentChanged = nsView.document !== document
        nsView.document = document
        nsView.setCropMode(activePanel == .crop)
        if documentChanged { nsView.setNeedsDisplay(nsView.bounds) }
    }
}

// MARK: - Crop interaction types

/// The active drag interaction on the crop draft (nil = no drag).
enum CropInteraction {
    case resize(handle: CropHandle, startMouse: NSPoint, startRect: NormalizedRect)
    case translate(startMouse: NSPoint, startRect: NormalizedRect)
    case newRect(origin: NSPoint)
}

// MARK: - Mask interaction types

enum MaskDragInteraction {
    case handle(MaskHandle, startMouse: NSPoint, startKind: MaskKind)
}

// MARK: - CanvasMTKView

final class CanvasMTKView: MTKView {

    // MARK: - Injected

    weak var document: StarDocument?
    var zoomBinding: Binding<CGFloat>?
    var offsetBinding: Binding<CGSize>?
    var cursorBinding: Binding<CGPoint?>?

    // MARK: - View state (point space)

    var viewZoom: CGFloat = 1.0 {
        // Overlay is updated inside draw() so its layer commit rides the same
        // runloop tick as the Metal present — keeps them exactly in sync.
        didSet { syncZoom(); needsDisplay = true }
    }
    var viewOffset: CGSize = .zero {
        didSet { syncOffset(); needsDisplay = true }
    }

    // MARK: - Interaction

    private var lastPanPoint: NSPoint?
    private var spaceHeld: Bool = false
    private var didFit: Bool = false
    private var lastKnownSourceSize: CGSize = .zero

    // MARK: - Crop mode

    private var cropMode: Bool = false
    private var cropDraft: NormalizedRect?
    private var cropInteraction: CropInteraction?
    private var aspectRatioLock: Double?
    private var cropDimLayer: CAShapeLayer?
    private var cropBorderLayer: CAShapeLayer?
    private var cropGridLayer: CAShapeLayer?
    private var cropHandlesLayer: CAShapeLayer?

    // MARK: - Mask editing

    private var maskShapeLayer: CAShapeLayer?
    private var maskHandlesLayer: CAShapeLayer?
    private var maskInteraction: MaskDragInteraction?
    private static let maskHandleHitRadius: CGFloat = 16
    private static let maskHandleVisualSize: CGFloat = 10
    /// Perpendicular distance (view points) within which a click on empty
    /// space near a linear mask's line grabs the whole gradient to translate.
    private static let maskLineGrabDistance: CGFloat = 14

    // MARK: - Overrides

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        if !didFit, document != nil { fitToView() }
        updateCropOverlay()
    }

    // MARK: - Notifications

    func installObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleZoomIn),          name: .zoomIn,             object: nil)
        nc.addObserver(self, selector: #selector(handleZoomOut),         name: .zoomOut,            object: nil)
        nc.addObserver(self, selector: #selector(handleZoomActual),      name: .zoomActual,         object: nil)
        nc.addObserver(self, selector: #selector(handleZoomFit),         name: .zoomFit,            object: nil)
        nc.addObserver(self, selector: #selector(handleCanvasChange),    name: .canvasDidChange,    object: nil)
        nc.addObserver(self, selector: #selector(handleCommitCrop),      name: .commitCropDraft,    object: nil)
        nc.addObserver(self, selector: #selector(handleCancelCrop),      name: .cancelCropDraft,    object: nil)
        nc.addObserver(self, selector: #selector(handleResetCropToFull), name: .resetCropDraftToFull, object: nil)
        nc.addObserver(self, selector: #selector(handleSetAspect(_:)),   name: .setCropDraftAspect, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func handleZoomIn()     { zoom(by: 1.25, around: nil) }
    @objc private func handleZoomOut()    { zoom(by: 1/1.25, around: nil) }
    @objc private func handleZoomActual() { viewZoom = 1; viewOffset = .zero }
    @objc private func handleZoomFit()    { fitToView() }

    @objc private func handleCanvasChange() {
        guard let doc = document else { needsDisplay = true; return }
        // Live gestures (straighten slider) constantly shift the effective
        // bounding box. Refitting on every tick makes the view jump. Skip the
        // refit while a pending op is being previewed — one refit happens on
        // drag-end when the op is committed and pending is cleared.
        if doc.canvas.pendingOperation != nil {
            needsDisplay = true
            return
        }
        let size = CGSize(width: doc.canvas.width, height: doc.canvas.height)
        if size != lastKnownSourceSize && size.width > 1 {
            didFit = false
            lastKnownSourceSize = size
            DispatchQueue.main.async { [weak self] in
                self?.fitToView()
                self?.needsDisplay = true
            }
        } else {
            needsDisplay = true
        }
    }

    @objc private func handleCommitCrop()      { commitCropDraft() }
    @objc private func handleCancelCrop()      { cancelCropDraft() }
    @objc private func handleResetCropToFull() {
        aspectRatioLock = nil
        cropDraft = .full
        updateCropOverlay()
    }
    @objc private func handleSetAspect(_ note: Notification) {
        guard let doc = document else { return }
        if let ratio = note.userInfo?["ratio"] as? Double, ratio > 0 {
            aspectRatioLock = ratio
            cropDraft = NormalizedRect.centeredRect(matching: ratio,
                                                    in: CGSize(width: doc.canvas.width,
                                                               height: doc.canvas.height))
        } else {
            aspectRatioLock = nil
        }
        updateCropOverlay()
    }

    // MARK: - Zoom / fit

    private func syncZoom() { zoomBinding?.wrappedValue = viewZoom }
    private func syncOffset() {
        if offsetBinding?.wrappedValue != viewOffset {
            offsetBinding?.wrappedValue = viewOffset
        }
    }

    private func fitToView() {
        guard let doc = document, doc.canvas.width > 0, doc.canvas.height > 0,
              bounds.width > 1, bounds.height > 1 else { return }
        let iw = CGFloat(doc.canvas.width)
        let ih = CGFloat(doc.canvas.height)
        viewOffset = .zero
        viewZoom = max(min(bounds.width / iw, bounds.height / ih) * 0.95, 0.05)
        didFit = true
        lastKnownSourceSize = CGSize(width: iw, height: ih)
    }

    private func zoom(by factor: CGFloat, around anchor: NSPoint?) {
        let newZoom = max(0.02, min(64, viewZoom * factor))
        guard let anchor, let doc = document else { viewZoom = newZoom; return }
        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        guard iw > 0, ih > 0 else { viewZoom = newZoom; return }

        let originBefore = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)
        let ax = (anchor.x - originBefore.x) / viewZoom
        let ay = (anchor.y - originBefore.y) / viewZoom

        let centerAfterX = (bounds.width  - iw * newZoom) / 2
        let centerAfterY = (bounds.height - ih * newZoom) / 2
        viewOffset = CGSize(
            width:  (anchor.x - ax * newZoom) - centerAfterX,
            height: (anchor.y - ay * newZoom) - centerAfterY
        )
        viewZoom = newZoom
    }

    private func imageOrigin(iw: CGFloat, ih: CGFloat, zoom: CGFloat, offset: CGSize) -> NSPoint {
        NSPoint(
            x: (bounds.width  - iw * zoom) / 2 + offset.width,
            y: (bounds.height - ih * zoom) / 2 + offset.height
        )
    }

    // MARK: - Trackpad / scroll

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + (event.scrollingDeltaY * 0.01),
                 around: convert(event.locationInWindow, from: nil))
        } else {
            viewOffset.width  += event.scrollingDeltaX
            viewOffset.height -= event.scrollingDeltaY
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        if abs(viewZoom - 1.0) < 0.01 { fitToView() }
        else { zoom(by: 1.0 / viewZoom, around: anchor) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Enter / Return commits the crop draft; Escape cancels.
        if cropMode {
            switch event.keyCode {
            case 36, 76: commitCropDraft();  return   // Return, keypad Enter
            case 53:     cancelCropDraft();  return   // Escape
            default: break
            }
        }
        // Enter / Return applies the current mask — deselects it so the tint
        // clears and the panel returns to the list. Escape does the same
        // (there's nothing "unapplied" to revert since edits committed live).
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
            if deselectHighlightedMaskIfAny() { return }
        }
        // Delete / Backspace removes the currently highlighted mask.
        if event.keyCode == 51 || event.keyCode == 117 {
            if deleteHighlightedMaskIfAny() { return }
        }
        if event.charactersIgnoringModifiers == " " {
            spaceHeld = true
            NSCursor.openHand.push()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Clear the mask highlight — panel stays open, list returns to view.
    /// Returns true iff there was something to deselect.
    private func deselectHighlightedMaskIfAny() -> Bool {
        guard let doc = document, doc.canvas.highlightedMaskID != nil else { return false }
        doc.canvas.highlightedMaskID = nil
        NotificationCenter.default.post(name: .canvasDidChange, object: doc)
        return true
    }

    /// Delete whichever mask is currently highlighted. Returns true if a mask
    /// was removed. The Masks panel observes canvasDidChange and clears its
    /// own selection state on the next tick.
    private func deleteHighlightedMaskIfAny() -> Bool {
        guard let doc = document, let id = doc.canvas.highlightedMaskID else { return false }
        doc.removeMask(id: id)
        doc.canvas.highlightedMaskID = nil
        NotificationCenter.default.post(name: .canvasDidChange, object: doc)
        return true
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            spaceHeld = false
            NSCursor.pop()
        } else { super.keyUp(with: event) }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if cropMode && !spaceHeld {
            beginCropInteraction(at: point)
            return
        }
        if !spaceHeld, let mask = activeMask(),
           beginMaskInteraction(at: point, for: mask) {
            return
        }
        lastPanPoint = point
        if spaceHeld { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let interaction = cropInteraction {
            applyCropInteraction(interaction, current: point)
        } else if let interaction = maskInteraction {
            applyMaskInteraction(interaction, current: point)
        } else if let last = lastPanPoint {
            viewOffset.width  += (point.x - last.x)
            viewOffset.height += (point.y - last.y)
            lastPanPoint = point
        }
        updateCursor(with: event)
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(with: event) }

    override func mouseUp(with event: NSEvent) {
        if maskInteraction != nil { endMaskInteraction() }
        cropInteraction = nil
        if spaceHeld { NSCursor.pop() }
        lastPanPoint = nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: cropMode ? .crosshair : .openHand)
    }

    private func updateCursor(with event: NSEvent) {
        guard let doc = document else { return }
        let p = convert(event.locationInWindow, from: nil)
        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        let origin = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)
        let lx = (p.x - origin.x) / viewZoom
        let ly = (p.y - origin.y) / viewZoom
        let newValue: CGPoint? = (lx >= 0 && lx < iw && ly >= 0 && ly < ih)
            ? CGPoint(x: floor(lx), y: floor(ih - ly))
            : nil
        if cursorBinding?.wrappedValue != newValue {
            cursorBinding?.wrappedValue = newValue
        }
    }

    // MARK: - Crop mode: state transitions

    func setCropMode(_ enabled: Bool) {
        guard cropMode != enabled else { return }
        if enabled {
            enterCropMode()
        } else {
            exitCropMode(autoCommit: true)
        }
    }

    private func enterCropMode() {
        cropMode = true
        cropDraft = existingCropRect() ?? .full
        document?.canvas.cropSuppressed = true
        NotificationCenter.default.post(name: .canvasDidChange, object: document)
        ensureCropOverlayLayers()
        updateCropOverlay()
        window?.invalidateCursorRects(for: self)
    }

    private func exitCropMode(autoCommit: Bool) {
        cropMode = false
        cropInteraction = nil
        if autoCommit { commitDraftToStateIfChanged() }
        cropDraft = nil
        document?.canvas.cropSuppressed = false
        NotificationCenter.default.post(name: .canvasDidChange, object: document)
        updateCropOverlay()
        window?.invalidateCursorRects(for: self)
    }

    /// Commit the current draft to history (called by Enter key / Apply button).
    /// Closes the crop panel afterwards so the pipeline actually reveals the
    /// newly-cropped result — matches Lightroom (Apply exits the tool).
    private func commitCropDraft() {
        commitDraftToStateIfChanged()
        NotificationCenter.default.post(
            name: .togglePanel,
            object: document,
            userInfo: ["panel": DockPanel.crop.rawValue]
        )
    }

    /// Discard changes to the draft; revert to the committed value and close
    /// the crop panel — symmetric with Apply. Escape and the Discard button
    /// both call this via .cancelCropDraft.
    private func cancelCropDraft() {
        cropDraft = existingCropRect() ?? .full
        NotificationCenter.default.post(
            name: .togglePanel,
            object: document,
            userInfo: ["panel": DockPanel.crop.rawValue]
        )
    }

    private func commitDraftToStateIfChanged() {
        guard let draft = cropDraft else { return }
        let existing = existingCropRect()
        // Full-rect = no crop; if state has a crop op we replace with full,
        // which upserting collapses to "remove the op".
        if draft.isFull {
            if existing != nil {
                var newState = document?.canvas.state ?? .empty
                newState.operations.removeAll { if case .crop = $0 { return true } else { return false } }
                if let doc = document, newState != doc.canvas.state {
                    doc.history.commit(newState: newState, name: "Reset Crop")
                }
            }
            return
        }
        if draft == existing { return }
        document?.commitOperation(.crop(draft), actionName: "Crop")
    }

    private func existingCropRect() -> NormalizedRect? {
        guard let doc = document else { return nil }
        for op in doc.canvas.state.operations {
            if case .crop(let rect) = op { return rect }
        }
        return nil
    }

    // MARK: - Crop mode: interaction

    private func beginCropInteraction(at point: NSPoint) {
        guard let draft = cropDraft else { return }
        let handle = hitTestCrop(at: point)
        switch handle {
        case .outside:
            cropInteraction = .newRect(origin: point)
            cropDraft = normalizedRect(from: CGRect(origin: point, size: .zero))
        case .interior:
            cropInteraction = .translate(startMouse: point, startRect: draft)
        default:
            cropInteraction = .resize(handle: handle, startMouse: point, startRect: draft)
        }
        updateCropOverlay()
    }

    private func applyCropInteraction(_ interaction: CropInteraction, current point: NSPoint) {
        switch interaction {
        case .newRect(let origin):
            cropDraft = normalizedRect(from: rect(from: origin, to: point))
        case .translate(let startMouse, let startRect):
            cropDraft = translated(startRect,
                                   byViewDelta: NSPoint(x: point.x - startMouse.x,
                                                        y: point.y - startMouse.y))
        case .resize(let handle, let startMouse, let startRect):
            let unconstrained = resized(startRect,
                                        handle: handle,
                                        byViewDelta: NSPoint(x: point.x - startMouse.x,
                                                             y: point.y - startMouse.y))
            if let ratio = aspectRatioLock {
                cropDraft = unconstrained.constrained(toRatio: ratio,
                                                      handle: handle,
                                                      original: startRect)
            } else {
                cropDraft = unconstrained
            }
        }
        updateCropOverlay()
    }

    // MARK: - Crop math (view ↔ normalized)

    private func imageDrawnSize() -> CGSize? {
        guard let doc = document, doc.canvas.width > 0, doc.canvas.height > 0 else { return nil }
        return CGSize(width: CGFloat(doc.canvas.width) * viewZoom,
                      height: CGFloat(doc.canvas.height) * viewZoom)
    }

    private func cropRectInView() -> CGRect? {
        guard let doc = document, let draft = cropDraft else { return nil }
        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        let origin = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)
        return CGRect(
            x: origin.x + CGFloat(draft.x) * iw * viewZoom,
            y: origin.y + CGFloat(draft.y) * ih * viewZoom,
            width:  CGFloat(draft.width)  * iw * viewZoom,
            height: CGFloat(draft.height) * ih * viewZoom
        )
    }

    private func rect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func normalizedRect(from viewRect: CGRect) -> NormalizedRect {
        guard let doc = document,
              let drawn = imageDrawnSize(),
              drawn.width > 0, drawn.height > 0 else { return .full }
        let origin = imageOrigin(iw: CGFloat(doc.canvas.width),
                                 ih: CGFloat(doc.canvas.height),
                                 zoom: viewZoom, offset: viewOffset)
        let x1 = clamp01(Double((viewRect.minX - origin.x) / drawn.width))
        let y1 = clamp01(Double((viewRect.minY - origin.y) / drawn.height))
        let x2 = clamp01(Double((viewRect.maxX - origin.x) / drawn.width))
        let y2 = clamp01(Double((viewRect.maxY - origin.y) / drawn.height))
        return NormalizedRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    private func translated(_ rect: NormalizedRect, byViewDelta delta: NSPoint) -> NormalizedRect {
        guard let drawn = imageDrawnSize(), drawn.width > 0, drawn.height > 0 else { return rect }
        let dxNorm = Double(delta.x / drawn.width)
        let dyNorm = Double(delta.y / drawn.height)
        var newX = rect.x + dxNorm
        var newY = rect.y + dyNorm
        newX = max(0, min(1 - rect.width,  newX))
        newY = max(0, min(1 - rect.height, newY))
        return NormalizedRect(x: newX, y: newY, width: rect.width, height: rect.height)
    }

    private func resized(_ rect: NormalizedRect, handle: CropHandle, byViewDelta delta: NSPoint) -> NormalizedRect {
        guard let drawn = imageDrawnSize(), drawn.width > 0, drawn.height > 0 else { return rect }
        let dx = Double(delta.x / drawn.width)
        let dy = Double(delta.y / drawn.height)
        let minSize = 0.02

        var x = rect.x, y = rect.y, w = rect.width, h = rect.height
        let right = rect.x + rect.width
        let top   = rect.y + rect.height

        if [.left, .topLeft, .bottomLeft].contains(handle) {
            x = clamp01(min(right - minSize, rect.x + dx))
            w = right - x
        }
        if [.right, .topRight, .bottomRight].contains(handle) {
            let newRight = clamp01(max(rect.x + minSize, right + dx))
            w = newRight - x
        }
        if [.bottom, .bottomLeft, .bottomRight].contains(handle) {
            y = clamp01(min(top - minSize, rect.y + dy))
            h = top - y
        }
        if [.top, .topLeft, .topRight].contains(handle) {
            let newTop = clamp01(max(rect.y + minSize, top + dy))
            h = newTop - y
        }
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func hitTestCrop(at point: NSPoint) -> CropHandle {
        guard let rect = cropRectInView() else { return .outside }
        let r: CGFloat = 14  // hit radius in points
        let nearL = abs(point.x - rect.minX) < r
        let nearR = abs(point.x - rect.maxX) < r
        let nearB = abs(point.y - rect.minY) < r
        let nearT = abs(point.y - rect.maxY) < r
        let alongH = point.x >= rect.minX - r && point.x <= rect.maxX + r
        let alongV = point.y >= rect.minY - r && point.y <= rect.maxY + r

        if nearL && nearT { return .topLeft }
        if nearR && nearT { return .topRight }
        if nearL && nearB { return .bottomLeft }
        if nearR && nearB { return .bottomRight }
        if nearL && alongV { return .left }
        if nearR && alongV { return .right }
        if nearT && alongH { return .top }
        if nearB && alongH { return .bottom }
        if rect.contains(point) { return .interior }
        return .outside
    }

    private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    // MARK: - Crop overlay layers

    private func ensureCropOverlayLayers() {
        guard cropDimLayer == nil else { return }
        wantsLayer = true

        let dim = makeOverlayLayer()
        dim.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        dim.fillRule = .evenOdd
        cropDimLayer = dim

        let border = makeOverlayLayer()
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        border.lineWidth = 1.0
        cropBorderLayer = border

        // Rule-of-thirds grid at 40% opacity — subtler than the border so the
        // eye stays on the image content, not the guides.
        let grid = makeOverlayLayer()
        grid.fillColor = nil
        grid.strokeColor = NSColor.white.withAlphaComponent(0.40).cgColor
        grid.lineWidth = 0.5
        cropGridLayer = grid

        let handles = makeOverlayLayer()
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.black.withAlphaComponent(0.4).cgColor
        handles.lineWidth = 0.5
        cropHandlesLayer = handles
    }

    /// Build a CAShapeLayer with all implicit animations disabled. The
    /// `actions` dictionary maps each animatable key to `NSNull` — property
    /// changes become instantaneous, joining whatever CATransaction is active
    /// (the runloop tick's implicit one, aligned with the display link).
    private func makeOverlayLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.isHidden = true
        layer.actions = [
            "path":        NSNull(),
            "position":    NSNull(),
            "bounds":      NSNull(),
            "frame":       NSNull(),
            "fillColor":   NSNull(),
            "strokeColor": NSNull(),
            "hidden":      NSNull(),
        ]
        self.layer?.addSublayer(layer)
        return layer
    }

    private func updateCropOverlay() {
        guard let dim = cropDimLayer,
              let border = cropBorderLayer,
              let grid = cropGridLayer,
              let handles = cropHandlesLayer else { return }

        // No explicit CATransaction here — layer changes join the current
        // runloop tick (or the enclosing tick when called from draw()).
        // Implicit animations are already suppressed via each layer's
        // `actions` dictionary.

        dim.frame = bounds
        border.frame = bounds
        grid.frame = bounds
        handles.frame = bounds

        guard cropMode, let cropRect = cropRectInView() else {
            dim.isHidden = true
            border.isHidden = true
            grid.isHidden = true
            handles.isHidden = true
            return
        }
        dim.isHidden = false
        border.isHidden = false
        grid.isHidden = false
        handles.isHidden = false

        dim.path = dimPath(cropRect: cropRect)
        border.path = borderPath(cropRect: cropRect)
        grid.path = thirdsGridPath(cropRect: cropRect)
        handles.path = handlesPath(cropRect: cropRect)
    }

    private func dimPath(cropRect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(cropRect)
        return path
    }

    private func borderPath(cropRect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(cropRect)
        return path
    }

    private func thirdsGridPath(cropRect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for i in 1..<3 {
            let x = cropRect.minX + cropRect.width  * CGFloat(i) / 3
            let y = cropRect.minY + cropRect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: cropRect.minY))
            path.addLine(to: CGPoint(x: x, y: cropRect.maxY))
            path.move(to: CGPoint(x: cropRect.minX, y: y))
            path.addLine(to: CGPoint(x: cropRect.maxX, y: y))
        }
        return path
    }

    private func handlesPath(cropRect: CGRect) -> CGPath {
        let side: CGFloat = 8
        let inset: CGFloat = 4
        let positions: [CGPoint] = [
            CGPoint(x: cropRect.minX,        y: cropRect.minY),
            CGPoint(x: cropRect.midX,        y: cropRect.minY),
            CGPoint(x: cropRect.maxX,        y: cropRect.minY),
            CGPoint(x: cropRect.minX,        y: cropRect.midY),
            CGPoint(x: cropRect.maxX,        y: cropRect.midY),
            CGPoint(x: cropRect.minX,        y: cropRect.maxY),
            CGPoint(x: cropRect.midX,        y: cropRect.maxY),
            CGPoint(x: cropRect.maxX,        y: cropRect.maxY),
        ]
        let path = CGMutablePath()
        for center in positions {
            let handle = CGRect(x: center.x - side/2, y: center.y - side/2,
                                width: side, height: side)
                .insetBy(dx: -inset/2, dy: -inset/2)
            path.addRoundedRect(in: handle, cornerWidth: 1.5, cornerHeight: 1.5)
        }
        return path
    }

    // MARK: - Mask overlay (drawing)

    private func activeMask() -> Mask? {
        guard let id = document?.canvas.highlightedMaskID,
              let mask = document?.canvas.state.masks.first(where: { $0.id == id }) else { return nil }
        return mask
    }

    private func ensureMaskOverlayLayers() {
        if maskShapeLayer == nil {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            shape.lineWidth = 1.0
            shape.lineDashPattern = [4, 4]
            shape.isHidden = true
            shape.actions = disabledActions
            layer?.addSublayer(shape)
            maskShapeLayer = shape
        }
        if maskHandlesLayer == nil {
            let handles = CAShapeLayer()
            handles.fillColor = NSColor.white.cgColor
            handles.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
            handles.lineWidth = 0.5
            handles.isHidden = true
            handles.actions = disabledActions
            layer?.addSublayer(handles)
            maskHandlesLayer = handles
        }
    }

    private var disabledActions: [String: CAAction] {
        [
            "path":        NSNull(),
            "position":    NSNull(),
            "bounds":      NSNull(),
            "frame":       NSNull(),
            "fillColor":   NSNull(),
            "strokeColor": NSNull(),
            "hidden":      NSNull(),
        ]
    }

    private func updateMaskOverlay() {
        ensureMaskOverlayLayers()
        guard let shape = maskShapeLayer, let handles = maskHandlesLayer else { return }
        shape.frame = bounds
        handles.frame = bounds

        guard let doc = document, let mask = activeMask() else {
            shape.isHidden = true
            handles.isHidden = true
            return
        }
        shape.isHidden = false
        handles.isHidden = false

        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        let origin = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)

        shape.path = maskShapePath(mask: mask, iw: iw, ih: ih, origin: origin)
        handles.path = maskHandlesPath(mask: mask, iw: iw, ih: ih, origin: origin)
    }

    private func maskShapePath(mask: Mask, iw: CGFloat, ih: CGFloat, origin: NSPoint) -> CGPath {
        let path = CGMutablePath()
        switch mask.kind {
        case .radial(let cx, let cy, let r0, let r1):
            let center = viewPoint(x: cx * Double(iw), y: cy * Double(ih), origin: origin)
            let shortest = min(iw, ih) * viewZoom
            let outer = CGFloat(r1) * shortest
            let inner = CGFloat(r0) * shortest
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer,
                                       width: outer * 2, height: outer * 2))
            if inner > 1 {
                path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                                           width: inner * 2, height: inner * 2))
            }
        case .linear(let sx, let sy, let ex, let ey):
            let start = viewPoint(x: sx * Double(iw), y: sy * Double(ih), origin: origin)
            let end   = viewPoint(x: ex * Double(iw), y: ey * Double(ih), origin: origin)
            drawLinearGradientGuides(path: path, start: start, end: end)
        }
        return path
    }

    /// Three parallel guide lines (100%, 50%, 0%) perpendicular to the gradient
    /// axis, plus the axis itself. Matches Lightroom's visualization so the
    /// user can see where the falloff begins and ends.
    private func drawLinearGradientGuides(path: CGMutablePath, start: CGPoint, end: CGPoint) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        let dirX = dx / length, dirY = dy / length
        // Perpendicular unit vector.
        let perpX = -dirY, perpY = dirX
        // Extend perpendicular guides well beyond the view so they read as
        // "infinite" lines even when the axis is short on-canvas.
        let extend: CGFloat = max(bounds.width, bounds.height) * 2

        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

        // Axis (thin line from 100% to 0%)
        path.move(to: start)
        path.addLine(to: end)

        // Three perpendicular guides
        for point in [start, mid, end] {
            path.move(to: CGPoint(x: point.x + perpX * extend, y: point.y + perpY * extend))
            path.addLine(to: CGPoint(x: point.x - perpX * extend, y: point.y - perpY * extend))
        }
    }

    private func maskHandlesPath(mask: Mask, iw: CGFloat, ih: CGFloat, origin: NSPoint) -> CGPath {
        let path = CGMutablePath()
        let positions = mask.kind.handlePositions(imageWidth: Int(iw), imageHeight: Int(ih))
        for (_, imagePoint) in positions {
            let viewPt = viewPoint(x: Double(imagePoint.x), y: Double(imagePoint.y), origin: origin)
            let side = Self.maskHandleVisualSize
            path.addEllipse(in: CGRect(x: viewPt.x - side / 2, y: viewPt.y - side / 2,
                                       width: side, height: side))
        }
        return path
    }

    private func viewPoint(x imgX: Double, y imgY: Double, origin: NSPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(imgX) * viewZoom,
                y: origin.y + CGFloat(imgY) * viewZoom)
    }

    // MARK: - Mask interaction

    /// Hit-test a mouse-down against the active mask's controls.
    ///
    /// Priority (Lightroom-style forgiveness):
    ///   1. Explicit handles (center, radiusEdge, endpoints, midpoint).
    ///   2. Interior of a radial: grab the whole mask by its center.
    ///   3. Along the line of a linear: grab as midpoint.
    /// Returns false only when the click is on empty canvas away from the mask,
    /// in which case the caller falls through to pan.
    private func beginMaskInteraction(at point: NSPoint, for mask: Mask) -> Bool {
        guard let doc = document else { return false }
        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        let origin = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)

        if let handle = hitTestExplicitHandle(mask: mask, point: point, iw: iw, ih: ih, origin: origin) {
            maskInteraction = .handle(handle, startMouse: point, startKind: mask.kind)
            return true
        }
        if let handle = hitTestMaskInterior(mask: mask, point: point, iw: iw, ih: ih, origin: origin) {
            maskInteraction = .handle(handle, startMouse: point, startKind: mask.kind)
            return true
        }
        return false
    }

    /// Fast path — did the click land on one of the drawn handle dots?
    private func hitTestExplicitHandle(mask: Mask, point: NSPoint,
                                       iw: CGFloat, ih: CGFloat,
                                       origin: NSPoint) -> MaskHandle? {
        let positions = mask.kind.handlePositions(imageWidth: Int(iw), imageHeight: Int(ih))
        for (handle, imagePoint) in positions {
            let viewPt = viewPoint(x: Double(imagePoint.x), y: Double(imagePoint.y), origin: origin)
            if hypot(point.x - viewPt.x, point.y - viewPt.y) <= Self.maskHandleHitRadius {
                return handle
            }
        }
        return nil
    }

    /// Forgiveness pass — click inside a radial or near a linear line?
    private func hitTestMaskInterior(mask: Mask, point: NSPoint,
                                     iw: CGFloat, ih: CGFloat,
                                     origin: NSPoint) -> MaskHandle? {
        switch mask.kind {
        case .radial(let cx, let cy, _, let r1):
            let center = viewPoint(x: cx * Double(iw), y: cy * Double(ih), origin: origin)
            let outerRadiusView = CGFloat(r1) * min(iw, ih) * viewZoom
            if hypot(point.x - center.x, point.y - center.y) <= outerRadiusView {
                return .center
            }
            return nil
        case .linear(let sx, let sy, let ex, let ey):
            let start = viewPoint(x: sx * Double(iw), y: sy * Double(ih), origin: origin)
            let end   = viewPoint(x: ex * Double(iw), y: ey * Double(ih), origin: origin)
            if pointIsNearSegment(point, start: start, end: end,
                                  tolerance: Self.maskLineGrabDistance) {
                return .midpoint
            }
            return nil
        }
    }

    /// Perpendicular distance from `point` to segment `start`→`end`, and
    /// whether the projection falls within the segment. True if both hold
    /// within `tolerance`.
    private func pointIsNearSegment(_ point: NSPoint, start: CGPoint, end: CGPoint,
                                    tolerance: CGFloat) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0.001 else {
            return hypot(point.x - start.x, point.y - start.y) <= tolerance
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSq))
        let projX = start.x + t * dx
        let projY = start.y + t * dy
        return hypot(point.x - projX, point.y - projY) <= tolerance
    }

    private func applyMaskInteraction(_ interaction: MaskDragInteraction, current point: NSPoint) {
        guard let doc = document, let mask = activeMask(),
              let index = doc.canvas.state.masks.firstIndex(where: { $0.id == mask.id }) else { return }
        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        guard iw > 0, ih > 0 else { return }

        let updatedKind: MaskKind
        switch interaction {
        case .handle(let handle, let startMouse, let startKind):
            updatedKind = updatedMaskKind(startKind: startKind,
                                          handle: handle,
                                          startMouse: startMouse,
                                          currentMouse: point,
                                          imageWidth: iw, imageHeight: ih)
        }
        doc.canvas.state.masks[index].kind = updatedKind
        NotificationCenter.default.post(name: .canvasDidChange, object: doc)
    }

    private func updatedMaskKind(startKind: MaskKind,
                                 handle: MaskHandle,
                                 startMouse: NSPoint,
                                 currentMouse: NSPoint,
                                 imageWidth iw: CGFloat, imageHeight ih: CGFloat) -> MaskKind {
        switch handle {
        case .center, .midpoint:
            let dxImage = Double((currentMouse.x - startMouse.x) / viewZoom)
            let dyImage = Double((currentMouse.y - startMouse.y) / viewZoom)
            return startKind.translated(byNormalizedDelta: dxImage / Double(iw),
                                        dy: dyImage / Double(ih))
        case .radiusEdge:
            guard case .radial(let cx, let cy, _, _) = startKind else { return startKind }
            let origin = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)
            let centerView = viewPoint(x: cx * Double(iw), y: cy * Double(ih), origin: origin)
            let radiusInViewPoints = hypot(currentMouse.x - centerView.x,
                                           currentMouse.y - centerView.y)
            let radiusInImagePixels = radiusInViewPoints / viewZoom
            let shortestDim = min(iw, ih)
            return startKind.settingRadius(Double(radiusInImagePixels / shortestDim))
        case .startPoint, .endPoint:
            let origin = imageOrigin(iw: iw, ih: ih, zoom: viewZoom, offset: viewOffset)
            let imgX = Double((currentMouse.x - origin.x) / viewZoom) / Double(iw)
            let imgY = Double((currentMouse.y - origin.y) / viewZoom) / Double(ih)
            return startKind.settingLinearEndpoint(handle, to: (x: imgX, y: imgY))
        case .none:
            return startKind
        }
    }

    private func endMaskInteraction() {
        guard let interaction = maskInteraction else { return }
        maskInteraction = nil
        guard let doc = document, let mask = activeMask() else { return }
        let startKind: MaskKind = {
            if case .handle(_, _, let s) = interaction { return s }
            return mask.kind
        }()
        guard startKind != mask.kind else { return }
        doc.commitMaskGeometry(named: "Adjust \(mask.name)")
    }

    // MARK: - Rendering (all math in DRAWABLE PIXEL space)

    /// Print a warning line whenever draw() exceeds this many milliseconds.
    /// Set to 0 to disable. Cheap to leave on — only prints on slow frames.
    private static let slowFrameThresholdMs: Double = 6.0

    override func draw(_ dirtyRect: NSRect) {
        let startTime = CACurrentMediaTime()
        let drawSignpost = OSSignpostID(log: RenderSignpost.log)
        os_signpost(.begin, log: RenderSignpost.log, name: "draw", signpostID: drawSignpost)
        defer {
            os_signpost(.end, log: RenderSignpost.log, name: "draw", signpostID: drawSignpost)
            let elapsedMs = (CACurrentMediaTime() - startTime) * 1000
            if Self.slowFrameThresholdMs > 0 && elapsedMs > Self.slowFrameThresholdMs {
                NSLog("[Darkroom] slow draw: %.2f ms (bounds %.0fx%.0f)",
                      elapsedMs, bounds.width, bounds.height)
            }
        }

        guard let drawable = currentDrawable, let doc = document else { return }
        guard let commandBuffer = SharedRenderer.shared.commandQueue.makeCommandBuffer() else { return }

        clearDrawable(drawable, commandBuffer: commandBuffer)

        let iw = CGFloat(doc.canvas.width), ih = CGFloat(doc.canvas.height)
        guard iw > 0, ih > 0 else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        renderCanvas(doc: doc, iw: iw, ih: ih, drawable: drawable, commandBuffer: commandBuffer)

        // Update overlays INSIDE draw() so their CAShapeLayer commits
        // land in the same runloop tick as the Metal present. Without this,
        // overlays could commit a frame ahead or behind the image on
        // trackpad pans.
        updateCropOverlay()
        updateMaskOverlay()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func clearDrawable(_ drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    private func renderCanvas(doc: StarDocument, iw: CGFloat, ih: CGFloat,
                              drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let scale = window?.backingScaleFactor ?? 2.0
        let drawableW = bounds.width * scale
        let drawableH = bounds.height * scale

        os_signpost(.begin, log: RenderSignpost.log, name: "evaluatePreview")
        let output = doc.canvas.evaluatePreview()
        os_signpost(.end, log: RenderSignpost.log, name: "evaluatePreview")

        // The preview pipeline runs against a ≤4K proxy, so its extent is
        // smaller than the source dimensions the rest of the system talks in.
        // Scale up to canvas-domain so on-screen coords match the overlay math.
        let outputSize = output.extent.size
        guard outputSize.width > 0, outputSize.height > 0 else { return }
        let proxyUpscaleX = iw / outputSize.width
        let proxyUpscaleY = ih / outputSize.height

        let displayScale = viewZoom * scale
        let originPxX = (drawableW - iw * displayScale) / 2 + viewOffset.width * scale
        let originPxY = (drawableH - ih * displayScale) / 2 + viewOffset.height * scale

        let positioned = output
            .samplingLinear()
            .transformed(by: CGAffineTransform(translationX: -output.extent.origin.x,
                                               y: -output.extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: proxyUpscaleX * displayScale,
                                               y: proxyUpscaleY * displayScale))
            .transformed(by: CGAffineTransform(translationX: originPxX, y: originPxY))

        let destRect = CGRect(x: 0, y: 0, width: drawableW, height: drawableH)
        let destination = CIRenderDestination(mtlTexture: drawable.texture,
                                              commandBuffer: commandBuffer)
        destination.colorSpace = doc.canvas.colorSpace

        os_signpost(.begin, log: RenderSignpost.log, name: "startTask")
        do {
            _ = try SharedRenderer.shared.context.startTask(
                toRender: positioned, from: destRect, to: destination, at: .zero)
        } catch {
            NSLog("Render error: \(error)")
        }
        os_signpost(.end, log: RenderSignpost.log, name: "startTask")
    }
}
