import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HierarchyRowView: View {
    /// A value, not a binding. The row used to hold
    /// `$sceneManager.hierarchyItems[index]` and write the new name straight
    /// into it; renaming now goes through `onRename`, addressed by id, so there
    /// is no longer any reason to hand a row write access to an array slot that
    /// may have moved since it was drawn.
    let item: HierarchyItem
    let depth: Int
    let continuingLevels: Set<Int>
    let showsDescendantContinuation: Bool
    let isSelected: Bool
    let accentColor: Color
    /// The colour weight paint gave this bone, if anything is bound to it.
    /// Nil for an image or mesh row, and for a bone nothing is bound to.
    var boneColor: SIMD4<Float>? = nil
    let hasChildren: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let canRename: Bool
    let showsVisibilityControl: Bool
    let showsEditAction: Bool
    let showsDragHandle: Bool
    let showsContextMenu: Bool
    let onEditMesh: () -> Void
    let onEditBone: () -> Void
    let onToggleVisibility: () -> Void
    let onRequestDelete: () -> Void
    let onFrame: () -> Void
    let onSelect: () -> Void
    /// The circular mark, and what tapping it does.
    ///
    /// Nil means this row cannot be part of a multi-selection — a section
    /// heading, a constraint. Defaulted so every existing call site compiles
    /// unchanged and opts in by passing one.
    var selectionMark: HierarchySelectionMark? = nil
    var onToggleSelection: (() -> Void)? = nil
    /// Commit a rename. Returns whether anything actually changed, so a box
    /// opened and closed again does not push an undo entry.
    let onRename: (String) -> Bool

    /// The row being renamed, owned by the panel.
    ///
    /// This was `@State private var isEditing` per row, which meant nothing
    /// could see that a rename was in progress: the panel kept Up/Down, Delete
    /// and Cmd-D armed over the open box, and double-clicking a second row left
    /// two boxes open at once. One optional id makes "exactly one row is being
    /// renamed" structural rather than a convention.
    @Binding var renamingItemID: UUID?

    @State private var isHovering = false
    @State private var draftName = ""
    @State private var isNameFocused = false

    private var isEditing: Bool { renamingItemID == item.id }

    /// Nil for every kind now: bones, images and meshes all draw their own
    /// glyph rather than an SF Symbol on a disc. Kept as an optional because
    /// `iconBadge` still branches on it, and a section header may yet name
    /// something that has no glyph of its own.
    private var iconName: String? {
        switch item.type {
        case .image: return nil
        case .bone:  return nil
        case .mesh:  return nil
        }
    }

    private var editIconName: String? {
        switch item.type {
        case .image, .mesh: return "square.grid.3x3"
        case .bone:         return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            treeGuide
                .frame(width: CGFloat(max(depth, 0)) * 12 + 16)

            HStack(spacing: 6) {
                disclosureControl

                // BEFORE the glyph, so the marks line up in a column down the
                // panel whatever kind each row is. A checkbox that moves with
                // the indent is one an artist has to look for.
                if let selectionMark, let onToggleSelection {
                    HierarchySelectionToggle(mark: selectionMark,
                                             tint: accentColor,
                                             action: onToggleSelection)
                }

                iconBadge

                if isEditing {
                    SelectableTextField(text: $draftName, isFocused: $isNameFocused)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UM.textPrimary)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(UM.textPrimary.opacity(0.08)))
                        .onSubmit { commitEditing() }
                } else {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.isHidden ? UM.textSecondary : UM.textPrimary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { if canRename { startEditing() } }
                        .accessibilityAddTraits(.isButton)
                }

                Spacer(minLength: 4)

                if isHovering {
                    if showsEditAction, let editIconName {
                        Button(action: {
                            switch item.type {
                            case .bone:         onEditBone()
                            case .image, .mesh: onEditMesh()
                            }
                        }) {
                            Image(systemName: editIconName)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UM.textSecondary)
                    }

                    if showsVisibilityControl {
                        Button(action: onToggleVisibility) {
                            Image(systemName: item.isHidden ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.isHidden ? UM.textSecondary : UM.textMuted)
                    }

                    if showsDragHandle {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(UM.textMuted)
                    }
                } else if showsVisibilityControl && item.isHidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UM.textMuted)
                }
            }
            .padding(.vertical, item.type == .bone ? 3 : 4.5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(accentColor.opacity(isSelected ? 0.80 : isHovering ? 0.25 : 0.0))
                    .frame(width: isSelected ? 2 : 1.5)
                    .padding(.vertical, 3)
                    .offset(x: -7)
            }
        }
        .padding(.horizontal, 4)
        .background { rowBackground }
        .opacity(item.isHidden ? 0.50 : 1.0)
        .contentShape(Rectangle())
        .contextMenu {
            if showsContextMenu {
                if canRename {
                    Button("Rename", action: startEditing)
                }
                Button("Frame", action: onFrame)
                Divider()
                Button("Delete", role: .destructive, action: onRequestDelete)
            }
        }
        // Not while the box is open. This gesture covers the whole row,
        // the text field included, so every click meant to place the caret
        // also re-selected the row and fought the field for the click.
        .onTapGesture(count: 1) { if !isEditing { onSelect() } }
        .onHover { isHovering = $0 }
        .onChange(of: isNameFocused) { _, focused in
            if isEditing && !focused { commitEditing() }
        }
        // The single commit point. A box can close four ways — Return, clicking
        // away, opening another row's box, the panel clearing the id after a
        // delete — and only the first two went through commitEditing, so the
        // other two used to throw the typing away. Closing the box is what
        // commits it; Escape discards by emptying the draft first.
        .onChange(of: isEditing) { _, editing in
            if !editing { commitDraft() }
        }
