/// Which part of the crop draft is being hit-tested or dragged.
/// Lives in the model layer (not the canvas view) so pure resize/constraint
/// logic can be unit-tested without pulling in AppKit or MTKView.
enum CropHandle: Equatable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
    case interior
    case outside
}
