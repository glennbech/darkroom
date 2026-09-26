import CoreGraphics

/// A rectangle expressed in normalized 0...1 coordinates relative to some
/// parent extent. Used for crop rects so they survive resolution changes and
/// serialize as plain numbers.
struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool { self == .full }

    /// Return the rectangle scaled into a source extent (image-pixel coordinates).
    func rect(in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.origin.x + CGFloat(x) * extent.width,
            y: extent.origin.y + CGFloat(y) * extent.height,
            width:  CGFloat(width)  * extent.width,
            height: CGFloat(height) * extent.height
        )
    }

    // MARK: - Aspect-locked resize

    /// Snap this rectangle to `ratio` (w/h), anchored so that the OPPOSITE side
    /// of the dragged `handle` stays fixed.
    ///
    /// Corner handles pick the axis with the larger delta from `original` as
    /// the driver; the other dimension is derived from the ratio.
    /// Edge handles use the handle's own axis as driver (right/left edges drive
    /// width; top/bottom drive height); the perpendicular dimension is centered.
    func constrained(toRatio ratio: Double,
                     handle: CropHandle,
                     original: NormalizedRect) -> NormalizedRect {
        guard ratio > 0 else { return self }
        let anchor = CropAnchor.forHandle(handle)
        guard anchor != .interior else { return self }

        let widthDriven = anchor.driver(handle: handle, current: self, original: original) == .width
        var newWidth  = width
        var newHeight = height
        if widthDriven { newHeight = newWidth / ratio }
        else           { newWidth  = newHeight * ratio }

        let newX: Double
        switch anchor.horizontal {
        case .left:   newX = x
        case .right:  newX = x + width - newWidth
        case .center: newX = x + (width - newWidth) / 2
        }
        let newY: Double
        switch anchor.vertical {
        case .bottom: newY = y
        case .top:    newY = y + height - newHeight
        case .center: newY = y + (height - newHeight) / 2
        }

        return NormalizedRect(x: newX, y: newY, width: newWidth, height: newHeight)
            .clampedToUnitSquare()
    }

    /// Clamp origin and size so the rect stays within (0,0,1,1) without changing shape.
    func clampedToUnitSquare() -> NormalizedRect {
        let w = min(1, max(0, width))
        let h = min(1, max(0, height))
        let x = min(1 - w, max(0, self.x))
        let y = min(1 - h, max(0, self.y))
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - CropAnchor (pure geometry for aspect-locked resize)

/// Which side / corner of a rectangle stays fixed while resizing.
/// Derived deterministically from `CropHandle` — the opposite side of the
/// dragged handle is what's anchored.
struct CropAnchor: Equatable {
    enum Horizontal { case left, right, center }
    enum Vertical   { case bottom, top, center }
    enum Driver     { case width, height }

    let horizontal: Horizontal
    let vertical: Vertical

    /// Sentinel used when the handle isn't a resize handle (interior/outside).
    static let interior = CropAnchor(horizontal: .center, vertical: .center)

    static func forHandle(_ handle: CropHandle) -> CropAnchor {
        switch handle {
        case .topLeft:     return CropAnchor(horizontal: .right,  vertical: .bottom)
        case .topRight:    return CropAnchor(horizontal: .left,   vertical: .bottom)
        case .bottomLeft:  return CropAnchor(horizontal: .right,  vertical: .top)
        case .bottomRight: return CropAnchor(horizontal: .left,   vertical: .top)
        case .top:         return CropAnchor(horizontal: .center, vertical: .bottom)
        case .bottom:      return CropAnchor(horizontal: .center, vertical: .top)
        case .left:        return CropAnchor(horizontal: .right,  vertical: .center)
        case .right:       return CropAnchor(horizontal: .left,   vertical: .center)
        case .interior, .outside: return .interior
        }
    }

    /// Which dimension is the "driver" of a ratio-locked resize.
    /// Edges naturally drive their perpendicular; corners pick the axis that
    /// changed most from the drag-start rectangle.
    func driver(handle: CropHandle,
                current: NormalizedRect,
                original: NormalizedRect) -> Driver {
        switch handle {
        case .left, .right:       return .width
        case .top, .bottom:       return .height
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let dw = abs(current.width  - original.width)
            let dh = abs(current.height - original.height)
            return dw >= dh ? .width : .height
        case .interior, .outside: return .width
        }
    }
}