#if os(macOS)
        .onExitCommand { if isEditing { cancelEditing() } }
#endif
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if hasChildren {
            Button(action: onToggleExpanded) {
                ZStack {
                    Circle()
                        .fill(UM.textPrimary.opacity(isSelected ? 0.10 : 0.05))
                        .overlay(Circle().stroke(UM.textPrimary.opacity(isSelected ? 0.18 : 0.09), lineWidth: 0.5))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(isSelected ? 0.70 : 0.38))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 11, height: 11)
        }
    }

    private var iconBadge: some View {
        ZStack {
            if let iconName {
                Circle()
                    .fill(UM.textPrimary.opacity(isSelected ? 0.09 : 0.05))
                    .overlay(Circle().stroke(UM.textPrimary.opacity(isSelected ? 0.16 : 0.08),
                                             lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                Image(systemName: iconName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(accentColor.opacity(isSelected ? 0.95 : 0.72))
            } else if item.type == .image {
                // Same treatment as the bone, in fuchsia: its own contour and
                // no disc behind it.
                ImageGlyph()
                    .frame(width: 13, height: 13)
                    .opacity(isSelected ? 1.0 : 0.88)
            } else if item.type == .mesh {
                // A geodesic ball. A wireframe has no body, so it is one
                // colour rather than the other two glyphs' body-and-contour.
                MeshGlyph()
                    .frame(width: 13, height: 13)
                    .opacity(isSelected ? 1.0 : 0.88)
            } else {
                // No disc behind the bone: it has its own contour, and the extra
                // room is what lets the contour survive. Measured — below about
                // 11 pt the purple edge falls under a pixel and the glyph reads
                // as a pale smudge.
                BoneGlyph(boneColor: boneColor)
                    .frame(width: 13, height: 13)
                    .opacity(isSelected ? 1.0 : 0.88)
            }
        }
    }

    private var treeGuide: some View {
        Canvas { context, size in
            let guideColor  = UM.textPrimary.opacity(0.09)
            let branchColor = UM.textPrimary.opacity(isSelected ? 0.30 : 0.17)
            let midY   = size.height * 0.5
            let nodeX  = CGFloat(depth) * 12 + 8
            let corner: CGFloat = 3.5

            // Ancestor vertical continuation lines
            for level in 0..<depth {
                let x    = CGFloat(level) * 12 + 8
                let endY = continuingLevels.contains(level) ? size.height : midY
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: endY))
                context.stroke(path, with: .color(guideColor), lineWidth: 1)
            }

            if depth > 0 {
                let parentX = CGFloat(depth - 1) * 12 + 8
                // Rounded elbow: vertical down, smooth corner, horizontal to node
                var elbow = Path()
                elbow.move(to: CGPoint(x: parentX, y: 0))
                elbow.addLine(to: CGPoint(x: parentX, y: midY - corner))
                elbow.addQuadCurve(
                    to: CGPoint(x: parentX + corner, y: midY),
                    control: CGPoint(x: parentX, y: midY)
                )
                elbow.addLine(to: CGPoint(x: nodeX, y: midY))
                context.stroke(elbow, with: .color(branchColor), lineWidth: isSelected ? 1.3 : 1.0)
            }

            if showsDescendantContinuation {
                var down = Path()
                down.move(to: CGPoint(x: nodeX, y: midY))
                down.addLine(to: CGPoint(x: nodeX, y: size.height))
                context.stroke(down, with: .color(guideColor), lineWidth: 1.0)
            }

            // Small semantic accent dot at the node connection point
            if depth > 0 {
                let dot = CGRect(x: nodeX - 1.5, y: midY - 1.5, width: 3, height: 3)
                context.fill(Path(ellipseIn: dot), with: .color(accentColor.opacity(isSelected ? 0.75 : 0.45)))
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accentColor.opacity(0.09))
        } else if isHovering {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(UM.textPrimary.opacity(0.045))
        }
    }

    /// Seed the draft BEFORE the field exists.
    ///
    /// This used to live in `.onChange(of: isEditing)`, which SwiftUI runs
    /// *after* the body has been evaluated with the new value — so the field
    /// was built, and `NSTextField(string:)` seeded, from the previous draft,
    /// and only corrected on the following update. Setting focus here too is
    /// what makes the iPad field come up focused at all: the iOS branch reads
    /// `isFocused` in `onAppear` and never observes it changing afterwards, so
    /// a value arriving one step late never reached it and the keyboard stayed
    /// down until the artist tapped the box a second time.
    private func startEditing() {
        guard !isEditing, canRename else { return }
        draftName = item.name
        renamingItemID = item.id
        isNameFocused = true
    }

    private func commitEditing() {
        guard isEditing else { return }
        isNameFocused = false
        renamingItemID = nil
    }

    private func cancelEditing() {
        guard isEditing else { return }
        draftName = item.name       // nothing left to commit
        isNameFocused = false
        renamingItemID = nil
    }

    /// Push the draft, if it says anything different, and forget it.
    ///
    /// The scene owns the rename: it addresses the row by id, resolves the
    /// unique name against the whole tree, and carries the image or bone name
    /// along with the row. The view no longer keeps its own copy of that rule —
    /// there were two, and they disagreed about which rows count as taken.
    private func commitDraft() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { draftName = item.name }
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        _ = onRename(trimmed)
    }
}

