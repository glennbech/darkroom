import Foundation
import CoreImage

/// Complete non-destructive edit state for one document.
///
/// This is the entire "what the user has done" — a small, Codable, versioned
/// value. Snapshotting this into a history stack gives us undo, redo, jump,
/// and future project persistence for free.
///
/// Forward compatibility rules (see CLAUDE.md):
/// - `schema` starts at 1 and only bumps on breaking changes.
/// - New fields are added with defaults; nothing is removed or renamed.
/// - Decoded from newer versions gracefully degrade; unknown fields survive round-trip.
struct EditorState: Codable, Equatable {
    let schema: Int
    var operations: [Operation]
    var adjustments: Adjustments
    var masks: [Mask]

    init(schema: Int = 1,
         operations: [Operation] = [],
         adjustments: Adjustments = .identity,
         masks: [Mask] = []) {
        self.schema = schema
        self.operations = operations
        self.adjustments = adjustments
        self.masks = masks
    }

    static let empty = EditorState()

    // Forward-compatible decoding — see Adjustments for rationale.
    private enum CodingKeys: String, CodingKey { case schema, operations, adjustments, masks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema      = try container.decodeIfPresent(Int.self,          forKey: .schema)      ?? 1
        self.operations  = try container.decodeIfPresent([Operation].self,  forKey: .operations)  ?? []
        self.adjustments = try container.decodeIfPresent(Adjustments.self,  forKey: .adjustments) ?? .identity
        self.masks       = try container.decodeIfPresent([Mask].self,       forKey: .masks)       ?? []
    }

    /// Effective canvas dimensions given a source size, without touching pixels.
    ///
    /// `skipCrop` is used by the Crop panel: while the user is refining a
    /// crop draft we render the full image, so the committed crop op must be
    /// bypassed both in evaluate() and in the derived dimensions.
    func effectiveSize(sourceWidth: Int, sourceHeight: Int,
                       skipCrop: Bool = false) -> (width: Int, height: Int) {
        var size = (width: sourceWidth, height: sourceHeight)
        for op in operations {
            if skipCrop, case .crop = op { continue }
            size = op.transformSize(size)
        }
        return size
    }

    /// Deterministic pipeline: pure function of `(source, self)`.
    /// Composed as source → operations → global adjustments → each mask.
    func evaluate(source: CIImage) -> CIImage {
        var img = source
        for op in operations { img = op.apply(to: img) }
        img = adjustments.apply(to: img)
        img = MaskCompositor.apply(masks: masks, to: img)
        return img
    }

    /// Insert or fold `op` into the operations list so that repeated invocations
    /// of the same *kind* stay idempotent — matching the Antipatterns rule in
    /// CLAUDE.md ("don't append operations of the same kind on repeated clicks").
    ///
    /// - crop / straighten: replace any existing occurrence
    /// - rotate90: accumulate counts (mod 4), remove if zero
    /// - flip: XOR into the existing flip state, remove if identity
    /// - resize: append (successive resizes are legitimate)
    func upserting(_ op: Operation) -> EditorState {
        var copy = self
        switch op {
        case .crop:
            copy.operations.removeAll { if case .crop = $0 { return true } else { return false } }
            copy.operations.append(op)
        case .straighten:
            copy.operations.removeAll { if case .straighten = $0 { return true } else { return false } }
            copy.operations.append(op)
        case .rotate90(let delta):
            var total = delta
            copy.operations.removeAll { existing in
                if case .rotate90(let c) = existing { total += c; return true }
                return false
            }
            let normalized = ((total % 4) + 4) % 4
            if normalized != 0 {
                copy.operations.append(.rotate90(count: normalized))
            }
        case .flip(let h, let v):
            var finalH = h, finalV = v
            copy.operations.removeAll { existing in
                if case .flip(let eh, let ev) = existing {
                    finalH = finalH != eh
                    finalV = finalV != ev
                    return true
                }
                return false
            }
            if finalH || finalV {
                copy.operations.append(.flip(horizontal: finalH, vertical: finalV))
            }
        case .resize:
            copy.operations.append(op)
        }
        return copy
    }
}
