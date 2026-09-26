import SwiftUI
import AppKit

@main
struct DarkroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands { menuCommands }
    }

    @CommandsBuilder private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            // Never mark these disabled — the disabled state is captured at
            // menu-build time and doesn't reactively update from the doc's
            // undo manager, which silently kills the shortcut. Let the undo
            // manager no-op instead if there's nothing to undo.
            Button("Undo") { currentDoc()?.undoManager?.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { currentDoc()?.undoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export…") { currentDoc()?.beginExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Print…") { currentDoc()?.beginPrint() }
                .keyboardShortcut("p", modifiers: .command)
        }
        CommandMenu("Image") {
            Button("Resize…") { currentDoc()?.beginResize() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandGroup(before: .windowList) {
            Button("Adjustments") { currentDoc()?.togglePanel(.adjustments) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Crop and Rotate") { currentDoc()?.togglePanel(.crop) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Masks") { currentDoc()?.togglePanel(.masks) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("History") { currentDoc()?.togglePanel(.history) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In")     { post(.zoomIn) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out")    { post(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { post(.zoomActual) }.keyboardShortcut("1", modifiers: .command)
            Button("Fit on Screen") { post(.zoomFit) }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Show Rulers") { post(.toggleRulers) }.keyboardShortcut("r", modifiers: .command)
        }
    }

    private func currentDoc() -> StarDocument? {
        NSDocumentController.shared.currentDocument as? StarDocument
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { _ = NSDocumentController.shared }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name {
    static let zoomIn        = Notification.Name("Darkroom.zoomIn")
    static let zoomOut       = Notification.Name("Darkroom.zoomOut")
    static let zoomActual    = Notification.Name("Darkroom.zoomActual")
    static let zoomFit       = Notification.Name("Darkroom.zoomFit")
    /// Canvas contents changed (adjustment slider, operation added, undo, redo).
    /// The canvas view redraws; if effective size differs, it refits automatically.
    static let canvasDidChange = Notification.Name("Darkroom.canvasDidChange")
    /// History list or currentIndex changed. History panel refreshes.
    static let historyDidChange = Notification.Name("Darkroom.historyDidChange")
    /// A dock panel toggle was requested. userInfo["panel"] carries a DockPanel raw value.
    static let togglePanel = Notification.Name("Darkroom.togglePanel")
    /// Commit the pending crop draft currently displayed on the canvas.
    static let commitCropDraft = Notification.Name("Darkroom.commitCropDraft")
    /// Discard the pending crop draft; revert to committed state.
    static let cancelCropDraft = Notification.Name("Darkroom.cancelCropDraft")
    /// Set a full-image draft (used when the Crop panel's Reset is pressed).
    static let resetCropDraftToFull = Notification.Name("Darkroom.resetCropDraftToFull")
    /// Snap the crop draft to a specific aspect ratio. userInfo["ratio"]: Double.
    static let setCropDraftAspect = Notification.Name("Darkroom.setCropDraftAspect")
    /// Toggle the on-canvas rulers (centimetres).
    static let toggleRulers = Notification.Name("Darkroom.toggleRulers")
}