#if os(macOS)
private struct SelectableTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if isFocused, nsView.window?.firstResponder != nsView.currentEditor() {
            nsView.window?.makeFirstResponder(nsView)
            nsView.currentEditor()?.selectAll(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { self._text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}
#else
private struct SelectableTextField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .focused($focused)
            .onAppear { focused = isFocused }
            // Both directions. This only read `isFocused` once, in onAppear,
            // and never again — so focus arriving a step later never reached
            // the field and the keyboard stayed down until the box was tapped
            // a second time. Autocapitalisation is off because these are rig
            // names, and "arm.upper" came back as "Arm.upper".
            .onChange(of: isFocused) { _, newValue in
                if focused != newValue { focused = newValue }
            }
            .onChange(of: focused) { _, newValue in
                if isFocused != newValue { isFocused = newValue }
            }
    }
}
#endif

// MARK: - Equatable

/// Lets SwiftUI leave a row alone when its data has not changed.
///
/// SwiftUI skips a child view whose stored properties all compare equal, and
/// it does that comparison structurally — but a closure is never equal to
/// another closure, and this row takes eleven of them. One is enough: without
/// an explicit `==`, every row's `body` ran again on every rebuild of the
/// tree, and the tree rebuilds on every `@Published` write on `SceneManager`,
/// which a canvas drag produces once a frame. Two hundred rows of view
/// construction and diffing, per frame, on the main thread, in front of the
/// next one.
///
/// Compared over the DATA only. The closures are deliberately excluded: they
/// are rebuilt on every pass by definition and carry no information the row
/// draws. Every property the row DOES draw has to be here — a field left out
/// freezes on screen, because nothing will ever tell SwiftUI it changed —
/// which is why `verify_hierarchy_rebuild_cost.py` reads the struct's own
/// stored properties and checks each one appears below.
extension HierarchyRowView: Equatable {
    static func == (lhs: HierarchyRowView, rhs: HierarchyRowView) -> Bool {
        lhs.item == rhs.item
            && lhs.depth == rhs.depth
            && lhs.continuingLevels == rhs.continuingLevels
            && lhs.showsDescendantContinuation == rhs.showsDescendantContinuation
            && lhs.isSelected == rhs.isSelected
            && lhs.accentColor == rhs.accentColor
            && lhs.boneColor == rhs.boneColor
            && lhs.hasChildren == rhs.hasChildren
            && lhs.isExpanded == rhs.isExpanded
            && lhs.canRename == rhs.canRename
            && lhs.showsVisibilityControl == rhs.showsVisibilityControl
            && lhs.showsEditAction == rhs.showsEditAction
            && lhs.showsDragHandle == rhs.showsDragHandle
            && lhs.showsContextMenu == rhs.showsContextMenu
            // The binding's VALUE: which row is being renamed decides whether
            // this one draws a name box or a label.
            && lhs.renamingItemID == rhs.renamingItemID
            // AND THE MARK. Without this the row compares equal while its
            // checkbox has changed, SwiftUI skips the body, and the mark never
            // updates — a selection control that does not show the selection.
            // `verify_hierarchy_rebuild_cost.py` caught exactly that, which is
            // what it is for: every property the row DRAWS has to be one it
            // COMPARES, or the skip is a lie.
            && lhs.selectionMark == rhs.selectionMark
    }
}
