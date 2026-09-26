import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One open image editing session.
///
/// Responsibilities kept intentionally narrow:
/// - Own the CanvasModel and HistoryManager.
/// - Bridge NSDocument I/O to the CGImageSource/CGImageDestination layer.
/// - Post notifications for UI (window content) to react to.
///
/// Business logic (rendering, history, adjustments) lives in the model layer.
final class StarDocument: NSDocument {
    var canvas: CanvasModel
    let history = HistoryManager()

    override init() {
        self.canvas = CanvasModel.empty()
        super.init()
        self.hasUndoManager = true
        wireHistory()
    }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        let contentView = ContentView(document: self)
        let hosting = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .visible
        window.tabbingMode = .preferred
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    // MARK: - I/O

    override func read(from url: URL, ofType typeName: String) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        let ci = CIImage(cgImage: cg)
        let colorSpace = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let dpi = Self.extractDPI(from: source) ?? 72
        self.canvas = CanvasModel(source: ci,
                                  width: cg.width,
                                  height: cg.height,
                                  colorSpace: colorSpace,
                                  sourceUTI: typeName,
                                  dpi: dpi)
        wireHistory()
        history.seed(with: canvas.state)
        NotificationCenter.default.post(name: .canvasDidChange, object: self)
    }

    /// Best-effort DPI extraction from the first image in a CGImageSource.
    /// Falls back to nil if the metadata isn't present.
    private static func extractDPI(from source: CGImageSource) -> Double? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 { return dpi }
        return nil
    }

    override func data(ofType typeName: String) throws -> Data {
        let rendered = canvas.evaluate()
        let context = SharedRenderer.shared.context
        let type = UTType(typeName) ?? .png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil),
              let cgImage = context.createCGImage(rendered,
                                                  from: rendered.extent,
                                                  format: .RGBA8,
                                                  colorSpace: canvas.colorSpace) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        return data as Data
    }

    // MARK: - Edits

    func applyResize(to size: CGSize, method: ResizeMethod) {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let newState = canvas.state.upserting(.resize(width: width, height: height, method: method))
        history.commit(newState: newState, name: "Resize to \(width) × \(height)")
    }

    /// Commit slider-driven adjustment changes into history as a single entry.
    /// Live drag updates go straight to `canvas.state` for smoothness; this is
    /// called at drag-end.
    func commitAdjustments(named name: String) {
        history.commit(newState: canvas.state, name: name)
    }

    // MARK: - Masks

    /// Append a new mask and commit the state change. Returns the new mask ID
    /// so the UI can select it.
    @discardableResult
    func addMask(kind: MaskKind, name: String) -> UUID {
        let mask = Mask(kind: kind, name: name)
        var newState = canvas.state
        newState.masks.append(mask)
        history.commit(newState: newState, name: "Add \(kind.label) Mask")
        return mask.id
    }

    func removeMask(id: UUID) {
        var newState = canvas.state
        newState.masks.removeAll { $0.id == id }
        guard newState != canvas.state else { return }
        history.commit(newState: newState, name: "Remove Mask")
    }

    /// Commit a mask geometry change (drag-end). Live drags mutate
    /// `canvas.state.masks[index].kind` directly for smoothness; this pushes
    /// the current state into history as a single entry.
    func commitMaskGeometry(named name: String) {
        history.commit(newState: canvas.state, name: name)
    }

    /// Fold an operation into `state.operations` (idempotently) and commit.
    /// Clears `pendingOperation` atomically so there's no flicker between the
    /// live preview and the committed state.
    func commitOperation(_ op: Operation, actionName: String) {
        canvas.pendingOperation = nil
        let newState = canvas.state.upserting(op)
        guard newState != canvas.state else { return }
        history.commit(newState: newState, name: actionName)
    }

    // MARK: - UI intents

    func togglePanel(_ panel: DockPanel) {
        NotificationCenter.default.post(name: .togglePanel,
                                        object: self,
                                        userInfo: ["panel": panel.rawValue])
    }

    // MARK: - Sheets

    func beginResize() {
        guard let window = windowControllers.first?.window else { return }
        let sheet = NSHostingController(rootView: ResizeSheet(
            current: CGSize(width: canvas.width, height: canvas.height),
            onCancel: { [weak self] in self?.dismissSheet() },
            onApply: { [weak self] size, method in
                self?.applyResize(to: size, method: method)
                self?.dismissSheet()
            }
        ))
        sheet.view.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        window.contentViewController?.presentAsSheet(sheet)
    }

    private func dismissSheet() {
        guard let vc = windowControllers.first?.window?.contentViewController else { return }
        vc.presentedViewControllers?.forEach { vc.dismiss($0) }
    }

    func beginPrint() {
        guard let window = windowControllers.first?.window else { return }
        let rendered = canvas.evaluate()
        let context = SharedRenderer.shared.context
        guard let cgImage = context.createCGImage(rendered,
                                                  from: rendered.extent,
                                                  format: .RGBA8,
                                                  colorSpace: canvas.colorSpace) else {
            NSSound.beep()
            return
        }

        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.orientation = cgImage.width > cgImage.height ? .landscape : .portrait

        let view = ImagePrintView(image: cgImage, pageSize: printInfo.imageablePageBounds.size)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = displayName ?? "Untitled"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func beginExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.nameFieldStringValue = displayName ?? "Untitled"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .png
            do {
                let data = try self.data(ofType: type.identifier)
                try data.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Private

    /// Wire HistoryManager to this document's undo manager and canvas.
    /// Applying a state pushes it into the model and posts canvasDidChange
    /// so the render surface refreshes.
    private func wireHistory() {
        history.undoManager = undoManager
        history.applyState = { [weak self] newState in
            guard let self else { return }
            self.canvas.state = newState
            self.updateChangeCount(.changeDone)
            NotificationCenter.default.post(name: .canvasDidChange, object: self)
        }
        history.onChange = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .historyDidChange, object: self)
        }
    }
}
