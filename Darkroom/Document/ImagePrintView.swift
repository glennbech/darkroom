import AppKit

/// NSView used by `NSPrintOperation` to render a single-page image print.
///
/// The view is sized to the print info's imageable page rect. On draw it
/// aspect-fits the image into that rect so orientation and paper size are
/// respected without stretching. One page, one image — no pagination.
final class ImagePrintView: NSView {
    private let image: CGImage

    init(image: CGImage, pageSize: NSSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: pageSize))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imageSize = CGSize(width: image.width, height: image.height)
        let target = Self.aspectFit(imageSize, in: bounds)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: target)
    }

    private static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        let x = bounds.minX + (bounds.width  - w) / 2
        let y = bounds.minY + (bounds.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
