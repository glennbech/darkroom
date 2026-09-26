import SwiftUI

/// Masks panel — list of masks plus, when one is selected, the same adjustment
/// stack as the Adjustments panel but routed to that mask's own adjustments.
///
/// Selecting a mask lights up its area on the canvas with a red tint via
/// `CanvasModel.highlightedMaskID`. Closing the panel or clearing the
/// selection removes the tint.
struct MasksPanel: View {
    let document: StarDocument

    @State private var selectedMaskID: UUID?
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    maskList
                    if selectedMaskID != nil {
                        Divider().opacity(0.5)
                        selectedMaskAdjustments
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(VisualEffect(material: .sidebar, blending: .behindWindow))
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidChange)) { note in
            guard let obj = note.object as AnyObject?, obj === document else { return }
            refreshTick &+= 1
            // Sync the panel's selection with the canvas's highlight — the
            // canvas can clear it via Enter/Escape on the keyboard.
            if selectedMaskID != document.canvas.highlightedMaskID {
                selectedMaskID = document.canvas.highlightedMaskID
            }
            // If the selected mask was deleted (e.g. via undo), clear.
            if let id = selectedMaskID,
               !document.canvas.state.masks.contains(where: { $0.id == id }) {
                clearSelection()
            }
        }
        .onDisappear { clearSelection() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Text("Masks")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            addButton
            removeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(VisualEffect(material: .titlebar, blending: .withinWindow))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var addButton: some View {
        Menu {
            Button("Radial") { add(kind: .defaultRadial(), name: newMaskName(prefix: "Radial")) }
            Button("Linear Gradient") { add(kind: .defaultLinear(), name: newMaskName(prefix: "Linear")) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add mask")
    }

    private var removeButton: some View {
        Button {
            if let id = selectedMaskID { remove(id: id) }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(selectedMaskID == nil)
        .help("Remove selected mask")
    }

    // MARK: - Mask list

    @ViewBuilder
    private var maskList: some View {
        let masks = document.canvas.state.masks
        if masks.isEmpty {
            emptyState
        } else {
            VStack(spacing: 2) {
                ForEach(masks) { mask in
                    row(for: mask)
                }
            }
            .id(refreshTick)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No masks yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Text("Use + above to add a radial or linear gradient mask.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func row(for mask: Mask) -> some View {
        let isSelected = selectedMaskID == mask.id
        return Button {
            select(isSelected ? nil : mask.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: mask.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 14)
                Text(mask.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                Spacer()
                if mask.isInverted {
                    Text("inv")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(for kind: MaskKind) -> String {
        switch kind {
        case .radial: return "circle.dashed"
        case .linear: return "line.diagonal"
        }
    }

    // MARK: - Adjustments for selected mask

    @ViewBuilder
    private var selectedMaskAdjustments: some View {
        if let id = selectedMaskID,
           document.canvas.state.masks.contains(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                MaskInvertToggle(document: document, maskID: id)
                    .id("\(id)-invert")
                MaskAmountSlider(document: document, maskID: id)
                    .id("\(id)-amount")
                AdjustmentSlidersView(document: document, target: .mask(id))
                    .id(id)  // rebuild the mirror when the selected mask changes
            }
        }
    }

    // MARK: - Actions

    private func add(kind: MaskKind, name: String) {
        let id = document.addMask(kind: kind, name: name)
        select(id)
    }

    private func remove(id: UUID) {
        document.removeMask(id: id)
        clearSelection()
    }

    private func select(_ id: UUID?) {
        selectedMaskID = id
        document.canvas.highlightedMaskID = id
        NotificationCenter.default.post(name: .canvasDidChange, object: document)
    }

    private func clearSelection() {
        guard selectedMaskID != nil || document.canvas.highlightedMaskID != nil else { return }
        selectedMaskID = nil
        document.canvas.highlightedMaskID = nil
        NotificationCenter.default.post(name: .canvasDidChange, object: document)
    }

    /// "Radial 1", "Radial 2", … avoiding collisions with existing names.
    private func newMaskName(prefix: String) -> String {
        let existing = Set(document.canvas.state.masks.map(\.name))
        var index = 1
        while existing.contains("\(prefix) \(index)") { index += 1 }
        return "\(prefix) \(index)"
    }
}
