import SwiftUI
import UniformTypeIdentifiers

struct HierarchyView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var sceneManager: SceneManager
    let onFrameItem: (UUID) -> Void

    @State private var pendingDeleteIDs: [UUID] = []
    @State private var isShowingDeleteAlert = false
    @State private var draggingID: UUID?
    @State private var collapsedBoneIDs: Set<UUID> = []
    @State private var expandedSections: Set<String> = ["skeleton", "images", "constraints"]
    /// The row whose name box is open, or nil. Owned here rather than inside
    /// each row so the panel can stand its shortcuts down while the artist is
    /// typing, and so only one box can ever be open.
    @State private var renamingItemID: UUID?

    // Stable virtual UUIDs for section headers — never collide with real item IDs
    private static let virtualSkeletonUUID = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFFF")!
    private static let virtualImagesUUID   = UUID(uuidString: "00000000-0000-0000-0000-EEEEEEEEEEEE")!
    private static let virtualConstraintsUUID = UUID(uuidString: "00000000-0000-0000-0000-DDDDDDDDDDDD")!

    // MARK: - Data Model

    struct DisplayEntry: Identifiable {
        enum Kind {
            case item(HierarchyItem.ItemType)
            case mesh(UUID)
            /// An IK constraint. Not a `HierarchyItem`: constraints live on the
            /// skeleton, not in the item tree, and giving them a row here is a
            /// way of SHOWING them rather than of storing them somewhere new.
            case constraint(UUID)
            case virtualSection(title: String, icon: String, key: String)
        }

        let id: String
        let targetID: UUID
        let kind: Kind
        let depth: Int
        let continuingLevels: Set<Int>
        let showsDescendantContinuation: Bool
    }

    /// One rebuild of the tree: the rows, and the answers every row needs.
    ///
    /// The lookups live here because they were linear scans of the whole rig,
    /// run once per ROW: `binding(for:)` searched `hierarchyItems` for the
    /// item's index, and `hasChildren` searched the bones and then the sprites
    /// for anything parented to it. N rows each scanning N items is N squared,
    /// and the tree rebuilds on every `@Published` write on `SceneManager` —
    /// which a canvas drag produces on every frame. Built once, with the
    /// entries, they are dictionary and set lookups and the rebuild is linear.
    struct Display {
        let entries: [DisplayEntry]
        /// Row id -> its index in `sceneManager.hierarchyItems`.
        let indexByID: [UUID: Int]
        /// Every id that something — a bone or a sprite — is parented to.
        let parentsWithChildren: Set<UUID>
        /// Section key -> how many rows it holds.
        let sectionCounts: [String: Int]

    }

    struct TreeBaseEntry {
        let id: String
        let targetID: UUID
        let type: HierarchyItem.ItemType
        let kind: DisplayEntry.Kind
        let depth: Int
        let lineage: [UUID]
    }

    private let imageAccent = Color(red: 0.42, green: 0.68, blue: 0.82)   // soft steel blue
    private let boneAccent  = Color(red: 0.62, green: 0.50, blue: 0.85)   // muted lavender
    private let meshAccent  = Color(red: 0.82, green: 0.60, blue: 0.36)   // warm amber

    // MARK: - Body

    var body: some View {
        // ONCE per pass. `displayEntries` was a computed property named twice
        // in here — to ask whether it was empty and to iterate it — so every
        // rebuild built the whole tree, threw it away, and built it again.
        let display = self.display
        return ScrollView {
            if display.entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .padding(.top, 14)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    selectAllRow

                    ForEach(display.entries, id: \.id) { entry in
                        switch entry.kind {
                        case .virtualSection(let title, let icon, let key):
                            sectionHeader(
                                title: title, icon: icon, key: key,
                                count: display.sectionCounts[key] ?? 0,
                                isExpanded: expandedSections.contains(key)
                            )
                        case .constraint(let constraintID):
                            constraintRow(constraintID, depth: entry.depth)
                        case .item, .mesh:
                            if let itemBinding = binding(for: entry, in: display) {
                                HierarchyRowView(
                                    item: itemBinding.wrappedValue,
                                    depth: entry.depth,
                                    continuingLevels: entry.continuingLevels,
                                    showsDescendantContinuation: entry.showsDescendantContinuation,
                                    isSelected: isSelected(entry: entry),
                                    accentColor: accentColor(for: itemBinding.wrappedValue),
                                    boneColor: sceneManager.skeleton.bones[entry.targetID]?.color,
                                    hasChildren: hasChildren(entry: entry, in: display),
                                    isExpanded: !collapsedBoneIDs.contains(itemBinding.wrappedValue.id),
                                    onToggleExpanded: { toggleExpanded(item: itemBinding.wrappedValue) },
                                    canRename: entry.canRename,
                                    showsVisibilityControl: entry.showsVisibilityControl,
                                    showsEditAction: true,
                                    showsDragHandle: entry.showsDragHandle,
                                    showsContextMenu: entry.showsContextMenu,
                                    onEditMesh: { selectMesh(for: entry.targetID) },
                                    onEditBone: {},
                                    onToggleVisibility: {
                                        // By id only. Writing the binding first
                                        // set the same flag through a captured
                                        // array index, which is the hazard the
                                        // rename hit — `updateVisibility`
                                        // already updates the row and the image.
                                        let item = itemBinding.wrappedValue
                                        sceneManager.updateVisibility(itemID: item.id, isHidden: !item.isHidden)
                                    },
                                    onRequestDelete: { requestDelete(ids: [itemBinding.wrappedValue.id]) },
                                    onFrame: { onFrameItem(entry.targetID) },
                                    onSelect: { select(entry: entry, item: itemBinding.wrappedValue) },
                                    selectionMark: selectionMark(for: entry),
                                    onToggleSelection: selectionMark(for: entry) == nil
                                        ? nil
                                        : { toggleSelection(entry: entry, item: itemBinding.wrappedValue) },
                                    onRename: { proposed in
                                        sceneManager.renameHierarchyItem(
                                            itemID: itemBinding.wrappedValue.id,
                                            to: proposed
                                        )
                                    },
                                    renamingItemID: $renamingItemID
                                )
                                // Declaring `==` is not enough: the parent has
                                // to opt the child into being compared.
                                .equatable()
                                .modifier(
                                    HierarchyDragDropModifier(
                                        isEnabled: entry.showsDragHandle,
                                        item: itemBinding.wrappedValue,
                                        sceneManager: sceneManager,
                                        draggingID: $draggingID
                                    )
                                )
                            }
                        }
                    }
                    dropZone
                }
                .padding(.vertical, 2)
            }
        }
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.18), value: sceneManager.hierarchyItems)
        .animation(.easeInOut(duration: 0.15), value: expandedSections)
