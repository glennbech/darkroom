import CoreGraphics

/// Draggable control on a mask overlay.
enum MaskHandle: Equatable {
    case center       // radial: move the whole mask
    case radiusEdge   // radial: resize (drags outer radius; inner is scaled)
    case startPoint   // linear: 0% end of the gradient
    case endPoint     // linear: 100% end
    case midpoint     // linear: drag whole line
    case none
}

extension MaskKind {
    /// Handle positions in IMAGE-PIXEL coordinates (Y-up, matching CI).
    /// UI layers convert these to view-space via the canvas's `imageOrigin`
    /// and current zoom.
    func handlePositions(imageWidth: Int, imageHeight: Int) -> [MaskHandle: CGPoint] {
        switch self {
        case .radial(let cx, let cy, _, let r1):
            let iw = CGFloat(imageWidth), ih = CGFloat(imageHeight)
            let shortest = min(iw, ih)
            let center = CGPoint(x: iw * CGFloat(cx), y: ih * CGFloat(cy))
            let radiusOuter = shortest * CGFloat(r1)
            return [
                .center:     center,
                .radiusEdge: CGPoint(x: center.x + radiusOuter, y: center.y),
            ]
        case .linear(let sx, let sy, let ex, let ey):
            let iw = CGFloat(imageWidth), ih = CGFloat(imageHeight)
            let start = CGPoint(x: iw * CGFloat(sx), y: ih * CGFloat(sy))
            let end   = CGPoint(x: iw * CGFloat(ex), y: ih * CGFloat(ey))
            let mid   = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            return [
                .startPoint: start,
                .endPoint:   end,
                .midpoint:   mid,
            ]
        }
    }

    // MARK: - Kind updates (pure)

    /// Move the mask's origin (center for radial, midpoint for linear) by a
    /// delta in normalized image coordinates. Direction and size are preserved.
    func translated(byNormalizedDelta dx: Double, dy: Double) -> MaskKind {
        switch self {
        case .radial(let cx, let cy, let r0, let r1):
            return .radial(centerX: clamp01(cx + dx),
                           centerY: clamp01(cy + dy),
                           radiusInner: r0,
                           radiusOuter: r1)
        case .linear(let sx, let sy, let ex, let ey):
            return .linear(startX: clamp01(sx + dx),
                           startY: clamp01(sy + dy),
                           endX:   clamp01(ex + dx),
                           endY:   clamp01(ey + dy))
        }
    }

    /// Set the outer radius (radial masks only) preserving the inner:outer ratio.
    /// `radius` is normalized to the shortest image dimension.
    func settingRadius(_ radius: Double) -> MaskKind {
        guard case .radial(let cx, let cy, let r0, let r1) = self else { return self }
        let clamped = max(0.01, min(1.0, radius))
        let featherRatio = r1 > 0 ? r0 / r1 : 0.5
        return .radial(centerX: cx, centerY: cy,
                       radiusInner: clamped * featherRatio,
                       radiusOuter: clamped)
    }

    /// Replace the start or end point of a linear gradient (normalized coords).
    func settingLinearEndpoint(_ handle: MaskHandle, to point: (x: Double, y: Double)) -> MaskKind {
        guard case .linear(let sx, let sy, let ex, let ey) = self else { return self }
        let nx = clamp01(point.x)
        let ny = clamp01(point.y)
        switch handle {
        case .startPoint: return .linear(startX: nx, startY: ny, endX: ex, endY: ey)
        case .endPoint:   return .linear(startX: sx, startY: sy, endX: nx, endY: ny)
        default:          return self
        }
    }
}

private func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
