import SwiftUI

/// Lightroom-style "Crop and Rotate" panel.
///
/// Editing flow:
///  1. Opening this panel puts the canvas into crop mode. The full uncropped
///     image is revealed, dimmed outside a draft rectangle.
///  2. Drag corners / edges / interior on the canvas to refine the draft.
///     Aspect picker snaps the draft to a preset ratio.
///  3. Enter or "Apply" commits the draft as a `.crop` operation.
///     Escape or "Discard" reverts the draft to the committed state.
///     Closing the panel auto-commits any pending draft.
///  4. Straighten, Rotate 90°, and Flip commit immediately (folded into
///     `state.operations` via idempotent upsert).
struct CropPanel: View {
    let document: StarDocument

    @State private var aspect: CropAspect = .original
    @State private var straighten: Double = 0
    @State private var straightenSnapshot: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    tip
                    applyDiscardRow
                    aspectSection
                    // Straighten temporarily disabled — needs more design work
                    // to feel Lightroom-tight. Focus is on rectangular crop.
                    // straightenSection
                    rotateFlipSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow))
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Crop and Rotate")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Reset All") { resetCropAndRotation() }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .help("Clear all crop, straighten, rotate and flip operations")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VisualEffect(material: .titlebar, blending: .withinWindow))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var tip: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Drag handles or the interior to refine the crop. Enter to apply, Esc to cancel.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var applyDiscardRow: some View {
        HStack(spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .cancelCropDraft, object: nil)
            } label: {
                Text("Cancel")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button {
                NotificationCenter.default.post(name: .commitCropDraft, object: nil)
            } label: {
                Text("Apply")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var aspectSection: some View {
        section("Aspect Ratio") {
            Picker("", selection: $aspect) {
                ForEach(CropAspect.allCases) { option in Text(option.label).tag(option) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: aspect) { _, newValue in applyAspect(newValue) }
        }
    }

    @ViewBuilder
    private var straightenSection: some View {
        section("Straighten") {
            AdjustmentSlider(
                label: "Angle",
                value: straightenBinding,
                range: -45...45,
                defaultValue: 0,
                onEditingChanged: handleStraightenEditing
            )
        }
    }

    @ViewBuilder
    private var rotateFlipSection: some View {
        section("Rotate & Flip") {
            HStack(spacing: 8) {
                iconButton("rotate.left",   help: "Rotate 90° Left")  { commit(.rotate90(count: -1), name: "Rotate 90° Left") }
                iconButton("rotate.right",  help: "Rotate 90° Right") { commit(.rotate90(count:  1), name: "Rotate 90° Right") }
                Divider().frame(height: 20).opacity(0.5)
                iconButton("arrow.left.arrow.right", help: "Flip Horizontal") { commit(.flip(horizontal: true, vertical: false), name: "Flip Horizontal") }
                iconButton("arrow.up.arrow.down",    help: "Flip Vertical")   { commit(.flip(horizontal: false, vertical: true), name: "Flip Vertical") }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Straighten (live via pending)

    private var straightenBinding: Binding<Double> {
        Binding(
            get: { straighten },
            set: { newValue in
                straighten = newValue
                document.canvas.pendingOperation = .straighten(degrees: newValue)
                NotificationCenter.default.post(name: .canvasDidChange, object: document)
            }
        )
    }

    private func handleStraightenEditing(_ editing: Bool) {
        if editing {
            straightenSnapshot = straighten
            // Freeze the current preview render so per-frame straighten redraws
            // apply a single rotation to a flat texture instead of re-running
            // the full CI pipeline.
            document.canvas.beginInteraction()
            return
        }
        guard straighten != straightenSnapshot else {
            document.canvas.pendingOperation = nil
            document.canvas.endInteraction()
            NotificationCenter.default.post(name: .canvasDidChange, object: document)
            return
        }
        document.canvas.endInteraction()
        commit(.straighten(degrees: straighten),
               name: "Straighten \(String(format: "%.1f", straighten))°")
    }

    // MARK: - Aspect

    private func applyAspect(_ aspect: CropAspect) {
        switch aspect {
        case .original:
            // Lock to the source image's own aspect ratio.
            let sourceRatio = Double(document.canvas.width) / Double(document.canvas.height)
            NotificationCenter.default.post(name: .setCropDraftAspect,
                                            object: nil,
                                            userInfo: ["ratio": sourceRatio])
        case .freeform:
            // Unlock — keep the current draft, allow any shape.
            NotificationCenter.default.post(name: .setCropDraftAspect,
                                            object: nil,
                                            userInfo: [:])
        case .oneByOne, .sixteenByNine, .fourByThree, .threeByTwo:
            if let ratio = aspect.ratio {
                NotificationCenter.default.post(name: .setCropDraftAspect,
                                                object: nil,
                                                userInfo: ["ratio": ratio])
            }
        }
    }

    // MARK: - Rotate / Flip / Reset

    private func commit(_ op: Operation, name: String) {
        document.commitOperation(op, actionName: name)
    }

    private func resetCropAndRotation() {
        var newState = document.canvas.state
        newState.operations.removeAll { op in
            switch op {
            case .crop, .straighten, .rotate90, .flip: return true
            case .resize: return false
            }
        }
        guard newState != document.canvas.state else { return }
        document.canvas.pendingOperation = nil
        document.history.commit(newState: newState, name: "Reset Crop and Rotation")
        NotificationCenter.default.post(name: .resetCropDraftToFull, object: nil)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            aspect = .original
            straighten = 0
        }
    }
}

// MARK: - CropAspect

enum CropAspect: String, CaseIterable, Identifiable {
    case original, freeform
    case oneByOne, sixteenByNine, fourByThree, threeByTwo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original:      return "Original"
        case .freeform:      return "Free"
        case .oneByOne:      return "1:1"
        case .sixteenByNine: return "16:9"
        case .fourByThree:   return "4:3"
        case .threeByTwo:    return "3:2"
        }
    }

    var ratio: Double? {
        switch self {
        case .original, .freeform: return nil
        case .oneByOne:      return 1.0
        case .sixteenByNine: return 16.0 / 9.0
        case .fourByThree:   return 4.0 / 3.0
        case .threeByTwo:    return 3.0 / 2.0
        }
    }
}

// MARK: - NormalizedRect helpers

extension NormalizedRect {
    /// Largest centered rectangle in `size` matching a given aspect ratio.
    static func centeredRect(matching ratio: Double, in size: CGSize) -> NormalizedRect {
        guard size.width > 0, size.height > 0 else { return .full }
        let sourceRatio = Double(size.width / size.height)
        if ratio >= sourceRatio {
            let normalizedHeight = sourceRatio / ratio
            return NormalizedRect(x: 0,
                                  y: (1.0 - normalizedHeight) / 2.0,
                                  width: 1,
                                  height: normalizedHeight)
        }
        let normalizedWidth = ratio / sourceRatio
        return NormalizedRect(x: (1.0 - normalizedWidth) / 2.0,
                              y: 0,
                              width: normalizedWidth,
                              height: 1)
    }
}