#if os(macOS)
        // Both stand down while a name box is open. A single-line NSTextField
        // does not consume Up or Down, so the arrows used to walk the selection
        // out from under the box the artist was typing in; and Delete, meant to
        // erase a character, popped the "Delete Item" alert.
        .onDeleteCommand {
            guard renamingItemID == nil else { return }
            // THE WHOLE SELECTION, like the button. This took the primary alone
            // — right when one item was all you could select, wrong the moment
            // the marks let you choose five and press Delete over them.
            requestDeleteSelection()
        }
        .onMoveCommand { direction in
            guard renamingItemID == nil else { return }
            moveSelection(direction)
        }
#endif
        .onDisappear { draggingID = nil; renamingItemID = nil }
        .onChange(of: sceneManager.hierarchyItems.count) { _, _ in
            // A row added or deleted while a box is open: close it rather than
            // let it hang over a tree that no longer has the same shape.
            renamingItemID = nil
        }
        .background(shortcutHandler)
        .alert("Delete Item", isPresented: $isShowingDeleteAlert) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { pendingDeleteIDs.removeAll() }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    /// The mark that takes the whole list, above it.
    ///
    /// At the top rather than in a toolbar, in the same column as every other
    /// mark, because that is what makes it read as "this one covers all of
    /// those" instead of as an unrelated command.
    private var selectAllRow: some View {
        let mark = selectAllMark
        return HStack(spacing: 6) {
            HierarchySelectionToggle(mark: mark, tint: imageAccent) {
                toggleSelectAll()
            }
            Text(mark == .full ? "Deselect All" : "Select All")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(UM.textSecondary)
                .animation(nil, value: mark)
            Spacer(minLength: 0)
            if selectedCount > 0 {
                Text("\(selectedCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(UM.textOnAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(UM.accentStrong))
                    .transition(.opacity.combined(with: .scale(0.8)))

                // NEXT TO THE COUNT, so it reads as "these five — remove
                // them". In a toolbar it would be a command with no stated
                // object, which is how the wrong thing gets deleted.
                Button(action: requestDeleteSelection) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.dangerAccent)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete the selected items")
                .accessibilityLabel(Text("Delete \(selectedCount) selected"))
                .transition(.opacity.combined(with: .scale(0.8)))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: selectedCount)
    }

    /// How many rows are in the selection right now — bones or sprites,
    /// whichever the artist is working with.
    private var selectedCount: Int {
        sceneManager.selectedBoneIDs.isEmpty
            ? sceneManager.selectedImageIDs.count
            : sceneManager.selectedBoneIDs.count
    }

    private func sectionHeader(title: String, icon: String, key: String, count: Int, isExpanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expandedSections.contains(key) {
                    expandedSections.remove(key)
                } else {
                    expandedSections.insert(key)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(UM.textMuted)
                    .frame(width: 10)

                // An empty icon name means the bone silhouette and "photo" the
                // picture mark — both shapes rather than SF Symbols, so a
                // section header wears the same glyph as the rows under it.
                if icon.isEmpty {
                    BoneGlyph()
                        .frame(width: 13, height: 13)
                } else if icon == "photo" {
                    ImageGlyph()
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(UM.textMuted)
                }

                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(UM.textMuted)
                    .tracking(0.7)

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(UM.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(UM.textPrimary.opacity(0.07)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, key == "skeleton" ? 2 : 8)
        .overlay(alignment: .leading) {
            // Vertical line at the level-0 column (absolute x=12)
            // that visually connects the section header down to its first child row.
            if isExpanded && count > 0 {
                Canvas { context, size in
                    let columnX: CGFloat = 12
                    let midY = size.height * 0.5
                    var path = Path()
                    path.move(to: CGPoint(x: columnX, y: midY))
                    path.addLine(to: CGPoint(x: columnX, y: size.height))
                    context.stroke(path, with: .color(UM.textPrimary.opacity(0.12)), lineWidth: 1)
                }
                .frame(width: 24)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        Color.clear
            .frame(height: 18)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                guard let draggingID else { return false }
                sceneManager.moveHierarchyItem(id: draggingID, toDisplayIndex: displayEntries.count)
                self.draggingID = nil
                return true
            }
    }

    // MARK: - Empty State

    /// Empty state, as the mockup draws it: one large soft disc, a line of
    /// explanation, and the action that resolves it.
    ///
    /// Import PNG is here rather than in the toolbar. This is the moment the
    /// artist needs it — an empty hierarchy is exactly the state it fixes — and
    /// it was previously a permanent button in the top bar, competing for
    /// attention long after the project had assets. It stays on Cmd-I and in
    /// the File menu.
    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(UM.accentSoft.opacity(0.55))
                    .frame(width: 96, height: 96)
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(UM.textPrimary.opacity(0.55))
            }

            Text("Import a PNG or create bones to start.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UM.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)

            Button {
                NotificationCenter.default.post(name: .ultraMeshRequestImportPNG, object: nil)
            } label: {
                Text("Import PNG")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UM.textPrimary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(UM.accentSoft))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: .command)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Section Count

    // MARK: - Display Entries

    /// The rows, for the paths that only need them: the drop zone's index and
    /// the arrow-key walk. Both run on a gesture, not on every body pass.
    private var displayEntries: [DisplayEntry] { display.entries }

    private var display: Display {
        let skeletonOpen = expandedSections.contains("skeleton")
        let imagesOpen   = expandedSections.contains("images")

        let itemsByID = Dictionary(uniqueKeysWithValues: sceneManager.hierarchyItems.map { ($0.id, $0) })
        let boneDepths = Dictionary(uniqueKeysWithValues: sceneManager.skeleton.orderedBones.map {
            ($0.id, boneDepth(for: $0.id))
        })

        let hasBones = !sceneManager.skeleton.orderedBones.isEmpty

        var baseEntries: [TreeBaseEntry] = []
        var insertedImagesSection = false

        // Virtual Skeleton section header
        if hasBones {
            baseEntries.append(TreeBaseEntry(
                id: "§skeleton",
                targetID: Self.virtualSkeletonUUID,
                type: .bone,
                kind: .virtualSection(title: "Skeleton", icon: "", key: "skeleton"),
                depth: 0,
                lineage: []
            ))
        }

        for id in sceneManager.displayHierarchyIDs() {
            guard let item = itemsByID[id] else { continue }
            if isHiddenByCollapsedAncestor(itemID: id, type: item.type) { continue }

            switch item.type {
            case .bone:
                guard skeletonOpen else { continue }
                let rawDepth = boneDepths[id] ?? 0
                baseEntries.append(TreeBaseEntry(
                    id: id.uuidString,
                    targetID: id,
                    type: .bone,
                    kind: .item(.bone),
                    depth: rawDepth + 1,
                    lineage: [Self.virtualSkeletonUUID] + boneLineage(for: id)
                ))

            case .image, .mesh:
                if let boundBoneID = sceneManager.image(for: id)?.boneBinding?.boneID {
                    // Bound to a bone → Skeleton section
                    guard skeletonOpen else { continue }
                    let rawDepth = (boneDepths[boundBoneID] ?? 0) + 1
                    let lineage  = [Self.virtualSkeletonUUID] + boneLineage(for: boundBoneID) + [boundBoneID]
                    baseEntries.append(TreeBaseEntry(
                        id: id.uuidString,
                        targetID: id,
                        type: .image,
                        kind: .item(.image),
                        depth: rawDepth + 1,
                        lineage: lineage
                    ))
                    baseEntries.append(TreeBaseEntry(
                        id: "mesh-\(id.uuidString)",
                        targetID: id,
                        type: .mesh,
                        kind: .mesh(id),
                        depth: rawDepth + 2,
                        lineage: lineage + [id]
                    ))
                } else {
                    // Unbound → Images section
                    if !insertedImagesSection {
                        insertedImagesSection = true
                        baseEntries.append(TreeBaseEntry(
                            id: "§images",
                            targetID: Self.virtualImagesUUID,
                            type: .image,
                            kind: .virtualSection(title: "Images", icon: "photo", key: "images"),
                            depth: 0,
                            lineage: []
                        ))
                    }
                    guard imagesOpen else { continue }
                    baseEntries.append(TreeBaseEntry(
                        id: id.uuidString,
                        targetID: id,
                        type: .image,
                        kind: .item(.image),
                        depth: 1,
                        lineage: [Self.virtualImagesUUID]
                    ))
                    baseEntries.append(TreeBaseEntry(
                        id: "mesh-\(id.uuidString)",
                        targetID: id,
                        type: .mesh,
                        kind: .mesh(id),
                        depth: 2,
                        lineage: [Self.virtualImagesUUID, id]
                    ))
                }
            }
        }

        // Constraints, last, as their own section. They are not part of the
        // item tree — they belong to the skeleton — so they get a section of
        // their own rather than being threaded into the bones they drive,
        // where they would appear as many times as they have bones.
        let constraints = sceneManager.skeleton.ikConstraints
        if !constraints.isEmpty {
            baseEntries.append(TreeBaseEntry(
                id: "§constraints",
                targetID: Self.virtualConstraintsUUID,
                type: .bone,
                kind: .virtualSection(title: "Constraints", icon: "", key: "constraints"),
                depth: 0,
                lineage: []
            ))
            if expandedSections.contains("constraints") {
                for constraint in constraints {
                    baseEntries.append(TreeBaseEntry(
                        id: "ik-\(constraint.id.uuidString)",
                        targetID: constraint.id,
                        type: .bone,
                        kind: .constraint(constraint.id),
                        depth: 1,
                        lineage: [Self.virtualConstraintsUUID]
                    ))
                }
            }
        }

        // The tree lines, in ONE backward pass.
        //
        // `continuingLevels` and `showsDescendantContinuation` each scanned
        // every LATER entry, for every entry — a third quadratic, inside the
        // rebuild itself and independent of the per-row ones. Both ask the
        // same question in the end: has some entry after this one got <id> at
        // level <n> of its lineage? Walking backwards and remembering the
        // pairs already passed answers both in one step each.
        var seenLater: Set<AncestorKey> = []
        var continuing = [Set<Int>](repeating: [], count: baseEntries.count)
        var descends = [Bool](repeating: false, count: baseEntries.count)
        for index in stride(from: baseEntries.count - 1, through: 0, by: -1) {
            let entry = baseEntries[index]
            descends[index] = seenLater.contains(
                AncestorKey(level: entry.depth, id: entry.targetID))
            if entry.depth > 0 {
                var levels: Set<Int> = []
                for level in 0..<entry.depth where entry.lineage.count > level {
                    if seenLater.contains(AncestorKey(level: level, id: entry.lineage[level])) {
                        levels.insert(level)
                    }
                }
                continuing[index] = levels
            }
            for (level, ancestor) in entry.lineage.enumerated() {
                seenLater.insert(AncestorKey(level: level, id: ancestor))
            }
        }

        // The two answers every ROW needs, built once here rather than by a
        // linear scan per row inside the `ForEach`.
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(sceneManager.hierarchyItems.count)
        for (position, item) in sceneManager.hierarchyItems.enumerated() {
            indexByID[item.id] = position
        }
        var parentsWithChildren: Set<UUID> = []
        for bone in sceneManager.skeleton.orderedBones {
            if let parentID = bone.parentID { parentsWithChildren.insert(parentID) }
        }
        var unboundImages = 0
        for image in sceneManager.images {
            if let boneID = image.boneBinding?.boneID {
                parentsWithChildren.insert(boneID)
            } else {
                unboundImages += 1
            }
        }

        return Display(
            entries: baseEntries.enumerated().map { index, entry in
                DisplayEntry(
                    id: entry.id,
                    targetID: entry.targetID,
                    kind: entry.kind,
                    depth: entry.depth,
                    continuingLevels: continuing[index],
                    showsDescendantContinuation: descends[index]
                )
            },
            indexByID: indexByID,
            parentsWithChildren: parentsWithChildren,
            sectionCounts: [
                "skeleton": sceneManager.skeleton.orderedBones.count,
                "images": unboundImages,
                "constraints": constraints.count,
            ]
        )
    }

    /// One rung of one row's lineage: "something at level <level> whose id is
    /// <id>". The tree-line pass is a set of these.
    private struct AncestorKey: Hashable {
        let level: Int
        let id: UUID
    }

    // MARK: - Tree Helpers

    private func boneLineage(for boneID: UUID) -> [UUID] {
        var lineage: [UUID] = []
        var currentID = sceneManager.skeleton.bone(boneID)?.parentID
        while let parentID = currentID {
            lineage.insert(parentID, at: 0)
            currentID = sceneManager.skeleton.bone(parentID)?.parentID
        }
        return lineage
    }

    private func isHiddenByCollapsedAncestor(itemID: UUID, type: HierarchyItem.ItemType) -> Bool {
        switch type {
        case .bone:
            var currentID = sceneManager.skeleton.bone(itemID)?.parentID
            while let parentID = currentID {
                if collapsedBoneIDs.contains(parentID) { return true }
                currentID = sceneManager.skeleton.bone(parentID)?.parentID
            }
            return false
        case .image, .mesh:
            guard let boundBoneID = sceneManager.image(for: itemID)?.boneBinding?.boneID else { return false }
            var currentID: UUID? = boundBoneID
            while let boneID = currentID {
                if collapsedBoneIDs.contains(boneID) { return true }
                currentID = sceneManager.skeleton.bone(boneID)?.parentID
            }
            return false
        }
    }

    private func boneDepth(for boneID: UUID) -> Int {
        var depth = 0
        var currentID = sceneManager.skeleton.bone(boneID)?.parentID
        while let parentID = currentID { depth += 1; currentID = sceneManager.skeleton.bone(parentID)?.parentID }
        return depth
    }

    // MARK: - Row Helpers

    private func accentColor(for item: HierarchyItem) -> Color {
        switch item.type {
        case .bone:  return boneAccent
        case .image: return imageAccent
        case .mesh:  return meshAccent
        }
    }

    private func hasChildren(entry: DisplayEntry, in display: Display) -> Bool {
        guard case let .item(type) = entry.kind, type == .bone else { return false }
        return display.parentsWithChildren.contains(entry.targetID)
    }

    private func toggleExpanded(item: HierarchyItem) {
        guard item.type == .bone else { return }
        if collapsedBoneIDs.contains(item.id) { collapsedBoneIDs.remove(item.id) }
        else { collapsedBoneIDs.insert(item.id) }
    }

    // MARK: - Constraint row

    /// A constraint's row.
    ///
    /// Drawn here rather than through `HierarchyRowView`, which takes a
    /// `HierarchyItem` and draws a bone, a sprite or a mesh from its type. A
    /// constraint is none of those and has no item: giving it one would mean
    /// putting it in the saved item tree, which is a storage change made to
    /// solve a drawing problem.
    @ViewBuilder
    private func constraintRow(_ constraintID: UUID, depth: Int) -> some View {
        if let constraint = sceneManager.skeleton.ikConstraints.first(where: { $0.id == constraintID }) {
            let isSelected = sceneManager.selectedConstraintID == constraintID
            Button {
                sceneManager.selectedConstraintID = constraintID
            } label: {
                HStack(spacing: 7) {
                    Spacer().frame(width: CGFloat(depth) * 14)
                    IKConstraintGlyph(isEnabled: constraint.enabled)
                        .frame(width: 15, height: 15)
                    Text(constraint.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(constraint.enabled ? UM.textPrimary : UM.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(UM.textPrimary.opacity(isSelected ? 0.10 : 0))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Selection

    private func isSelected(entry: DisplayEntry) -> Bool {
        switch entry.kind {
        case .virtualSection: return false
        case .constraint(let id): return sceneManager.selectedConstraintID == id
        case .item(let type):
            switch type {
            case .bone:  return sceneManager.selectedBoneIDs.contains(entry.targetID)
            case .image: return sceneManager.selectedImageID == entry.targetID && !sceneManager.isMeshLayerSelected
            case .mesh:  return sceneManager.selectedImageID == entry.targetID && sceneManager.isMeshLayerSelected
            }
        case .mesh(let imageID):
            return sceneManager.selectedImageID == imageID && sceneManager.isMeshLayerSelected
        }
    }

    /// The mark on a row, or nil when the row is not something a selection can
    /// contain.
    ///
    /// Bones and sprites only. A section heading is a label, and a constraint
    /// is selected one at a time by the panel that edits it — giving either a
    /// checkbox would promise a multi-selection that nothing downstream can
    /// act on.
    private func selectionMark(for entry: DisplayEntry) -> HierarchySelectionMark? {
        switch entry.kind {
        case .item(.bone):
            return sceneManager.selectedBoneIDs.contains(entry.targetID) ? .full : .empty
        case .item(.image), .item(.mesh), .mesh:
            return sceneManager.selectedImageIDs.contains(entry.targetID) ? .full : .empty
        case .virtualSection, .constraint:
            return nil
        }
    }

    /// Add or remove one row, without a modifier key.
    ///
    /// This is Cmd-click, reachable. `select(entry:item:)` reads
    /// `currentModifiers()` and says so in its own comment: on iPadOS without a
    /// hardware keyboard there is no modifier to read, so an artist there could
    /// not build a selection from the hierarchy at all — only by rubber-band on
    /// the canvas, and only over what happened to be visible.
    ///
    /// Bones and sprites stay separate, because they already are: selecting a
    /// sprite clears the bone selection and the reverse, and this does not
    /// invent a mixed selection that the transforms, the timeline and the
    /// inspector would then have to learn about.
    private func toggleSelection(entry: DisplayEntry, item: HierarchyItem) {
        switch entry.kind {
        case .item(.bone):
            sceneManager.toggleBoneSelection(entry.targetID)
        case .item(.image), .item(.mesh), .mesh:
            let id = entry.targetID
            var ids = sceneManager.selectedImageIDs
            if ids.contains(id) {
                ids.remove(id)
                // The primary follows the set rather than being left pointing
                // at something no longer in it.
                sceneManager.setSelection(ids: Array(ids),
                                          primary: ids.contains(sceneManager.selectedImageID ?? id)
                                              ? sceneManager.selectedImageID
                                              : ids.first,
                                          additive: false)
            } else {
                sceneManager.setSelection(ids: [id], primary: id, additive: true)
            }
        case .virtualSection, .constraint:
            break
        }
    }

    /// Every row a selection can contain, in the order they are shown.
    private var selectableEntries: [DisplayEntry] {
        displayEntries.filter { selectionMark(for: $0) != nil }
    }

    /// The mark for "select all": full when every selectable row is in, partial
    /// when some are, empty when none are.
    var selectAllMark: HierarchySelectionMark {
        let entries = selectableEntries
        guard !entries.isEmpty else { return .empty }
        let selected = entries.filter { selectionMark(for: $0) == .full }.count
        if selected == 0 { return .empty }
        return selected == entries.count ? .full : .partial
    }

    /// Select everything, or — when everything already is — clear it.
    ///
    /// PARTIAL SELECTS THE REST rather than clearing. Tapping a half-filled
    /// mark to finish the job is the common intent; tapping it to throw away
    /// what is already chosen is the one an artist would have to undo, and
    /// selection is not undoable.
    ///
    /// Bones and sprites are still separate, so "all" means all of the kind
    /// that is currently selected, and all sprites when nothing is.
    func toggleSelectAll() {
        let entries = selectableEntries
        guard !entries.isEmpty else { return }
        if selectAllMark == .full {
            sceneManager.clearSelection()
            return
        }
        let bones = entries.compactMap { entry -> UUID? in
            if case .item(.bone) = entry.kind { return entry.targetID }
            return nil
        }
        let images = entries.compactMap { entry -> UUID? in
            if case .item(.bone) = entry.kind { return nil }
            return entry.targetID
        }
        if !sceneManager.selectedBoneIDs.isEmpty, !bones.isEmpty {
            sceneManager.setBoneSelection(bones, primary: bones.last, additive: false)
        } else if !images.isEmpty {
            sceneManager.setSelection(ids: images, primary: images.first, additive: false)
        } else if !bones.isEmpty {
            sceneManager.setBoneSelection(bones, primary: bones.last, additive: false)
        }
    }

    private func select(entry: DisplayEntry, item: HierarchyItem) {
        // Cmd toggles one row in or out; Shift takes the run from the bone that
        // is already active down to this one. Both are read here rather than in
        // the row, because the run needs the ROW ORDER and only this view knows
        // it.
        //
        // On iPadOS a hardware keyboard reports the same flags; without one
        // there is no modifier to read, and the canvas marquee is the multi-
        // select gesture there.
        let modifiers = HierarchyView.currentModifiers()
        switch entry.kind {
        case .virtualSection: break
        case .constraint(let id): sceneManager.selectedConstraintID = id
        case .item(let type):
            switch type {
            case .bone:
                if modifiers.contains(.shift) {
                    sceneManager.setBoneSelection(shiftBoneRange(to: item.id),
                                                  primary: item.id, additive: false)
                } else if modifiers.contains(.command) {
                    sceneManager.toggleBoneSelection(item.id)
                } else {
                    sceneManager.selectBone(item.id)
                }
            case .image:
                if sceneManager.meshWeightPaintEnabled {
                    sceneManager.selectMeshLayer(for: item.id)
                } else {
                    sceneManager.setSelection(ids: [item.id], primary: item.id, additive: false)
                }
            case .mesh: selectMesh(for: item.id)
            }
        case .mesh(let imageID): selectMesh(for: imageID)
        }
    }

    /// The bone rows between the active bone and this one, in row order.
    ///
    /// Row order, not skeleton order: Shift over a list means "everything I can
    /// see between these two", and the tree is what the artist is looking at.
    /// With nothing active yet it is just this bone — a run needs two ends.
    private func shiftBoneRange(to boneID: UUID) -> [UUID] {
        let boneRows: [UUID] = displayEntries.compactMap { entry -> UUID? in
            if case .item(.bone) = entry.kind { return entry.targetID }
            return nil
        }
        guard let anchor = sceneManager.selectedBoneID,
              let from = boneRows.firstIndex(of: anchor),
              let to = boneRows.firstIndex(of: boneID) else { return [boneID] }
        return Array(boneRows[min(from, to)...max(from, to)])
    }

    /// The modifier keys held right now.
    ///
    /// SwiftUI does not hand a plain `Button` action its modifiers, and the
    /// hierarchy rows are buttons; `Gesture.modifiers(_:)` is macOS-only. So on
    /// macOS the platform is asked at the moment the action runs, and on
    /// iPadOS there is no answer to ask for: a tap arrives with no event to
    /// read. Multi-select there is the canvas marquee and the timeline rows,
    /// which do get their modifiers — and which work with a finger, where a
    /// Cmd-click never could.
    ///
    /// Returned rather than branched at the call site so the selection rules
    /// above are written once, the same on both platforms.
    private static func currentModifiers() -> EventModifiers {
        #if os(macOS)
        var result: EventModifiers = []
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
        #else
        return []
        #endif
    }

    private func selectMesh(for imageID: UUID) {
        sceneManager.selectMeshLayer(for: imageID)
        // The tool, and nothing else. This used to set `meshShowDeformed` as
        // well — off when entering mesh edit, on when leaving — so clicking a
        // row in the tree silently changed a checkbox in the Mesh panel, and
        // the artist's own setting was overwritten by a selection.
        //
        // Weight paint counts as much as mesh edit here. Dropping to another
        // tool runs `canvasToolChanged`, which turns the brush off — so
        // picking a different mesh in the tree, which is only a change of
        // subject, threw the artist out of weight paint entirely.
        if sceneManager.isSpriteMeshMode {
            appState.toolManager.setTool(.mesh)
            return
        }
        // With no mode running: the MOVE tool, not Mesh mode.
        //
        // This did enter Mesh mode for a while, on the reading that picking a
        // mesh row is a request to edit the mesh. It is not — it is a request
        // to get at the NODES, which the move tool's vertex path already
        // gives: hit a node, drag it, the mesh deforms. Mesh mode is a larger
        // thing, with the Add / Modify / Delete sub-modes, the triangles and
        // the panel, and wanting to nudge a node now and then is not asking
        // for any of that.
        //
        // So the Mesh button stays the only way into Mesh mode. That is not a
        // convention here, it is structural: `isMeshEditEnabled = true` is
        // written in exactly one place, inside `CanvasModeSelection.enter`,
        // and `verify_canvas_modes.py` fails if a second one appears.
        appState.toolManager.setTool(.move)
    }

    // MARK: - Binding

    private func binding(for entry: DisplayEntry, in display: Display) -> Binding<HierarchyItem>? {
        switch entry.kind {
        case .virtualSection, .constraint: return nil
        case .item:
            guard let index = display.indexByID[entry.targetID] else { return nil }
            return $sceneManager.hierarchyItems[index]
        case .mesh(let imageID):
            return Binding(
                get: {
                    guard let image = sceneManager.image(for: imageID) else {
                        return HierarchyItem(id: imageID, name: "Mesh", type: .mesh, isHidden: false, children: [], order: 0)
                    }
                    return HierarchyItem(id: imageID, name: "\(image.name) Mesh", type: .mesh, isHidden: image.isHidden, children: [], order: 0)
                },
                set: { _ in }
            )
        }
    }

    // MARK: - Delete

    private var deleteMessage: String {
        pendingDeleteIDs.count == 1
            ? "Are you sure you want to delete this item?"
            : "Are you sure you want to delete \(pendingDeleteIDs.count) items?"
    }

    /// Everything the artist has selected, in row order.
    ///
    /// ROW ORDER, not set order: a Swift `Set` iterates in an order seeded per
    /// process, and "delete these five" has to mean the same five in the same
    /// sequence on every run — the confirmation names a count, and the undo
    /// that follows has to be reproducible.
    ///
    /// One definition for the button and for the Delete key. They deleted
    /// different things before: the key took `selectedBoneID ?? selectedImageID`,
    /// a single item, which was right when a single item was all you could
    /// select and stopped being right the moment the marks arrived.
    var selectedHierarchyIDs: [UUID] {
        let bones = sceneManager.selectedBoneIDs
        let images = sceneManager.selectedImageIDs
        guard !bones.isEmpty || !images.isEmpty else { return [] }
        return displayEntries.compactMap { entry -> UUID? in
            switch entry.kind {
            case .item(.bone):
                return bones.contains(entry.targetID) ? entry.targetID : nil
            case .item(.image), .item(.mesh), .mesh:
                return images.contains(entry.targetID) ? entry.targetID : nil
            case .virtualSection, .constraint:
                return nil
            }
        }
    }

    /// Delete everything selected, after asking.
    func requestDeleteSelection() {
        let ids = selectedHierarchyIDs
        guard !ids.isEmpty else { return }
        requestDelete(ids: ids)
    }

    private func requestDelete(ids: [UUID]) {
        pendingDeleteIDs = ids
        isShowingDeleteAlert = true
    }

    private func performDelete() {
        for id in pendingDeleteIDs { sceneManager.deleteHierarchy(itemID: id) }
        pendingDeleteIDs.removeAll()
    }

    // MARK: - Keyboard Navigation

#if os(macOS)
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !displayEntries.isEmpty else { return }
        let currentIndex = displayEntries.firstIndex(where: { isSelected(entry: $0) }) ?? 0
        let nextIndex: Int
        switch direction {
        case .up:   nextIndex = max(0, currentIndex - 1)
        case .down: nextIndex = min(displayEntries.count - 1, currentIndex + 1)
        default:    return
        }
        let nextEntry = displayEntries[nextIndex]
        if let itemBinding = binding(for: nextEntry, in: display) {
            select(entry: nextEntry, item: itemBinding.wrappedValue)
        }
    }
#endif

    private var shortcutHandler: some View {
        // A command-key equivalent fires whether or not a text field has focus,
        // so this duplicated the selection out from under a half-typed name.
        Button("Duplicate") {
            guard renamingItemID == nil else { return }
            sceneManager.duplicateSelected()
        }
        .keyboardShortcut("d", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

// MARK: - DisplayEntry Extensions

private extension HierarchyView.DisplayEntry {
    var canRename: Bool {
        switch kind {
        case .virtualSection, .mesh, .constraint: return false
        case .item(let type):                     return type != .mesh
        }
    }

    var showsVisibilityControl: Bool {
        switch kind {
        case .virtualSection, .mesh, .constraint: return false
        case .item(let type):                     return type != .mesh
        }
    }

    var showsDragHandle: Bool {
        switch kind {
        case .virtualSection, .mesh, .constraint: return false
        case .item(let type):                     return type != .mesh
        }
    }

    var showsContextMenu: Bool { showsDragHandle }
}

// MARK: - Drag-Drop Modifier

private struct HierarchyDragDropModifier: ViewModifier {
    let isEnabled: Bool
    let item: HierarchyItem
    let sceneManager: SceneManager
    @Binding var draggingID: UUID?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    draggingID = item.id
                    return NSItemProvider(object: item.id.uuidString as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: HierarchyDropDelegate(
                        item: item,
                        sceneManager: sceneManager,
                        draggingID: $draggingID
                    )
                )
        } else {
            content
        }
    }
}
