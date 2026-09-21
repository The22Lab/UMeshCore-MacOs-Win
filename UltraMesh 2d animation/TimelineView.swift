import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var sceneManager: SceneManager

    private let sidebarWidth: CGFloat = 240
    private var timelineLabelsWidth: CGFloat { TimelineMetrics.labelsWidth }
    private var rowHeight: CGFloat { TimelineMetrics.rowHeight }
    private let frameSpacing: CGFloat = 21
    private let contentLeadingInset: CGFloat = 10
    private let graphMinHeight: CGFloat = 130

    /// What part of the curve the Graph Editor is looking at.
    ///
    /// Nil means the artist has not navigated, and the view fits the curve —
    /// its handles and its true extrema, not its keyframe values. See
    /// `graphViewportOrFit` and `GraphViewport`.
    @State private var graphViewport: GraphViewport?
    private let graphIdealHeight: CGFloat = 190

    @State private var isLoopEnabled = true
    @State private var isScrubbing = false
    /// Set only while a scrub is in flight. Everything else reads the model.
    ///
    /// This used to be the view's own copy of the playhead, kept in step by an
    /// `onChange` — which meant a second full body evaluation for every frame
    /// of playback, for a number the model already had.
    @State private var scrubFrame: Double?
    @State private var timelineContentOffset: CGPoint = .zero
    @State private var timelineViewportSize: CGSize = .zero
    /// Groups the artist has folded away. Session state: a rig big enough to
    /// need folding is one you are working through now, not a preference.
    @State private var collapsedTrackGroups: Set<String> = []
    /// Bumped on every accepted key press; the diamond animates off the change.
    @State private var keyPressCount: Int = 0
    /// Frame the current head drag started from, so the drag stays 1:1.
    @State private var scrubStartFrame: Double = 0
    @State private var trackTreeCache = TrackTreeCache()
    @State private var activeKeyframeDrag: ActiveKeyframeDrag?
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDragCurrent: CGPoint?
    @State private var activeGraphPointDrag: ActiveGraphPointDrag?
    @State private var activeGraphHandleDrag: ActiveGraphHandleDrag?
    @State private var activeCurveSegmentDrag: ActiveCurveSegmentDrag?

    private var palette: TimelinePalette { .default }
    private var unitMode: TimelineUnitMode {
        get { TimelineUnitMode(rawValue: appState.timelineUnitModeRawValue) ?? .frames }
        nonmutating set { appState.timelineUnitModeRawValue = newValue.rawValue }
    }

    private var isSnapEnabled: Bool {
        get { appState.isTimelineSnapEnabled }
        nonmutating set { appState.isTimelineSnapEnabled = newValue }
    }

    private var isOnionSkinEnabled: Bool {
        get { appState.isTimelineOnionSkinEnabled }
        nonmutating set { appState.isTimelineOnionSkinEnabled = newValue }
    }

    /// The timeline's two views of the same clip. The graph used to be a panel
    /// that opened UNDER the timeline, taking ~190pt off the rows you were
    /// reading — on a 420pt timeline that is 46% of it — and reserving a blank
    /// column the width of the track labels so its plot lined up with them.
    /// As a tab, one pane is drawn at a time and the plot gets the full height.
    private enum TimelineTab: String, CaseIterable {
        case dopeSheet
        case graph

        var title: String {
            switch self {
            case .dopeSheet: return "Dope Sheet"
            case .graph:     return "Graph"
            }
        }

        var icon: String {
            switch self {
            case .dopeSheet: return "rectangle.grid.1x2"
            case .graph:     return "chart.xyaxis.line"
            }
        }
    }

    /// Backed by the flag that was already persisted, so no project migrates:
    /// both of its values are a real tab.
    private var timelineTab: TimelineTab {
        get { appState.isTimelineGraphVisible ? .graph : .dopeSheet }
        nonmutating set { appState.isTimelineGraphVisible = (newValue == .graph) }
    }

    private var selectedTrackID: String? {
        get { appState.timelineSelectedTrackID }
        nonmutating set { appState.timelineSelectedTrackID = newValue }
    }

    private var selectedFilter: TimelineFilter {
        get { TimelineFilter(rawValue: appState.timelineSelectedFilterRawValue) ?? .all }
        nonmutating set { appState.timelineSelectedFilterRawValue = newValue.rawValue }
    }

    private var zoomScale: CGFloat {
        get { CGFloat(appState.timelineZoomScale) }
        nonmutating set { appState.timelineZoomScale = Double(newValue) }
    }

    private var zoomScaleBinding: Binding<CGFloat> {
        Binding(
            get: { zoomScale },
            set: { zoomScale = $0 }
        )
    }

    private var selectedGraphChannelID: String? {
        get { appState.timelineSelectedGraphChannelID }
        nonmutating set { appState.timelineSelectedGraphChannelID = newValue }
    }

    private var selectedImage: SceneImage? {
        guard let selectedID = sceneManager.selectedImageID else { return nil }
        return sceneManager.image(for: selectedID)
    }

    private var selectedBone: Bone? {
        guard let selectedID = sceneManager.selectedBoneID else { return nil }
        return sceneManager.skeleton.bones[selectedID]
    }

    /// The constraint the inspector currently has open, if any. Constraints are
    /// animation targets in their own right: their properties live on the scene
    /// clip rather than on a bone or a sprite.
    private var selectedConstraint: (id: UUID, kind: ConstraintKind, name: String)? {
        guard let id = sceneManager.selectedConstraintID,
              let kind = sceneManager.skeleton.constraintKind(for: id),
              let name = sceneManager.skeleton.constraintName(for: id) else { return nil }
        return (id, kind, name)
    }

    private var selectedAnimationTargetID: UUID? {
        selectedImage?.id ?? selectedBone?.id ?? selectedConstraint?.id
    }

    /// Owner of a given row, read OFF THE ROW.
    ///
    /// This used to answer `selectedAnimationTargetID` for every non-scene row.
    /// That was right while the only rows on screen belonged to the selected
    /// object; now that every animated object is listed it would be a silent
    /// write to the wrong one — clicking a key on Bone 2's Rotate row would
    /// move a key on whichever bone happened to be selected. Every row built by
    /// `trackRowID` carries its target's UUID, so the row answers for itself.
    private func targetID(for track: FlattenedTimelineTrack) -> UUID? {
        guard let property = propertyForTrack(track) else { return nil }
        // Draw order has one fixed scene target; every other row — bone, image,
        // constraint, event — names its own.
        if property == .drawOrder { return SceneAnimationTarget.drawOrder }
        return rowTargetID(from: track.node.id)
    }

    /// Recover the target UUID a row was built with.
    private func rowTargetID(from rowID: String) -> UUID? {
        guard let uuidString = rowID.split(separator: ".").last else { return nil }
        return UUID(uuidString: String(uuidString))
    }

    /// Owner of the row the artist has selected, used by the graph editor and
    /// every keyframe operation driven from the selected row.
    /// Owner of the row the artist has selected — the graph plots this.
    ///
    /// Same correction as `targetID(for:)`: it answered the selected OBJECT for
    /// a transform row, which would now plot Bone 5's curve while Bone 2's
    /// Rotate row is the one lit up. The selected row names its own target.
    private var selectedTrackTargetID: UUID? {
        guard let property = selectedTrackProperty else { return nil }
        if property == .drawOrder { return SceneAnimationTarget.drawOrder }
        guard let selectedTrackID else { return selectedAnimationTargetID }
        return rowTargetID(from: selectedTrackID) ?? selectedAnimationTargetID
    }

    private var selectedAnimationTargetName: String? {
        selectedImage?.name ?? selectedBone?.name ?? selectedConstraint?.name
    }

    private var selectedAnimationClip: AnimationClip? {
        if let clip = selectedImage?.animationClip { return clip }
        if let clip = selectedBone?.animationClip { return clip }
        if selectedConstraint != nil { return sceneManager.sceneAnimationClip }
        return nil
    }

    private var selectedAnimationTargetKindTitle: String {
        if selectedImage != nil {
            return "Image"
        }
        if selectedBone != nil {
            return "Bone"
        }
        if let kind = selectedConstraint?.kind {
            return "\(kind.title) Constraint"
        }
        return "Object"
    }

    private var clipName: String {
        selectedAnimationTargetName.map { "\($0) Clip" } ?? "No Clip Selected"
    }

    private var frameStep: Int {
        zoomScale < 0.85 ? 10 : (zoomScale > 1.7 ? 1 : 5)
    }

    /// How far the ruler and the content width reach.
    ///
    /// This used to be the SELECTED object's clip duration. Now that every
    /// animated object is listed, a key past that duration fell outside the
    /// content width entirely — off the end of the scrollable area, so the row
    /// was drawn but its keys could never be reached. The span has to cover
    /// every object the timeline lists.
    /// The frame the timeline is showing: the scrub in flight, or the model.
    ///
    /// Reading the model rather than mirroring it is what removes the second
    /// render per animated frame — and it cannot go stale, which the mirror
    /// copy could and did whenever a guard excluded a case.
    private var currentFrame: Double {
        scrubFrame ?? Double(sceneManager.currentFrame)
    }

    private var totalFrames: Int {
        max(90, animatedFrameSpan, workEndFrame)
    }

    /// The last frame any listed object holds a key on.
    private var animatedFrameSpan: Int {
        var span = selectedAnimationClip?.durationInFrames ?? 0
        for row in flattenedTracks where row.node.kind == .track {
            if let last = row.node.frames?.max() {
                span = max(span, last)
            }
        }
        return span
    }

    private var workStartFrame: Int {
        sceneManager.playbackStartFrame
        
    }

    private var workEndFrame: Int {
        sceneManager.playbackEndFrame
    }

    private var contentWidth: CGFloat {
        CGFloat(totalFrames) * frameSpacing * zoomScale
    }

    /// Stable row identifier that also carries the property, so the timeline can
    /// resolve a row back to its track without matching on the display title
    /// (two constraint types both label a property "Rotate Mix").
    private func trackRowID(_ property: AnimationTrackProperty, _ targetID: UUID) -> String {
        "track.prop.\(property.rawValue).\(targetID.uuidString)"
    }

    private func tint(for property: AnimationTrackProperty) -> Color {
        switch property {
        case .translate:  return palette.transform
        case .rotate:     return palette.rotation
        case .scale:      return palette.scale
        case .shear:      return palette.skew
        case .meshDeform: return palette.deform
        case .drawOrder:  return palette.attachment
        case .event:      return palette.event
        default:          return palette.constraint
        }
    }

    /// Every object the clip animates, each under a row that names it.
    ///
    /// This used to build ONE group, for the selected object. A rig with eight
    /// keyed bones showed one of them and hid the rest, and the views then
    /// filtered the group rows out too, so the four rows that were left said
    /// `Translate / Rotate / Scale / Shear` with nothing saying whose.
    ///
    /// An object earns a place by holding a key, or by being selected — so the
    /// first key on a fresh bone still has somewhere to land. Document order,
    /// never selection order: a list that rearranges under a finger that is
    /// already dragging is worse than a short one.
    private var trackTree: [TimelineTrackNode] {
        var groups: [TimelineTrackNode] = []

        if let constraint = selectedConstraint, selectedImage == nil, selectedBone == nil,
           let constraintGroup = objectGroup(
               targetID: constraint.id,
               name: constraint.name,
               subtitle: "\(constraint.kind.title) constraint",
               tint: palette.constraint,
               clip: sceneManager.sceneAnimationClip,
               candidateProperties: constraint.kind.animatableProperties,
               isSelected: true
           ) {
            groups.append(constraintGroup)
        }

        // Bones in hierarchy order — `Skeleton.orderedBones` walks a dictionary,
        // whose order is not stable between runs.
        for entry in IKBuilderRules.hierarchicalOrder(skeleton: sceneManager.skeleton) {
            let bone = entry.bone
            guard let group = objectGroup(
                targetID: bone.id,
                name: bone.name,
                subtitle: nil,
                tint: palette.bone,
                clip: bone.animationClip,
                // Bones carry transform tracks but never mesh deform.
                candidateProperties: AnimationTrackProperty.nodeProperties.filter { $0 != .meshDeform },
                isSelected: bone.id == selectedAnimationTargetID
            ) else { continue }
            groups.append(group)
        }

        for image in sceneManager.images {
            guard let group = objectGroup(
                targetID: image.id,
                name: image.name,
                subtitle: nil,
                tint: palette.object,
                clip: image.animationClip,
                candidateProperties: AnimationTrackProperty.nodeProperties,
                isSelected: image.id == selectedAnimationTargetID
            ) else { continue }
            groups.append(group)
        }

        // Draw order is scene-wide: it is shown whenever it holds keys, or while
        // animating so the artist can create the first one: the Draw Order row
        // is permanent rather than appearing only once it holds a key.
        let drawOrderFrames = sceneManager.sceneAnimationClip.frameNumbers(
            for: SceneAnimationTarget.drawOrder,
            property: .drawOrder
        )
        if !drawOrderFrames.isEmpty || sceneManager.isAnimationEditingEnabled {
            groups.append(
                TimelineTrackNode(
                    id: "group.scene.draworder",
                    title: "Scene",
                    subtitle: nil,
                    tint: palette.attachment,
                    kind: .group,
                    children: [
                        .track(
                            id: trackRowID(.drawOrder, SceneAnimationTarget.drawOrder),
                            title: AnimationTrackProperty.drawOrder.title,
                            tint: palette.attachment,
                            frames: drawOrderFrames
                        )
                    ]
                )
            )
        }

        // Attachments: one row per SLOT that holds keys, plus every multi-sprite
        // slot while animating so the first key can be made from the timeline
        // rather than only from the inspector. A slot of one sprite is not a
        // choice and gets no row.
        var attachmentRows: [TimelineTrackNode] = []
        for slotName in sceneManager.slotNames {
            let target = SlotAnimationTarget.id(forSlotNamed: slotName)
            let frames = sceneManager.sceneAnimationClip.frameNumbers(
                for: target, property: .attachment
            )
            let isChoice = sceneManager.attachments(inSlot: slotName).count > 1
            guard !frames.isEmpty || (isChoice && sceneManager.isAnimationEditingEnabled) else {
                continue
            }
            attachmentRows.append(
                .track(
                    id: trackRowID(.attachment, target),
                    title: slotName,
                    tint: palette.attachment,
                    frames: frames
                )
            )
        }
        if !attachmentRows.isEmpty {
            groups.append(
                TimelineTrackNode(
                    id: "group.scene.attachments",
                    title: "Attachments",
                    subtitle: nil,
                    tint: palette.attachment,
                    kind: .group,
                    children: attachmentRows
                )
            )
        }

        // Events are scene-wide like draw order: one row per event definition
        // that has keys, plus every definition while animating so the artist can
        // place the first one.
        let eventDefinitions = sceneManager.isAnimationEditingEnabled
            ? sceneManager.animationEvents
            : sceneManager.animationEvents.filter { definition in
                !sceneManager.sceneAnimationClip
                    .frameNumbers(for: definition.id, property: .event).isEmpty
            }

        if !eventDefinitions.isEmpty {
            groups.append(
                TimelineTrackNode(
                    id: "group.scene.events",
                    title: "Events",
                    subtitle: nil,
                    tint: palette.event,
                    kind: .group,
                    children: eventDefinitions.map { definition in
                        .track(
                            id: trackRowID(.event, definition.id),
                            title: definition.name,
                            tint: palette.event,
                            frames: sceneManager.sceneAnimationClip
                                .frameNumbers(for: definition.id, property: .event)
                        )
                    }
                )
            )
        }

        guard !groups.isEmpty else { return [] }

        return [
            TimelineTrackNode(
                id: "group.animation.root",
                title: "animation",
                subtitle: nil,
                tint: palette.accent,
                kind: .group,
                children: groups
            )
        ]
    }

    /// One object's group, or nil when it has earned no place on the timeline.
    ///
    /// The SELECTED object shows all of its channels, so a channel with no key
    /// yet still has a row to key into. Every other object shows only what it
    /// actually holds — four rows times every bone in the rig is a list nobody
    /// can read.
    private func objectGroup(
        targetID: UUID,
        name: String,
        subtitle: String?,
        tint: Color,
        clip: AnimationClip,
        candidateProperties: [AnimationTrackProperty],
        isSelected: Bool
    ) -> TimelineTrackNode? {
        var rows: [TimelineTrackNode] = []
        for property in candidateProperties {
            let frames = clip.frameNumbers(for: targetID, property: property)
            guard isSelected || !frames.isEmpty else { continue }
            rows.append(
                .track(
                    id: trackRowID(property, targetID),
                    title: property.title,
                    tint: self.tint(for: property),
                    frames: frames
                )
            )
        }

        guard !rows.isEmpty else { return nil }

        return TimelineTrackNode(
            id: objectGroupID(targetID),
            title: name,
            subtitle: subtitle,
            tint: tint,
            kind: .group,
            children: rows
        )
    }

    private func objectGroupID(_ targetID: UUID) -> String {
        "group.object.\(targetID.uuidString)"
    }

    /// "3 objects · 14 keys" — what the list is actually showing.
    private var animatedObjectSummary: String {
        let groups = flattenedTracks.filter { $0.node.kind == .group }
        guard !groups.isEmpty else { return "No animated objects" }
        let keys = groups.reduce(0) { $0 + groupKeyCount($1) }
        let objects = groups.count == 1 ? "1 object" : "\(groups.count) objects"
        let keyText = keys == 1 ? "1 key" : "\(keys) keys"
        return "\(objects) · \(keyText)"
    }

    /// Selecting a bone or an image on the canvas takes the timeline to it.
    ///
    /// Two things were wrong without this. The object could be anywhere in a
    /// list of twelve, with no indication of where — and the GRAPH follows the
    /// selected ROW, which stayed on the object you had just left, so picking
    /// Bone 16 kept plotting Bone 11's curve.
    ///
    /// The scroll is the least that brings the object's row into the body. An
    /// object already on screen does not move the list: a timeline that jumps
    /// under a finger that is already dragging is worse than one that does not
    /// follow at all.
    private func revealSelectedObject() {
        guard let targetID = selectedAnimationTargetID else { return }

        collapsedTrackGroups.remove(objectGroupID(targetID))

        if let firstRow = flattenedTracks.first(where: {
            $0.node.kind == .track && rowTargetID(from: $0.node.id) == targetID
        }) {
            selectedTrackID = firstRow.node.id
        }

        guard let index = timelineRows.firstIndex(where: {
            $0.node.id == objectGroupID(targetID)
        }) else { return }

        // Before the first layout the host has not reported a size. Scrolling
        // against a height of zero would snap the list to the row's top for no
        // reason, so leave it where it is and let the next selection do it.
        guard timelineViewportSize.height > 0 else { return }
        let bodyHeight = max(timelineViewportSize.height, rowHeight)
        let top = CGFloat(index) * rowHeight
        let bottom = top + rowHeight
        var offset = timelineContentOffset.y
        if top < offset {
            offset = top
        } else if bottom > offset + bodyHeight {
            offset = bottom - bodyHeight
        } else {
            return
        }
        let maxOffset = max(timelineScrollHeight - bodyHeight, 0)
        timelineContentOffset.y = min(max(offset, 0), maxOffset)
    }

    /// The one vertical scroll position. Labels and canvas both read it; the
    /// pinned ruler reads `scrollOffsetX`.
    private var scrollOffsetY: CGFloat { timelineContentOffset.y }
    private var scrollOffsetX: CGFloat { timelineContentOffset.x }

    /// What actually scrolls: the rows, and nothing else.
    ///
    /// The scrollable height used to be the row count PADDED up to fill the
    /// viewport — right for drawing a full-height zebra, wrong as a content
    /// size, because it left somewhere to scroll to even with three rows.
    private var timelineScrollHeight: CGFloat {
        CGFloat(max(timelineRows.count, 1)) * rowHeight
    }

    /// Everything the track tree is built FROM, and nothing else.
    ///
    /// Deliberately not the playhead: the tree is identical on every tick of a
    /// playback, and rebuilding it there was the thread the playhead needed.
    /// Anything the tree reads that is missing here shows a STALE list, which
    /// is worse than a slow one — so this hashes the ids, the names and the
    /// clip revisions of every object, not a summary of them.
    private var trackTreeSignature: Int {
        var hasher = Hasher()
        hasher.combine(sceneManager.isAnimationEditingEnabled)
        hasher.combine(selectedAnimationTargetID)
        hasher.combine(selectedFilter)
        hasher.combine(collapsedTrackGroups)

        for entry in IKBuilderRules.hierarchicalOrder(skeleton: sceneManager.skeleton) {
            hasher.combine(entry.bone.id)
            hasher.combine(entry.bone.name)
            hasher.combine(entry.bone.animationClip.revision)
        }
        for image in sceneManager.images {
            hasher.combine(image.id)
            hasher.combine(image.name)
            hasher.combine(image.animationClip.revision)
        }
        hasher.combine(sceneManager.sceneAnimationClip.revision)
        for definition in sceneManager.animationEvents {
            hasher.combine(definition.id)
            hasher.combine(definition.name)
        }
        return hasher.finalize()
    }

    /// The tree, built once and reused until the signature moves.
    ///
    /// A reference type in `@State` on purpose: writing to it during a body
    /// evaluation is a plain store, not a published change, so it memoises
    /// without invalidating the view that just read it.
    private var cachedTrackTree: [TimelineTrackNode] {
        let signature = trackTreeSignature
        if trackTreeCache.signature == signature, let nodes = trackTreeCache.nodes {
            return nodes
        }
        let nodes = trackTree
        trackTreeCache.signature = signature
        trackTreeCache.nodes = nodes
        return nodes
    }

    private var flattenedTracks: [FlattenedTimelineTrack] {
        cachedTrackTree.flatMap { flatten(node: $0, depth: 0) }
    }

    private var visibleTracks: [FlattenedTimelineTrack] {
        // A group row survives whenever one of its own rows does. Filtering
        // groups out on their own merits would leave property rows floating
        // with nothing naming their object — the fault this list just fixed.
        let kept = flattenedTracks.filter { $0.node.kind != .group && passesFilter($0) }
        let keptIDs = Set(kept.map { $0.id })
        return flattenedTracks.filter { track in
            guard track.node.kind == .group else { return keptIDs.contains(track.id) }
            return track.node.children.contains { child in
                keptIDs.contains(child.id)
            }
        }
    }

    private func passesFilter(_ track: FlattenedTimelineTrack) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .keyed:
            return !(track.node.frames?.isEmpty ?? true)
        case .transforms:
            return track.node.id.contains("translate") || track.node.id.contains("rotate") || track.node.id.contains("scale") || track.node.id.contains("shear")
        case .selected:
            guard let selectedTrackID else { return false }
            return track.node.id == selectedTrackID
        case .events:
            return track.node.id.contains("event") || track.node.id.contains("audio")
                || track.node.id.contains(AnimationTrackProperty.event.rawValue)
        }
    }

    /// The rows the timeline actually draws, group rows included.
    ///
    /// This filtered `kind == .track` and threw the group rows away — which is
    /// why `trackTree` built a node carrying each object's name and the artist
    /// never saw one. Labels, canvas and rubber-band hit-testing all walk this
    /// one list, so their row indices cannot drift apart.
    private var timelineRows: [FlattenedTimelineTrack] {
        var rows: [FlattenedTimelineTrack] = []
        var skippingChildrenOf: Int?
        for row in visibleTracks {
            if let depth = skippingChildrenOf {
                if row.depth > depth { continue }
                skippingChildrenOf = nil
            }
            rows.append(row)
            if row.node.kind == .group, collapsedTrackGroups.contains(row.node.id) {
                // The group itself always stays, or it could not be reopened.
                skippingChildrenOf = row.depth
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            compactTransportBar
            timelineTabBar
            mainArea
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(palette.separator, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 6)
        }
        .onAppear {
            isLoopEnabled = sceneManager.playbackLoops
        }
        .onChange(of: isLoopEnabled) { _, newValue in
            sceneManager.playbackLoops = newValue
        }
        .onChange(of: selectedAnimationTargetID) { _, _ in
            revealSelectedObject()
        }
        .focusable()
        .focusEffectDisabled()
#if os(macOS)
        .onDeleteCommand {
            sceneManager.deleteSelectedKeyframes()
        }
        .onCopyCommand {
            sceneManager.copySelectedKeyframes()
        }
        .onPasteCommand(of: [UTType.plainText]) { _ in
            sceneManager.pasteCopiedKeyframes()
        }
        .onCommand(Selector(("duplicate:"))) {
            sceneManager.duplicateSelectedKeyframes()
        }
#endif
    }

    // MARK: - Compact Transport Bar

    private var compactTransportBar: some View {
        HStack(spacing: 10) {
            transportControls

            barSeparator

            keyPoseButton

            barSeparator

            keyframeOpsBar

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                barToggleButton(icon: "repeat", active: isLoopEnabled) {
                    isLoopEnabled.toggle()
                }
            }

            barSeparator

            frameRatePill

            barSeparator

            frameRangePill

            barSeparator

            CapsuleSlider(
                value: Binding(get: { Double(zoomScale) }, set: { zoomScale = CGFloat($0) }),
                in: 0.7...2.2
            )
            .frame(width: 110)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(UM.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(UM.textPrimary.opacity(0.07), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(UM.appBackground)
    }

    /// Project frame rate — a document property, not a per-clip one. Editing it retimes
    /// playback immediately and updates the timecode readout; it does not move
    /// or rescale any keyframe, which stay on their frame numbers.
    private var frameRatePill: some View {
        HStack(spacing: 6) {
            Text("FPS")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.38))
                .tracking(0.8)

            Menu {
                ForEach([24.0, 25.0, 30.0, 48.0, 50.0, 60.0, 120.0], id: \.self) { rate in
                    Button {
                        sceneManager.projectFramesPerSecond = rate
                    } label: {
                        HStack {
                            Text("\(Int(rate)) fps")
                            if abs(sceneManager.projectFramesPerSecond - rate) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("\(Int(sceneManager.projectFramesPerSecond.rounded()))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UM.textPrimary.opacity(0.90))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.38))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Text(timecodeText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(UM.textPrimary.opacity(0.42))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(UM.textPrimary.opacity(0.05))
        )
    }

    /// Playhead position as seconds at the project rate, e.g. "1.20s".
    private var timecodeText: String {
        String(format: "%.2fs", sceneManager.timecode(forFrame: sceneManager.currentFrame))
    }

    private var clipInfoPill: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLIP")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(0.38))
                    .tracking(0.8)
                HStack(spacing: 4) {
                    Text(clipName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.90))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.38))
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(red: 0.36, green: 0.92, blue: 0.52))
                        .frame(width: 5, height: 5)
                    Text(selectedAnimationTargetID == nil ? "No selection" : "Tracks · 1 clip")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UM.textPrimary.opacity(0.38))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            barIconButton(icon: "backward.end.fill") {
                sceneManager.stepFrames(-1, lowerBound: workStartFrame, upperBound: workEndFrame)
            }
            Button {
                sceneManager.togglePlayback(looping: isLoopEnabled, lowerBound: workStartFrame, upperBound: workEndFrame)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                    Image(systemName: sceneManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.black)
                        .offset(x: sceneManager.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            barIconButton(icon: "forward.end.fill") {
                sceneManager.stepFrames(1, lowerBound: workStartFrame, upperBound: workEndFrame)
            }
        }
    }

    private var frameRangePill: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FRAME RANGE")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(UM.textPrimary.opacity(0.38))
                .tracking(0.8)
            HStack(spacing: 8) {
                TextField("0", value: Binding(
                    get: { workStartFrame },
                    set: { v in
                        let s = min(max(v, 0), totalFrames)
                        sceneManager.setPlaybackRange(start: s, end: max(workEndFrame, s))
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(UM.textPrimary.opacity(0.85))
                .frame(width: 36)
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(UM.textPrimary.opacity(0.25))
                TextField("90", value: Binding(
                    get: { workEndFrame },
                    set: { v in
                        let e = min(max(v, workStartFrame), totalFrames)
                        sceneManager.setPlaybackRange(start: workStartFrame, end: e)
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(UM.textPrimary.opacity(0.85))
                .frame(width: 36)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    /// Capture the selected bone or sprite's pose at the playhead.
    ///
    /// The button is the diamond it creates, in the colour of the channel the
    /// press would write — so what is about to happen is legible before you
    /// touch it.
    ///
    /// Three states, because a frame is often PARTLY keyed: a rotate drag left
    /// `.rotate` here and nothing else. A hollow diamond says nothing is keyed,
    /// a cored one says some of it is, a solid one says all of it. Pressing on
    /// a partial completes the key rather than clearing it, so the channel the
    /// artist already had is never lost.
    private var keyPoseButton: some View {
        let state = sceneManager.transformKeyState()
        let enabled = sceneManager.isAnimationEditingEnabled
            && !sceneManager.transformKeyTargets.isEmpty
        let fill: KeyframeDiamondIcon.Fill
        switch state {
        case .none:    fill = .hollow
        case .partial: fill = .core
        case .full:    fill = .solid
        }

        return Button {
            // Only confirm a press that actually wrote something: animating a
            // refusal would say the opposite of what happened.
            guard sceneManager.toggleTransformKey() else { return }
            keyPressCount &+= 1
            PlatformFeedback.lightImpact()
        } label: {
            KeyframeDiamondIcon(
                color: keyButtonTint,
                fill: fill,
                isEnabled: enabled,
                pressCount: keyPressCount
            )
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .none
                          ? UM.textPrimary.opacity(0.055)
                          : keyButtonTint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(state == .none ? Color.clear : keyButtonTint.opacity(0.35),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(keyPoseHelp(state: state, enabled: enabled))
    }

    /// The colour of the channel this press would write.
    ///
    /// Read from the same list the press iterates, so the diamond cannot show
    /// one channel while the key lands on another. With no transform tool in
    /// hand the press covers all four, and no single colour is honest — the
    /// neutral ink says "the whole transform".
    private var keyButtonTint: Color {
        let channels = sceneManager.activeTransformKeyProperties
        guard channels.count == 1, let color = UM.channelColor(for: channels[0]) else {
            return UM.textPrimary.opacity(0.68)
        }
        return color
    }

    private func keyPoseHelp(state: SceneManager.TransformKeyState, enabled: Bool) -> String {
        guard enabled else {
            return sceneManager.isAnimationEditingEnabled
                ? "Select a bone or an image to key it"
                : "Keying is only available in Animator"
        }
        // Name the channel, so it is never a surprise which one the key wrote.
        let channels = sceneManager.activeTransformKeyProperties
        let what = channels.count == 1 ? channels[0].title.lowercased() : "pose"
        switch state {
        case .none:    return "Key the \(what) at this frame"
        case .partial: return "Complete the \(what) key at this frame"
        case .full:    return "Remove the \(what) key at this frame"
        }
    }

    private var keyframeOpsBar: some View {
        let hasSel = !sceneManager.selectedKeyframes.isEmpty
        let hasCopy = !sceneManager.copiedKeyframes.isEmpty
        return HStack(spacing: 2) {
            barIconButton(icon: "scissors", enabled: hasSel) {
                _ = sceneManager.copySelectedKeyframes()
                sceneManager.deleteSelectedKeyframes()
            }
            barIconButton(icon: "doc.on.doc", enabled: hasSel) {
                _ = sceneManager.copySelectedKeyframes()
            }
            barIconButton(icon: "doc.on.clipboard", enabled: hasCopy) {
                sceneManager.pasteCopiedKeyframes()
            }
            barIconButton(icon: "trash", enabled: hasSel) {
                sceneManager.deleteSelectedKeyframes()
            }
        }
    }

    private var barSeparator: some View {
        Rectangle()
            .fill(UM.textPrimary.opacity(0.09))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func barIconButton(icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? UM.textPrimary.opacity(0.68) : UM.textPrimary.opacity(0.22))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(UM.textPrimary.opacity(0.055))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func barToggleButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? UM.textPrimary.opacity(0.92) : UM.textPrimary.opacity(0.38))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? UM.textPrimary.opacity(0.12) : UM.textPrimary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(active ? UM.textPrimary.opacity(0.18) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var timelineContainer: some View {
        VStack(spacing: 0) {
            topBar
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(palette.separator)
            mainArea
        }
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(clipName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.middle)
                    Text(selectedAnimationTargetID == nil ? "Select an object to start animating" : "\(selectedAnimationTargetKindTitle) animation ready • One clip")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.separator, lineWidth: 1)
            )
            .layoutPriority(1)

            Spacer(minLength: 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TransportButton(systemImage: "backward.end.fill") {
                        sceneManager.stepFrames(-1, lowerBound: workStartFrame, upperBound: workEndFrame)
                    }
                    TransportButton(
                        systemImage: sceneManager.isPlaying ? "pause.fill" : "play.fill",
                        isProminent: true
                    ) {
                        sceneManager.togglePlayback(looping: isLoopEnabled, lowerBound: workStartFrame, upperBound: workEndFrame)
                    }
                    TransportButton(systemImage: "forward.end.fill") {
                        sceneManager.stepFrames(1, lowerBound: workStartFrame, upperBound: workEndFrame)
                    }

                    keyframeClipboardBar

                    playbackRangePicker
                    unitPicker
                    toggleChip(title: "Snap", isOn: isSnapEnabled, tint: palette.loop) { isSnapEnabled.toggle() }
                    toggleChip(title: "Loop", isOn: isLoopEnabled, tint: palette.accent) { isLoopEnabled.toggle() }
                    toggleChip(title: "Onion", isOn: isOnionSkinEnabled, tint: palette.onion) { isOnionSkinEnabled.toggle() }
                    toggleChip(title: "Graph", isOn: timelineTab == .graph, tint: palette.graph) {
                        timelineTab = timelineTab == .graph ? .dopeSheet : .graph
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                        CapsuleSlider(
                            value: Binding(get: { Double(zoomScaleBinding.wrappedValue) },
                                           set: { zoomScaleBinding.wrappedValue = CGFloat($0) }),
                            in: 0.7...2.2
                        )
                        .frame(width: 120)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(palette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.separator, lineWidth: 1)
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [
                    palette.panel.opacity(0.30),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var keyframeClipboardBar: some View {
        let hasSelection = !sceneManager.selectedKeyframes.isEmpty
        let hasCopied = !sceneManager.copiedKeyframes.isEmpty

        return HStack(spacing: 2) {
            clipboardButton(systemImage: "scissors", enabled: hasSelection) {
                _ = sceneManager.copySelectedKeyframes()
                sceneManager.deleteSelectedKeyframes()
            }
            clipboardButton(systemImage: "doc.on.doc", enabled: hasSelection) {
                _ = sceneManager.copySelectedKeyframes()
            }
            clipboardButton(systemImage: "doc.on.clipboard", enabled: hasCopied) {
                sceneManager.pasteCopiedKeyframes()
            }
            clipboardButton(systemImage: "trash", enabled: hasSelection) {
                sceneManager.deleteSelectedKeyframes()
            }
        }
        .padding(3)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private func clipboardButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? palette.primaryText : palette.tertiaryText)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(enabled ? UM.textPrimary.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var interpolationPicker: some View {
        let selectionCount = sceneManager.selectedKeyframes.count
        let selectedInterpolation = sceneManager.selectedKeyframeInterpolation()

        return HStack(spacing: 3) {
            ForEach(KeyframeInterpolation.allCases, id: \.rawValue) { interpolation in
                Button {
                    sceneManager.setInterpolationForSelectedKeyframes(interpolation)
                } label: {
                    Text(interpolationChipTitle(for: interpolation))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(interpolationChipTextColor(for: interpolation, selectedInterpolation: selectedInterpolation))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(interpolationChipBackground(for: interpolation, selectedInterpolation: selectedInterpolation))
                        )
                }
                .buttonStyle(.plain)
                .disabled(selectionCount == 0)
            }
        }
        .padding(3)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
        .opacity(selectionCount == 0 ? 0.55 : 1)
        .overlay(alignment: .bottomTrailing) {
            if selectionCount > 1, selectedInterpolation == nil {
                Text("Mixed")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.background.opacity(0.92))
                    .clipShape(Capsule())
                    .offset(x: 8, y: 10)
            }
        }
    }

    private var playbackRangePicker: some View {
        HStack(spacing: 8) {
            playbackRangeField(title: "Start", value: Binding(
                get: { workStartFrame },
                set: { newValue in
                    let clampedStart = min(max(newValue, 0), totalFrames)
                    let clampedEnd = max(sceneManager.playbackEndFrame, clampedStart)
                    sceneManager.setPlaybackRange(start: clampedStart, end: clampedEnd)
                }
            ))

            playbackRangeField(title: "End", value: Binding(
                get: { workEndFrame },
                set: { newValue in
                    let clampedEnd = min(max(newValue, workStartFrame), totalFrames)
                    sceneManager.setPlaybackRange(start: workStartFrame, end: clampedEnd)
                }
            ))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private func playbackRangeField(title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            TextField(title, value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .frame(width: 56)
        }
    }

    private var unitPicker: some View {
        HStack(spacing: 2) {
            ForEach(TimelineUnitMode.allCases) { mode in
                Button {
                    unitMode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(unitMode == mode ? palette.primaryText : palette.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(unitMode == mode ? palette.accent.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private var mainArea: some View {
        if timelineTab == .graph {
            AnyView(
                HStack(alignment: .top, spacing: 0) {
                    graphTrackColumn
                    paneSeparator
                    graphPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.background)
            )
        } else {
            AnyView(timelineBody)
        }
    }

    /// The dope sheet: names and keyframes in ONE scrolling surface.
    ///
    /// They used to be two — the grid in a scroll view, the name column copying
    /// its offset through SwiftUI state with `.offset(y:)`. Two surfaces kept in
    /// step by a state round-trip can only ever be approximately in step: the
    /// copy lands a frame late and coalesces under a flick, and the names area
    /// was not a scroll surface at all, so a drag that started there went to
    /// whichever ancestor would take it. One surface cannot disagree with
    /// itself; there is no gain to calibrate and no latency to chase.
    ///
    /// The names stay put sideways the way a spreadsheet freezes its first
    /// column: they cancel the horizontal scroll, and only that.
    private var timelineBody: some View {
        Group {
            if visibleTracks.isEmpty {
                emptyTimelineState
            } else {
                GeometryReader { geometry in
                    let bodyHeight = max(geometry.size.height - TimelineMetrics.headerHeight, rowHeight)
                    let gridWidth = contentWidth + 24 + contentLeadingInset
                    let contentSize = CGSize(width: TimelineMetrics.gridLeadingInset + gridWidth,
                                             height: timelineScrollHeight)
                    let maxHorizontalOffset = max(contentSize.width - geometry.size.width, 0)
                    let maxVerticalOffset = max(contentSize.height - bodyHeight, 0)
                    let horizontalTrackWidth = max(geometry.size.width - 8, 1)
                    let verticalTrackHeight = max(bodyHeight - 8, 1)
                    let horizontalThumbWidth = max(min((geometry.size.width / max(contentSize.width, 1)) * horizontalTrackWidth, horizontalTrackWidth), 36)
                    let verticalThumbHeight = max(min((bodyHeight / max(contentSize.height, 1)) * verticalTrackHeight, verticalTrackHeight), 36)
                    let horizontalTravel = max(horizontalTrackWidth - horizontalThumbWidth, 0)
                    let verticalTravel = max(verticalTrackHeight - verticalThumbHeight, 0)
                    let horizontalProgress = maxHorizontalOffset > 0 ? scrollOffsetX / maxHorizontalOffset : 0
                    let verticalProgress = maxVerticalOffset > 0 ? scrollOffsetY / maxVerticalOffset : 0

                    VStack(spacing: 0) {
                        // The pinned header, in the same two columns as the body
                        // below it: names heading over the names, ruler over the
                        // grid.
                        HStack(spacing: 0) {
                            tracksHeader
                                .frame(width: timelineLabelsWidth)
                            paneSeparator
                            pinnedRuler(width: gridWidth)
                        }
                        .frame(height: TimelineMetrics.headerHeight)

                        ZStack(alignment: .topLeading) {
                            TimelineScrollHost(
                                contentOffset: $timelineContentOffset,
                                viewportSize: $timelineViewportSize,
                                contentSize: contentSize
                            ) {
                                ZStack(alignment: .topLeading) {
                                    keyframeGrid(width: gridWidth)
                                        .offset(x: TimelineMetrics.gridLeadingInset)

                                    stickyLabelColumn
                                }
                                .frame(width: contentSize.width,
                                       height: contentSize.height,
                                       alignment: .topLeading)
                            }

                            Capsule()
                                .fill(UM.textPrimary.opacity(0.72))
                                .frame(width: horizontalThumbWidth, height: 4)
                                .offset(x: 4 + (horizontalTravel * horizontalProgress), y: bodyHeight - 8)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let proposed = min(max(value.location.x - (horizontalThumbWidth * 0.5), 0), horizontalTravel)
                                            let progress = horizontalTravel > 0 ? proposed / horizontalTravel : 0
                                            timelineContentOffset.x = progress * maxHorizontalOffset
                                        }
                                )

                            if maxVerticalOffset > 0 {
                                Capsule()
                                    .fill(UM.textPrimary.opacity(0.72))
                                    .frame(width: 4, height: verticalThumbHeight)
                                    .offset(x: geometry.size.width - 8, y: 4 + (verticalTravel * verticalProgress))
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let proposed = min(max(value.location.y - (verticalThumbHeight * 0.5), 0), verticalTravel)
                                                let progress = verticalTravel > 0 ? proposed / verticalTravel : 0
                                                timelineContentOffset.y = progress * maxVerticalOffset
                                            }
                                    )
                            }
                        }
                        .frame(height: bodyHeight, alignment: .top)
                        .clipped()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(palette.background)
                    // Drawn over both, because the head lives in the ruler and
                    // the line in the body: one view, so they cannot disagree
                    // about which frame they are on.
                    .overlay(alignment: .topLeading) {
                        PlayheadView(
                            clock: sceneManager.playheadClock,
                            xForFrame: { frame in
                                TimelineMetrics.gridLeadingInset + framePosition(frame) - scrollOffsetX
                            },
                            leftEdge: TimelineMetrics.gridLeadingInset,
                            bodyHeight: bodyHeight,
                            isScrubbing: isScrubbing,
                            label: { timelineLabel(for: $0) },
                            onDrag: { translation in
                                beginScrubIfNeeded()
                                scrub(byPoints: translation)
                            },
                            onDragEnded: { endScrub() }
                        )
                        .allowsHitTesting(true)
                    }
                }
            }
        }
    }

    /// The keyframe half of the surface. Its local origin is row 0, frame 0, so
    /// `framePosition` and `rowIndex * rowHeight` describe it directly — which
    /// is what the rubber band's arithmetic has always assumed.
    private func keyframeGrid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            timelineRowBands(height: timelineScrollHeight)
            timelineGrid(height: timelineScrollHeight)

            LazyVStack(spacing: 0) {
                ForEach(Array(timelineRows.enumerated()), id: \.element.id) { index, track in
                    timelineRow(for: track, rowIndex: index)
                }
            }

            if let selectionRect = currentSelectionRect {
                Rectangle()
                    .fill(palette.accent.opacity(0.14))
                    .overlay(
                        Rectangle()
                            .stroke(palette.accent.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .offset(x: selectionRect.minX, y: selectionRect.minY)
            }
        }
        .frame(width: width, height: timelineScrollHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(selectionBoxGesture)
    }

    /// The frozen name column. Inside the scrolling surface, so it moves
    /// vertically with the rows for free; it cancels the horizontal scroll so
    /// it stays at the left edge.
    private var stickyLabelColumn: some View {
        VStack(spacing: 0) {
            ForEach(Array(timelineRows.enumerated()), id: \.element.id) { index, track in
                timelineLabelRow(for: track, rowIndex: index)
            }
        }
        .frame(width: timelineLabelsWidth, alignment: .leading)
        .background(palette.background)
        .overlay(
            Rectangle()
                .fill(palette.separator)
                .frame(width: 1),
            alignment: .trailing
        )
        .offset(x: scrollOffsetX)
    }

    private var tracksHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tracks")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text(animatedObjectSummary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if !collapsedTrackGroups.isEmpty {
                Button {
                    collapsedTrackGroups.removeAll()
                } label: {
                    Image(systemName: "chevron.down.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Expand every object")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: TimelineMetrics.headerHeight)
        .background(palette.panel)
    }

    private var paneSeparator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: 1)
    }

    private var timelineTabBar: some View {
        HStack(spacing: 4) {
            ForEach(TimelineTab.allCases, id: \.self) { tab in
                let isCurrent = timelineTab == tab
                Button {
                    timelineTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isCurrent ? UM.textPrimary : UM.textPrimary.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isCurrent ? UM.textPrimary.opacity(0.10) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isCurrent ? UM.textPrimary.opacity(0.16) : Color.clear,
                                    lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    /// The track list for the Graph tab.
    ///
    /// It scrolls on its own rather than following `timelineContentOffset`:
    /// nothing drives that offset while the dope sheet is not on screen, so
    /// rows scrolled out of view would have had no way back.
    private var graphTrackColumn: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tracks")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(clipName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: TimelineMetrics.headerHeight)
            .background(palette.panel)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(timelineRows.enumerated()), id: \.element.id) { index, track in
                        timelineLabelRow(for: track, rowIndex: index)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: timelineLabelsWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
    }

    @ViewBuilder
    private func timelineLabelRow(for track: FlattenedTimelineTrack, rowIndex: Int) -> some View {
        let isGroup = track.node.kind == .group
        let isCollapsed = collapsedTrackGroups.contains(track.node.id)

        HStack(spacing: 6) {
            // Indent by depth, so a property row reads as belonging to the
            // object row above it rather than as a sibling of it.
            if track.depth > 0 {
                Color.clear.frame(width: CGFloat(track.depth) * 12, height: 1)
            }

            if isGroup {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 9)
            } else {
                Circle()
                    .fill(track.node.tint.opacity(0.95))
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(track.node.title)
                    .font(.system(size: isGroup ? 11 : 10.5,
                                  weight: isGroup ? .semibold : .medium))
                    .foregroundStyle(trackLabelColor(for: track))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle = track.node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // How many keys this object holds, so a collapsed group still says
            // whether there is anything in it.
            if isGroup, isCollapsed {
                Text("\(groupKeyCount(track))")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight, alignment: .leading)
        .background(rowStripe(index: rowIndex))
        .contentShape(Rectangle())
        .onTapGesture {
            if isGroup {
                if isCollapsed {
                    collapsedTrackGroups.remove(track.node.id)
                } else {
                    collapsedTrackGroups.insert(track.node.id)
                }
                // Selecting the object too, so the canvas follows the timeline.
                selectObject(for: track)
            } else {
                selectedTrackID = track.node.id
                selectObject(for: track)
            }
        }
    }

    /// Total keys under a group row.
    private func groupKeyCount(_ track: FlattenedTimelineTrack) -> Int {
        track.node.children.reduce(0) { $0 + ($1.frames?.count ?? 0) }
    }

    /// Clicking a row in the timeline selects the object it belongs to, the way
    /// clicking it in the hierarchy would. Without this the timeline can show
    /// eight objects but the canvas still only follows the hierarchy.
    private func selectObject(for track: FlattenedTimelineTrack) {
        guard let targetID = rowTargetID(from: track.node.id) else { return }
        if sceneManager.skeleton.bones[targetID] != nil {
            // Before the "already selected, nothing to do" shortcut below: with
            // a modifier held, clicking the row that is already active is
            // exactly how you take it back out of the selection.
            if isShiftModifierPressed {
                sceneManager.setBoneSelection(shiftBoneRange(to: targetID),
                                              primary: targetID, additive: false)
                return
            }
            if isCommandModifierPressed {
                sceneManager.toggleBoneSelection(targetID)
                return
            }
        }
        guard targetID != selectedAnimationTargetID else { return }
        if sceneManager.images.contains(where: { $0.id == targetID }) {
            sceneManager.setSelection(ids: [targetID], primary: targetID, additive: false)
        } else if sceneManager.skeleton.bones[targetID] != nil {
            sceneManager.selectBone(targetID)
        }
    }

    private func trackLabelColor(for track: FlattenedTimelineTrack) -> Color {
        if track.node.id == selectedTrackID {
            return track.node.tint.opacity(0.98)
        }
        if track.node.kind == .group {
            let isSelectedObject = rowTargetID(from: track.node.id) == selectedAnimationTargetID
            return isSelectedObject ? track.node.tint.opacity(0.98) : palette.primaryText
        }
        return palette.secondaryText
    }

    /// A keyframe's colour is its channel's colour.
    ///
    /// This used to switch on the row's display title — so a diamond found its
    /// colour by matching the word "Rotate", and any rename or translation of
    /// that label would have quietly dropped it to the fallback. The property
    /// is what it is keyed on now, and the colour comes from the one palette.
    private func keyframeDiamondColor(for track: FlattenedTimelineTrack) -> Color {
        guard let property = propertyForTrack(track),
              let color = UM.channelColor(for: property) else {
            return track.node.tint.opacity(0.76)
        }
        return color
    }

    private var timelineLeftColumn: some View {
        trackSidebar
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
    }

    private var trackSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Timeline")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text(selectedAnimationTargetName ?? "animation")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                    }

                    Spacer()

                    Menu {
                        ForEach(TimelineFilter.allCases) { filter in
                            Button(filter.title) {
                                selectedFilter = filter
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: TimelineMetrics.headerHeight)
                .background(palette.panel)

                ForEach(visibleTracks) { track in
                    trackSidebarRow(track)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
    }

    /// The ruler, pinned vertically and scrolled horizontally with the rows.
    private func pinnedRuler(width: CGFloat) -> some View {
        rulerRow
            .frame(width: width, alignment: .leading)
            .offset(x: -scrollOffsetX)
            .frame(height: TimelineMetrics.headerHeight, alignment: .leading)
            .clipped()
    }

    private func trackSidebarRow(_ track: FlattenedTimelineTrack) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(track.node.tint.opacity(track.node.kind == .group ? 0.9 : 0.7))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.node.title)
                    .font(.system(size: 11, weight: track.node.kind == .group ? .semibold : .medium))
                    .foregroundStyle(track.node.id == selectedTrackID ? palette.primaryText : palette.secondaryText)
                if let subtitle = track.node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            Spacer()

            if track.node.kind == .track {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open")
                    Image(systemName: "speaker.slash")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.leading, 14 + CGFloat(track.depth) * 12)
        .padding(.trailing, 10)
        .frame(height: rowHeight, alignment: .leading)
        .background(rowBackground(isSelected: track.node.id == selectedTrackID))
        .contentShape(Rectangle())
        .onTapGesture {
            if track.node.kind == .track {
                selectedTrackID = track.node.id
            }
        }
    }

    private var rulerRow: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(palette.panel)

            rulerGrid(height: TimelineMetrics.headerHeight)

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.workRange.opacity(0.14))
                .frame(width: framePosition(workEndFrame) - framePosition(workStartFrame), height: 8)
                .offset(x: framePosition(workStartFrame), y: 26)

            ForEach(Array(stride(from: 0, through: totalFrames, by: frameStep)), id: \.self) { frame in
                let labelWidth = max(CGFloat(frameStep) * frameSpacing * zoomScale, 18)

                VStack(alignment: .center, spacing: 1) {
                    Text(rulerLabel(for: frame))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(frame.isMultiple(of: 10) ? palette.primaryText.opacity(0.85) : palette.secondaryText.opacity(0.78))

                    Rectangle()
                        .fill(frame.isMultiple(of: 10) ? palette.gridStrong : palette.gridSoft.opacity(0.8))
                        .frame(width: 1, height: frame.isMultiple(of: 10) ? 7 : 4)
                }
                .frame(width: labelWidth)
                .offset(x: framePosition(frame) - (labelWidth * 0.5), y: 4)
            }

        }
        .contentShape(Rectangle())
        .gesture(rulerScrubGesture(contentWidth: contentWidth))
        .frame(height: TimelineMetrics.headerHeight)
        .clipped()
    }

    private func rulerGrid(height: CGFloat) -> some View {
        let lineTopOffset: CGFloat = 14
        let lineHeight = max(height - lineTopOffset, 0)

        return ZStack(alignment: .leading) {
            ForEach(0...totalFrames, id: \.self) { frame in
                Rectangle()
                    .fill(gridColor(for: frame))
                    .frame(width: 1, height: lineHeight)
                    .offset(x: framePosition(frame), y: lineTopOffset)
            }
        }
    }

    private func timelineRow(for track: FlattenedTimelineTrack, rowIndex: Int) -> some View {
        ZStack(alignment: .leading) {
            rowStripe(index: rowIndex)
            timelineGrid(height: rowHeight)

            if track.node.kind == .group {
                groupSummaryRow(for: track)
            } else if let imageID = targetID(for: track),
                      let property = propertyForTrack(track) {
                keyframeLine(
                    for: track,
                    imageID: imageID,
                    property: property,
                    keyframes: sceneManager.keyframes(for: imageID, property: property)
                )
            }
        }
        .frame(height: rowHeight)
        .clipped()
    }

    /// Where an object holds keys, summarised on its own row.
    ///
    /// Without this a collapsed group is a blank band and folding one away
    /// hides the very thing you folded it to skim. The marks are not draggable:
    /// a summary tick can stand for four keys at once, so moving it would be
    /// ambiguous. Open the group to edit.
    private func groupSummaryRow(for track: FlattenedTimelineTrack) -> some View {
        let frames: [Int] = Array(Set(track.node.children.flatMap { $0.frames ?? [] })).sorted()
        return ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.self) { frame in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(track.node.tint.opacity(0.55))
                    .frame(width: 3, height: rowHeight * 0.34)
                    .offset(x: framePosition(frame) - 1.5,
                            y: rowHeight * 0.33)
            }
        }
        .allowsHitTesting(false)
    }

    private func keyframeLine(
        for track: FlattenedTimelineTrack,
        imageID: UUID,
        property: AnimationTrackProperty,
        keyframes: [Keyframe]
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if keyframes.count > 1 {
                Path { path in
                    let centerY = rowHeight * 0.5
                    for index in 0..<(keyframes.count - 1) {
                        let lhs = keyframes[index]
                        let rhs = keyframes[index + 1]
                        let start = CGPoint(x: framePosition(lhs.frame), y: centerY)
                        let end = CGPoint(x: framePosition(rhs.frame), y: centerY)

                        switch lhs.interpolation {
                        case .hold:
                            path.move(to: start)
                            path.addLine(to: end)
                        case .linear:
                            path.move(to: start)
                            path.addLine(to: end)
                        case .bezier:
                            let controlYOffset: CGFloat = min(10, max((end.x - start.x) * 0.12, 4))
                            let controlOne = CGPoint(x: start.x + ((end.x - start.x) * 0.35), y: centerY - controlYOffset)
                            let controlTwo = CGPoint(x: start.x + ((end.x - start.x) * 0.65), y: centerY + controlYOffset)
                            path.move(to: start)
                            path.addCurve(to: end, control1: controlOne, control2: controlTwo)
                        }
                    }
                }
                .stroke(track.node.tint.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

                Path { path in
                    let centerY = rowHeight * 0.5
                    for index in 0..<(keyframes.count - 1) {
                        let lhs = keyframes[index]
                        guard lhs.interpolation == .hold else { continue }
                        let rhs = keyframes[index + 1]
                        let start = CGPoint(x: framePosition(lhs.frame), y: centerY)
                        let end = CGPoint(x: framePosition(rhs.frame), y: centerY)
                        path.move(to: start)
                        path.addLine(to: end)
                    }
                }
                .stroke(
                    track.node.tint.opacity(0.46),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [5, 4])
                )
            }

            ForEach(keyframes) { keyframe in
                let selection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: keyframe.id)
                DiamondKeyframe(
                    color: keyframeDiamondColor(for: track),
                    isSelected: sceneManager.isKeyframeSelected(selection),
                    interpolation: keyframe.interpolation
                )
                .frame(width: 12, height: 12)
                .allowsHitTesting(false)
                .frame(width: 22, height: rowHeight)
                .position(x: framePosition(keyframe.frame), y: rowHeight * 0.5)
            }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = value.startLocation.x
                            guard let hitKeyframe = nearestKeyframe(to: x, in: keyframes) else { return }
                            let hitSelection = SelectedKeyframe(imageID: imageID, property: property, keyframeID: hitKeyframe.id)
                            selectedTrackID = track.node.id
                            if activeKeyframeDrag?.anchor.keyframeID != hitKeyframe.id {
                                sceneManager.selectKeyframe(
                                    imageID: imageID,
                                    property: property,
                                    keyframeID: hitKeyframe.id,
                                    additive: isShiftModifierPressed
                                )
                                let activeSelections = sceneManager.selectedKeyframes.isEmpty ? [hitSelection] : Array(sceneManager.selectedKeyframes)
                                let startFrames = Dictionary(uniqueKeysWithValues: activeSelections.compactMap { selected in
                                    sceneManager.keyframes(for: selected.imageID, property: selected.property)
                                        .first(where: { $0.id == selected.keyframeID })
                                        .map { (selected, $0.frame) }
                                })
                                activeKeyframeDrag = ActiveKeyframeDrag(anchor: hitSelection, startFrames: startFrames)
                            }
                            guard let drag = activeKeyframeDrag,
                                  sceneManager.isKeyframeSelected(drag.anchor) else { return }
                            let frameWidth = max(frameSpacing * zoomScale, 1)
                            let deltaFrames = Int((value.translation.width / frameWidth).rounded())
                            sceneManager.moveSelectedKeyframes(
                                anchor: drag.anchor,
                                deltaFrames: deltaFrames,
                                startFrames: drag.startFrames
                            )
                        }
                        .onEnded { value in
                            if activeKeyframeDrag == nil {
                                let x = value.startLocation.x
                                if let hitKeyframe = nearestKeyframe(to: x, in: keyframes) {
                                    selectedTrackID = track.node.id
                                    sceneManager.selectKeyframe(
                                        imageID: imageID,
                                        property: property,
                                        keyframeID: hitKeyframe.id,
                                        additive: isShiftModifierPressed
                                    )
                                } else {
                                    sceneManager.setSelectedKeyframes([], additive: false)
                                }
                            }
                            activeKeyframeDrag = nil
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Graph tab's right-hand pane: its own toolbar over the plot.
    private var graphPane: some View {
        VStack(spacing: 0) {
            graphToolbar
            graphPlot
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.background)
    }

    private var graphToolbar: some View {
        let channels = graphChannels

        return HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Graph Editor")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(selectedTrackTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                HStack(spacing: 8) {
                    if channels.isEmpty {
                        graphChip(title: "No Data")
                    } else {
                        interpolationPicker

                        Button {
                            sceneManager.applyAutoTangentsToSelectedKeyframes()
                        } label: {
                            graphChip(title: "Auto")
                        }
                        .buttonStyle(.plain)
                        .disabled(sceneManager.selectedKeyframes.isEmpty)

                        ForEach(channels) { channel in
                            graphLegendChip(channel: channel)
                        }
                    }
                }
            }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.panel)
        .overlay(
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// The curves themselves.
    ///
    /// The popout reserved `timelineLabelsWidth` of empty space here so its
    /// plot lined up with the dope-sheet rows above it. The real track column
    /// sits there now, so the plot gets that width back.
    private var graphPlot: some View {
        let channels = graphChannels

        return GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.panel.opacity(0.72))

                    HStack(spacing: 0) {
                        GeometryReader { plotGeometry in
                            let drawingSize = CGSize(
                                width: max(plotGeometry.size.width, 40),
                                height: max(plotGeometry.size.height, 80)
                            )

                            ZStack(alignment: .topLeading) {
                                graphGrid

                                if channels.isEmpty {
                                    VStack(spacing: 8) {
                                        Text(selectedAnimationTargetID == nil ? "Graph editor ready" : "Select a keyed track")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(palette.primaryText)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.9)
                                        Text(selectedAnimationTargetID == nil ? "Select an object to create tracks." : "Choose Rotate, Translate, Scale, or Shear with keyframes to edit curves.")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(palette.secondaryText)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.85)
                                    }
                                    .frame(maxWidth: 420)
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    // ONCE, for everything below it.
                                    //
                                    // Each of `graphCurve`, `graphPoint` and
                                    // `graphBezierHandles` used to call
                                    // `graphValueRange(for: graphChannels)`
                                    // itself, which recomputes the bounds of
                                    // every curve from scratch — so the bounds
                                    // were computed once per channel, once per
                                    // KEYFRAME, and once per Bézier keyframe,
                                    // every redraw. The timeline redraws on
                                    // every frame of playback, and the bounds
                                    // computation is itself proportional to the
                                    // keyframes it walks, which is how adding
                                    // Bézier curves took the editor to five
                                    // frames a second.
                                    let valueRange = graphValueRange(for: channels)
                                    ZStack(alignment: .topLeading) {
                                        ForEach(channels) { channel in
                                            graphCurve(for: channel, range: valueRange, size: drawingSize)
                                        }

                                        Rectangle()
                                            .fill(palette.playhead.opacity(0.8))
                                            .frame(width: 1.5, height: drawingSize.height)
                                            .offset(x: graphXPosition(for: currentFrame, width: drawingSize.width))

                                        ForEach(channels) { channel in
                                            ForEach(channel.samples) { sample in
                                                graphPoint(for: channel, sample: sample, range: valueRange, size: drawingSize)
                                            }
                                        }

                                        if let selectedHandleKeyframe = selectedGraphHandleKeyframe,
                                           let selectedGraphChannelID {
                                            graphBezierHandles(for: selectedHandleKeyframe, channelID: selectedGraphChannelID, range: valueRange, size: drawingSize)
                                        }

                                        if let dragBadge {
                                            dragBadge
                                                .offset(x: 14, y: 14)
                                        }
                                    }
                                    .frame(width: drawingSize.width, height: drawingSize.height)
                                    .clipped()
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
    }

    private var graphGrid: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack(alignment: .topLeading) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(index == 2 ? palette.gridStrong : palette.gridSoft)
                        .frame(height: 1)
                        .offset(y: CGFloat(index) * (height / 4))
                }

                ForEach(0..<7, id: \.self) { index in
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? palette.gridStrong : palette.gridSoft)
                        .frame(width: 1, height: height)
                        .offset(x: CGFloat(index) * (width / 6))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Label("Playhead \(timelineLabel(for: currentFrame))", systemImage: "playhead")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)

                Label("Work Area \(timelineLabel(for: workStartFrame))-\(timelineLabel(for: workEndFrame))", systemImage: "timeline.selection")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 18)

                Label("Snap \(isSnapEnabled ? "On" : "Off")", systemImage: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)

                Label(selectedAnimationTargetID == nil ? "No Selection" : selectedFilter.title, systemImage: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.panel)
        .overlay(
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1),
            alignment: .top
        )
    }

    private func rowBackground(isSelected: Bool) -> some View {
        Group {
            if isSelected {
                palette.selection
            } else {
                Color.clear
            }
        }
    }

    private func rowStripe(index: Int) -> some View {
        Rectangle()
            .fill(index.isMultiple(of: 2) ? palette.rowA : palette.rowB)
    }

    private func timelineRowBands(height: CGFloat) -> some View {
        let rowCount = max(Int(ceil(height / rowHeight)), 1)

        return ZStack(alignment: .topLeading) {
            ForEach(0..<rowCount, id: \.self) { index in
                Rectangle()
                    .fill(index.isMultiple(of: 2) ? palette.rowA : palette.rowB)
                    .frame(height: rowHeight)
                    .offset(y: CGFloat(index) * rowHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func timelineGrid(height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0...totalFrames, id: \.self) { frame in
                Rectangle()
                    .fill(gridColor(for: frame))
                    .frame(width: 1, height: height)
                    .offset(x: framePosition(frame))
            }
        }
    }

    private func toggleChip(title: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isOn ? tint.opacity(1.0) : tint.opacity(0.42))
                    .frame(width: 8, height: 8)
                    .shadow(color: isOn ? tint.opacity(0.55) : .clear, radius: 4, x: 0, y: 0)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? UM.textPrimary.opacity(0.98) : UM.textPrimary.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isOn
                        ? tint.opacity(0.22)
                        : UM.surfaceRaised
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isOn ? tint.opacity(0.85) : UM.textPrimary.opacity(0.09), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func graphChip(title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.background.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(palette.separator, lineWidth: 1)
            )
    }

    private func graphLegendChip(channel: GraphChannel) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(channel.color)
                .frame(width: 6, height: 6)
            Text(channel.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.background.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private var selectedTrackTitle: String {
        guard let selectedTrackID else { return "No Track Selected" }
        return flattenedTracks.first(where: { $0.node.id == selectedTrackID })?.node.title ?? "No Track Selected"
    }

    private var selectedTrackProperty: AnimationTrackProperty? {
        guard let selectedTrackID,
              let track = flattenedTracks.first(where: { $0.node.id == selectedTrackID }) else {
            return nil
        }
        return propertyForTrack(track)
    }

    private var selectedGraphHandleKeyframe: Keyframe? {
        guard let imageID = selectedTrackTargetID,
              let property = selectedTrackProperty,
              selectedGraphChannelID != nil,
              sceneManager.selectedKeyframes.count == 1,
              let selection = sceneManager.selectedKeyframes.first,
              selection.imageID == imageID,
              selection.property == property else {
            return nil
        }

        return sceneManager.keyframes(for: imageID, property: property)
            .first(where: { $0.id == selection.keyframeID })
    }

    private func graphChannelValue(for keyframe: Keyframe, channelID: String) -> Float? {
        switch keyframe.value {
        case let .translate(value):
            return channelID.hasSuffix(".x") ? value.x : value.y
        case let .rotate(value):
            return value
        case let .scale(value):
            return channelID.hasSuffix(".x") ? value.x : value.y
        case let .shear(value):
            return channelID.hasSuffix(".x") ? value.x : value.y
        case let .scalar(value):
            return value
        case let .vector2(value):
            return channelID.hasSuffix(".x") ? value.x : value.y
        case let .flag(value):
            return value ? 1 : 0
        case .meshDeform, .drawOrder, .event, .attachment:
            return nil
        }
    }

    private var graphChannels: [GraphChannel] {
        guard let targetID = selectedTrackTargetID,
              let property = selectedTrackProperty else {
            return []
        }

        let keyframes = sceneManager.keyframes(for: targetID, property: property)
        guard !keyframes.isEmpty else { return [] }

        switch property {
        case .translate:
            return [
                GraphChannel(
                    id: "translate.x",
                    title: "X",
                    color: palette.transform.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.translateValue?.x ?? 0, channelID: "translate.x")
                    }
                ),
                GraphChannel(
                    id: "translate.y",
                    title: "Y",
                    color: palette.accent.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.translateValue?.y ?? 0, channelID: "translate.y")
                    }
                )
            ]
        case .rotate:
            return [
                GraphChannel(
                    id: "rotate.scalar",
                    title: "Angle",
                    color: palette.rotation.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.rotateValue ?? 0, channelID: "rotate.scalar")
                    }
                )
            ]
        case .scale:
            return [
                GraphChannel(
                    id: "scale.x",
                    title: "Width",
                    color: palette.scale.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.scaleValue?.x ?? 1, channelID: "scale.x")
                    }
                ),
                GraphChannel(
                    id: "scale.y",
                    title: "Height",
                    color: palette.accent.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.scaleValue?.y ?? 1, channelID: "scale.y")
                    }
                )
            ]
        case .shear:
            return [
                GraphChannel(
                    id: "shear.x",
                    title: "X",
                    color: palette.skew.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.shearValue?.x ?? 0, channelID: "shear.x")
                    }
                ),
                GraphChannel(
                    id: "shear.y",
                    title: "Y",
                    color: palette.rotation.opacity(0.98),
                    samples: keyframes.map {
                        GraphSample(keyframe: $0, value: $0.value.shearValue?.y ?? 0, channelID: "shear.y")
                    }
                )
            ]
        case .meshDeform, .drawOrder, .event, .attachment:
            // Per-vertex deform and draw order permutations have no meaningful
            // scalar curve, so the graph editor shows nothing for them.
            return []
        default:
            // Constraint properties: one curve for scalars and booleans, two
            // for vector properties such as physics wind.
            switch property.valueKind {
            case .scalar:
                return [
                    GraphChannel(
                        id: "constraint.scalar",
                        title: property.title,
                        color: palette.accent.opacity(0.98),
                        samples: keyframes.map {
                            GraphSample(keyframe: $0, value: $0.value.floatValue ?? 0, channelID: "constraint.scalar")
                        }
                    )
                ]
            case .flag:
                return [
                    GraphChannel(
                        id: "constraint.flag",
                        title: property.title,
                        color: palette.rotation.opacity(0.98),
                        samples: keyframes.map {
                            GraphSample(keyframe: $0, value: ($0.value.boolValue ?? false) ? 1 : 0, channelID: "constraint.flag")
                        }
                    )
                ]
            case .vector2:
                return [
                    GraphChannel(
                        id: "constraint.x",
                        title: "X",
                        color: palette.accent.opacity(0.98),
                        samples: keyframes.map {
                            GraphSample(keyframe: $0, value: $0.value.simd2Value?.x ?? 0, channelID: "constraint.x")
                        }
                    ),
                    GraphChannel(
                        id: "constraint.y",
                        title: "Y",
                        color: palette.rotation.opacity(0.98),
                        samples: keyframes.map {
                            GraphSample(keyframe: $0, value: $0.value.simd2Value?.y ?? 0, channelID: "constraint.y")
                        }
                    )
                ]
            case .deform, .drawOrder, .event, .attachment:
                return []
            }
        }
    }

    private func graphCurve(for channel: GraphChannel, range valueRange: ClosedRange<Float>,
                            size: CGSize) -> some View {

        return ZStack(alignment: .topLeading) {
            Path { path in
                guard channel.samples.count > 1 else { return }

                for index in 0..<(channel.samples.count - 1) {
                    let lhs = channel.samples[index]
                    let rhs = channel.samples[index + 1]
                    let start = CGPoint(
                        x: graphXPosition(for: Double(lhs.frame), width: size.width),
                        y: graphYPosition(for: lhs.value, range: valueRange, height: size.height)
                    )
                    let end = CGPoint(
                        x: graphXPosition(for: Double(rhs.frame), width: size.width),
                        y: graphYPosition(for: rhs.value, range: valueRange, height: size.height)
                    )

                    switch lhs.interpolation {
                    case .hold:
                        path.move(to: start)
                        path.addLine(to: CGPoint(x: end.x, y: start.y))
                        path.addLine(to: end)
                    case .linear:
                        path.move(to: start)
                        path.addLine(to: end)
                    case .bezier:
                        let controlOne = graphBezierOutControlPoint(lhs: lhs, rhs: rhs, channelID: channel.id, range: valueRange, size: size, samples: channel.samples)
                        let controlTwo = graphBezierInControlPoint(lhs: lhs, rhs: rhs, channelID: channel.id, range: valueRange, size: size, samples: channel.samples)
                        path.move(to: start)
                        path.addCurve(to: end, control1: controlOne, control2: controlTwo)
                    }
                }
            }
            .stroke(channel.color.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(0..<max(channel.samples.count - 1, 0), id: \.self) { index in
                graphCurveHitArea(
                    lhs: channel.samples[index],
                    rhs: channel.samples[index + 1],
                    channel: channel,
                    size: size,
                    valueRange: valueRange
                )
            }
        }
    }

    private func graphCurveHitArea(
        lhs: GraphSample,
        rhs: GraphSample,
        channel: GraphChannel,
        size: CGSize,
        valueRange: ClosedRange<Float>
    ) -> some View {
        let start = CGPoint(
            x: graphXPosition(for: Double(lhs.frame), width: size.width),
            y: graphYPosition(for: lhs.value, range: valueRange, height: size.height)
        )
        let end = CGPoint(
            x: graphXPosition(for: Double(rhs.frame), width: size.width),
            y: graphYPosition(for: rhs.value, range: valueRange, height: size.height)
        )
        let c1 = graphBezierOutControlPoint(lhs: lhs, rhs: rhs, channelID: channel.id, range: valueRange, size: size, samples: channel.samples)
        let c2 = graphBezierInControlPoint(lhs: lhs, rhs: rhs, channelID: channel.id, range: valueRange, size: size, samples: channel.samples)

        let segPath = Path { path in
            switch lhs.interpolation {
            case .hold:
                path.move(to: start)
                path.addLine(to: CGPoint(x: end.x, y: start.y))
                path.addLine(to: end)
            case .linear:
                path.move(to: start)
                path.addLine(to: end)
            case .bezier:
                path.move(to: start)
                path.addCurve(to: end, control1: c1, control2: c2)
            }
        }
        let hitStyle = StrokeStyle(lineWidth: GraphMetrics.curveGrabPx)

        return segPath
            .stroke(Color.clear, lineWidth: GraphMetrics.curveGrabPx)
            .contentShape(segPath.strokedPath(hitStyle))
            .onTapGesture {
                guard let imageID = selectedTrackTargetID,
                      let property = selectedTrackProperty else { return }
                sceneManager.selectKeyframe(
                    imageID: imageID,
                    property: property,
                    keyframeID: lhs.keyframeID,
                    additive: false
                )
                selectedGraphChannelID = channel.id
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard lhs.interpolation == .bezier,
                              let imageID = selectedTrackTargetID,
                              let property = selectedTrackProperty else { return }

                        let keyframes = sceneManager.keyframes(for: imageID, property: property)
                        guard let lhsKf = keyframes.first(where: { $0.id == lhs.keyframeID }),
                              let rhsKf = keyframes.first(where: { $0.id == rhs.keyframeID }) else { return }

                        if activeCurveSegmentDrag?.lhsKeyframeID != lhs.keyframeID ||
                           activeCurveSegmentDrag?.channelID != channel.id {
                            sceneManager.selectKeyframe(
                                imageID: imageID,
                                property: property,
                                keyframeID: lhs.keyframeID,
                                additive: false
                            )
                            selectedGraphChannelID = channel.id
                            let initOut = graphTangent(for: lhsKf, channelID: channel.id, handle: .out) ?? defaultGraphTangent(handle: .out)
                            let initIn = graphTangent(for: rhsKf, channelID: channel.id, handle: .in) ?? defaultGraphTangent(handle: .in)
                            activeCurveSegmentDrag = ActiveCurveSegmentDrag(
                                channelID: channel.id,
                                lhsKeyframeID: lhs.keyframeID,
                                rhsKeyframeID: rhs.keyframeID,
                                initialLhsOutTangent: initOut,
                                initialRhsInTangent: initIn
                            )
                        }

                        guard let drag = activeCurveSegmentDrag else { return }
                        let deltaValue = graphValueDelta(from: value.translation.height, range: valueRange, height: size.height)

                        var newLhsOut = drag.initialLhsOutTangent
                        newLhsOut.y -= deltaValue
                        var newRhsIn = drag.initialRhsInTangent
                        newRhsIn.y -= deltaValue

                        sceneManager.updateKeyframeTangents(
                            imageID: imageID, property: property, keyframeID: lhs.keyframeID,
                            inTangent: updatedPrimaryInTangent(for: lhsKf, channelID: channel.id, handle: .out, updatedTangent: newLhsOut),
                            outTangent: updatedPrimaryOutTangent(for: lhsKf, channelID: channel.id, handle: .out, updatedTangent: newLhsOut),
                            secondaryInTangent: updatedSecondaryInTangent(for: lhsKf, channelID: channel.id, handle: .out, updatedTangent: newLhsOut),
                            secondaryOutTangent: updatedSecondaryOutTangent(for: lhsKf, channelID: channel.id, handle: .out, updatedTangent: newLhsOut)
                        )
                        sceneManager.updateKeyframeTangents(
                            imageID: imageID, property: property, keyframeID: rhs.keyframeID,
                            inTangent: updatedPrimaryInTangent(for: rhsKf, channelID: channel.id, handle: .in, updatedTangent: newRhsIn),
                            outTangent: updatedPrimaryOutTangent(for: rhsKf, channelID: channel.id, handle: .in, updatedTangent: newRhsIn),
                            secondaryInTangent: updatedSecondaryInTangent(for: rhsKf, channelID: channel.id, handle: .in, updatedTangent: newRhsIn),
                            secondaryOutTangent: updatedSecondaryOutTangent(for: rhsKf, channelID: channel.id, handle: .in, updatedTangent: newRhsIn)
                        )
                    }
                    .onEnded { _ in activeCurveSegmentDrag = nil }
            )
    }

    private func graphPoint(for channel: GraphChannel, sample: GraphSample,
                            range: ClosedRange<Float>, size: CGSize) -> some View {
        let selection = selectedGraphSelection(for: sample)
        let isSelected = selection.map(sceneManager.isKeyframeSelected) == true
        let px = graphXPosition(for: Double(sample.frame), width: size.width)
        let py = graphYPosition(for: sample.value, range: range, height: size.height)

        return Circle()
            .fill(palette.background)
            .overlay(
                Circle()
                    .stroke(isSelected ? UM.textPrimary.opacity(0.92) : channel.color,
                            lineWidth: isSelected ? 2.4 : 1.8)
            )
            // Drawn small, grabbed generously — and the grab size is
            // platform-aware, because a Pencil tip is not a cursor.
            .frame(width: GraphMetrics.keyframeVisualPx, height: GraphMetrics.keyframeVisualPx)
            .frame(width: GraphMetrics.keyframeGrabPx, height: GraphMetrics.keyframeGrabPx)
            .position(x: px, y: py)
            .onTapGesture {
                guard let imageID = selectedTrackTargetID,
                      let property = selectedTrackProperty,
                      selection != nil else { return }
                sceneManager.selectKeyframe(
                    imageID: imageID,
                    property: property,
                    keyframeID: sample.keyframeID,
                    additive: isShiftModifierPressed
                )
                selectedGraphChannelID = channel.id
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard let imageID = selectedTrackTargetID,
                              let property = selectedTrackProperty,
                              let selection else { return }

                        if activeGraphPointDrag?.selection != selection {
                            sceneManager.selectKeyframe(
                                imageID: imageID,
                                property: property,
                                keyframeID: sample.keyframeID,
                                additive: isShiftModifierPressed
                            )
                            selectedGraphChannelID = channel.id
                            activeGraphPointDrag = ActiveGraphPointDrag(
                                selection: selection,
                                initialFrame: sample.frame,
                                initialValue: sample.value
                            )
                        }

                        let frameWidth = max(contentWidth / CGFloat(max(totalFrames, 1)), 1)
                        let deltaFrames = Int((value.translation.width / frameWidth).rounded())
                        let updatedFrame = max((activeGraphPointDrag?.initialFrame ?? sample.frame) + deltaFrames, 0)

                        let deltaValue = graphValueDelta(from: value.translation.height, range: range, height: size.height)
                        let updatedValue = (activeGraphPointDrag?.initialValue ?? sample.value) - deltaValue

                        sceneManager.moveKeyframe(
                            imageID: imageID,
                            property: property,
                            keyframeID: sample.keyframeID,
                            toFrame: updatedFrame
                        )
                        sceneManager.updateKeyframeValue(
                            imageID: imageID,
                            property: property,
                            keyframeID: sample.keyframeID,
                            value: updatedGraphKeyframeValue(for: property, keyframeID: sample.keyframeID, channelID: channel.id, scalarValue: updatedValue)
                        )
                    }
                    .onEnded { _ in
                        activeGraphPointDrag = nil
                    }
            )
    }

    private func graphBezierHandles(for keyframe: Keyframe, channelID: String,
                                    range: ClosedRange<Float>, size: CGSize) -> some View {
        let framePoint = CGPoint(
            x: graphXPosition(for: Double(keyframe.frame), width: size.width),
            y: graphYPosition(for: graphChannelValue(for: keyframe, channelID: channelID) ?? 0, range: range, height: size.height)
        )

        return ZStack {
            if let outHandle = graphHandlePoint(for: keyframe, channelID: channelID, handle: .out, size: size, range: range) {
                Path { path in
                    path.move(to: framePoint)
                    path.addLine(to: outHandle)
                }
                .stroke(palette.graph.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                graphHandleKnob(for: keyframe, channelID: channelID, handle: .out, point: outHandle, size: size, range: range)
            }

            if let inHandle = graphHandlePoint(for: keyframe, channelID: channelID, handle: .in, size: size, range: range) {
                Path { path in
                    path.move(to: framePoint)
                    path.addLine(to: inHandle)
                }
                .stroke(palette.graph.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                graphHandleKnob(for: keyframe, channelID: channelID, handle: .in, point: inHandle, size: size, range: range)
            }
        }
    }

    private func graphHandleKnob(
        for keyframe: Keyframe,
        channelID: String,
        handle: GraphHandleKind,
        point: CGPoint,
        size: CGSize,
        range: ClosedRange<Float>
    ) -> some View {
        Circle()
            .fill(palette.background)
            .overlay(
                Circle()
                    .stroke(palette.graph.opacity(0.92), lineWidth: 1.8)
            )
            // Bigger than a keyframe's, not smaller: a handle is the smallest
            // thing on screen and the one most often reached for, and it can
            // sit on top of its own keyframe. It used to be 20 against the
            // keyframe's 22, so only the drawing order kept it grabbable.
            .frame(width: GraphMetrics.handleVisualPx, height: GraphMetrics.handleVisualPx)
            .frame(width: GraphMetrics.handleGrabPx, height: GraphMetrics.handleGrabPx)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let imageID = selectedTrackTargetID,
                              let property = selectedTrackProperty else { return }

                        let currentTangent = graphTangent(for: keyframe, channelID: channelID, handle: handle)
                        if activeGraphHandleDrag?.keyframeID != keyframe.id || activeGraphHandleDrag?.handle != handle || activeGraphHandleDrag?.channelID != channelID {
                            activeGraphHandleDrag = ActiveGraphHandleDrag(
                                keyframeID: keyframe.id,
                                channelID: channelID,
                                handle: handle,
                                initialTangent: currentTangent ?? defaultGraphTangent(handle: handle)
                            )
                        }

                        let updatedTangent = updatedGraphTangent(
                            from: activeGraphHandleDrag?.initialTangent ?? defaultGraphTangent(handle: handle),
                            translation: value.translation,
                            handle: handle,
                            range: range,
                            size: size
                        )

                        sceneManager.updateKeyframeTangents(
                            imageID: imageID,
                            property: property,
                            keyframeID: keyframe.id,
                            inTangent: updatedPrimaryInTangent(for: keyframe, channelID: channelID, handle: handle, updatedTangent: updatedTangent),
                            outTangent: updatedPrimaryOutTangent(for: keyframe, channelID: channelID, handle: handle, updatedTangent: updatedTangent),
                            secondaryInTangent: updatedSecondaryInTangent(for: keyframe, channelID: channelID, handle: handle, updatedTangent: updatedTangent),
                            secondaryOutTangent: updatedSecondaryOutTangent(for: keyframe, channelID: channelID, handle: handle, updatedTangent: updatedTangent)
                        )
                    }
                    .onEnded { _ in
                        activeGraphHandleDrag = nil
                    }
            )
    }

    private func interpolationChipTitle(for interpolation: KeyframeInterpolation) -> String {
        switch interpolation {
        case .hold:
            return "Hold"
        case .linear:
            return "Linear"
        case .bezier:
            return "Bezier"
        }
    }

    private func interpolationChipBackground(
        for interpolation: KeyframeInterpolation,
        selectedInterpolation: KeyframeInterpolation?
    ) -> Color {
        guard selectedInterpolation == interpolation else {
            return palette.background.opacity(0.7)
        }

        switch interpolation {
        case .hold:
            return palette.skew.opacity(0.18)
        case .linear:
            return palette.accent.opacity(0.18)
        case .bezier:
            return palette.graph.opacity(0.18)
        }
    }

    private func interpolationChipTextColor(
        for interpolation: KeyframeInterpolation,
        selectedInterpolation: KeyframeInterpolation?
    ) -> Color {
        guard selectedInterpolation == interpolation else {
            return palette.secondaryText
        }

        switch interpolation {
        case .hold:
            return palette.skew.opacity(0.95)
        case .linear:
            return palette.accent.opacity(0.95)
        case .bezier:
            return palette.graph.opacity(0.95)
        }
    }

    private var dragBadge: AnyView? {
        if let pointDrag = activeGraphPointDrag,
           let keyframe = graphKeyframe(for: pointDrag.selection.keyframeID),
           let channelID = selectedGraphChannelID,
           let value = graphChannelValue(for: keyframe, channelID: channelID) {
            return AnyView(
                graphBadge(
                    title: "Key",
                    detail: "F \(keyframe.frame)  •  V \(formattedGraphValue(value))"
                )
            )
        }

        if let handleDrag = activeGraphHandleDrag,
           let keyframe = graphKeyframe(for: handleDrag.keyframeID),
           let tangent = graphTangent(for: keyframe, channelID: handleDrag.channelID, handle: handleDrag.handle) {
            return AnyView(
                graphBadge(
                    title: handleDrag.handle == .in ? "In" : "Out",
                    detail: "ΔF \(formattedGraphValue(tangent.x))  •  ΔV \(formattedGraphValue(tangent.y))"
                )
            )
        }

        return nil
    }

    private func graphBadge(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.tertiaryText)
            Text(detail)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.background.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private func selectedGraphSelection(for sample: GraphSample) -> SelectedKeyframe? {
        guard let imageID = selectedTrackTargetID,
              let property = selectedTrackProperty else {
            return nil
        }

        return SelectedKeyframe(imageID: imageID, property: property, keyframeID: sample.keyframeID)
    }

    /// Where a handle SITS, in time and value — not on screen.
    ///
    /// Both the drawing and the fitting need this, and before there was only a
    /// screen-space version, which the fit could not use without already
    /// knowing the range it was trying to compute. One answer to "where is
    /// this handle", in the units the animation stores.
    private func graphControlPoints(
        lhs: GraphSample,
        rhs: GraphSample,
        channelID: String,
        samples: [GraphSample]
    ) -> (out: CGPoint, incoming: CGPoint) {
        // THROUGH `AnimationCurve`, which is what playback evaluates.
        //
        // This used to work the geometry out for itself, and got three things
        // differently from the evaluator: its auto tangent had no
        // turning-point clamp, so it drew a curve climbing past the key it had
        // just left — 100.65 against a key of 100, where playback holds
        // exactly 100; it never clamped a control point into its segment, so a
        // handle dragged past the next key drew an S-bend that differed from
        // what played by 90 units; and where it could not find the keyframe at
        // all it fell back to 0.35 and 0.65 of the span against the evaluator's
        // third. Three curves, and the artist was shown the one that is not
        // played. Measured in `Editor/verify_curve_authority.py`.
        //
        // The neighbours are passed because they are what an auto tangent is
        // derived from, and the graph HAS them — the evaluator, working one
        // segment at a time, does not, which is why the two disagreed about
        // exactly the keys where it matters.
        _ = channelID
        let index = samples.firstIndex { $0.id == lhs.id }
        let beforeStart = index.flatMap { $0 > 0 ? samples[$0 - 1] : nil }
            .map { (frame: $0.frame, value: $0.value) }
        let afterEnd = index.flatMap { $0 + 2 < samples.count ? samples[$0 + 2] : nil }
            .map { (frame: $0.frame, value: $0.value) }

        let segment = AnimationCurve.segment(
            start: (frame: lhs.frame, value: lhs.value),
            end: (frame: rhs.frame, value: rhs.value),
            outTangent: lhs.interpolation == .bezier ? lhs.outTangent : nil,
            inTangent: rhs.inTangent,
            beforeStart: beforeStart,
            afterEnd: afterEnd)

        return (out: CGPoint(x: Double(segment.control1.x), y: Double(segment.control1.y)),
                incoming: CGPoint(x: Double(segment.control2.x), y: Double(segment.control2.y)))
    }

    /// The extent of everything the editor draws: keys, handles, and the true
    /// extrema of each cubic between them.
    ///
    /// The range used to come from `samples.map(\.value)` — the keyframe
    /// values, padded 18%. A handle is not a keyframe value, and a cubic is not
    /// bounded by its ends, so a handle dragged out any distance and the curve
    /// it makes were mapped outside the frame and clipped away. The curve was
    /// cropped to fit a rectangle derived from something that is not the curve.
    private var graphCurveBounds: GraphBounds {
        var bounds = GraphBounds()
        for channel in graphChannels {
            for sample in channel.samples {
                bounds.include(time: Double(sample.frame), value: Double(sample.value))
            }
            guard channel.samples.count > 1 else { continue }
            for index in 0..<(channel.samples.count - 1) {
                let lhs = channel.samples[index]
                let rhs = channel.samples[index + 1]
                guard lhs.interpolation == .bezier else { continue }
                let controls = graphControlPoints(lhs: lhs, rhs: rhs,
                                                  channelID: channel.id,
                                                  samples: channel.samples)
                bounds.include(
                    cubicFrom: CGPoint(x: Double(lhs.frame), y: Double(lhs.value)),
                    control1: controls.out,
                    control2: controls.incoming,
                    to: CGPoint(x: Double(rhs.frame), y: Double(rhs.value)))
            }
        }
        return bounds
    }

    /// The view the artist has navigated to, or a fit to the curve when they
    /// have not navigated at all.
    private var graphViewportOrFit: GraphViewport {
        if let graphViewport { return graphViewport }
        let bounds = graphCurveBounds
        guard bounds.isValid else {
            return GraphViewport(timeRange: 0...Double(max(totalFrames, 1)),
                                 valueRange: -1...1)
        }
        return GraphViewport.fitting(bounds)
    }

    private func graphValueRange(for channels: [GraphChannel]) -> ClosedRange<Float> {
        let viewport = graphViewportOrFit
        return Float(viewport.valueRange.lowerBound)...Float(viewport.valueRange.upperBound)
    }

    /// X stays the clip fraction, deliberately, and this is not an oversight.
    ///
    /// The graph shares this mapping with the playhead and sits directly under
    /// the timeline ruler, which is laid out from the same fraction. Fitting X
    /// to the CURVE would put the graph on a different horizontal scale from
    /// the ruler above it and the playhead through it — the frame numbers
    /// would stop lining up with the keys under them.
    ///
    /// So horizontal zoom is not "route this through the viewport"; it is
    /// "zoom the timeline and the graph together", which is a change to the
    /// ruler as well. The viewport is ready for it — `timeRange` and
    /// `time(forX:)` are there and tested — and until the ruler moves with it,
    /// wiring only this half would break the alignment it is supposed to
    /// improve. The vertical axis, which is what the report is about, has no
    /// such coupling and does go through the viewport.
    private func graphXPosition(for frame: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(frame / Double(max(totalFrames, 1)))
    }

    private func graphYPosition(for value: Float, range: ClosedRange<Float>, height: CGFloat) -> CGFloat {
        let normalized = CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001))
        return height - (normalized * height)
    }

    private func graphValueDelta(from translationY: CGFloat, range: ClosedRange<Float>, height: CGFloat) -> Float {
        guard height > 0 else { return 0 }
        let unitsPerPoint = (range.upperBound - range.lowerBound) / Float(height)
        return Float(translationY) * unitsPerPoint
    }

    private func graphKeyframe(for keyframeID: UUID) -> Keyframe? {
        guard let imageID = selectedTrackTargetID,
              let property = selectedTrackProperty else {
            return nil
        }

        return sceneManager.keyframes(for: imageID, property: property)
            .first(where: { $0.id == keyframeID })
    }

    private func defaultGraphTangent(handle: GraphHandleKind) -> SIMD2<Float> {
        let frameLength: Float = 4
        switch handle {
        case .in:
            return SIMD2<Float>(-frameLength, 0)
        case .out:
            return SIMD2<Float>(frameLength, 0)
        }
    }

    // `smoothAutoTangent` was here: the graph's own auto tangent, a plain
    // central difference with no turning-point clamp. It is DELETED rather
    // than left unused, because it is the second broken way to answer a
    // question that now has one right answer — `AnimationCurve.autoSlope` —
    // and leaving it is how the graph would drift back to drawing a curve
    // nobody plays. Whoever needs an auto tangent asks the curve.


    private func graphHandlePoint(
        for keyframe: Keyframe,
        channelID: String,
        handle: GraphHandleKind,
        size: CGSize,
        range: ClosedRange<Float>
    ) -> CGPoint? {
        guard let scalarValue = graphChannelValue(for: keyframe, channelID: channelID) else { return nil }

        let tangent = graphTangent(for: keyframe, channelID: channelID, handle: handle) ?? defaultGraphTangent(handle: handle)
        let frameValue = CGFloat(keyframe.frame) + CGFloat(tangent.x)
        let value = scalarValue + tangent.y

        return CGPoint(
            x: graphXPosition(for: Double(frameValue), width: size.width),
            y: graphYPosition(for: value, range: range, height: size.height)
        )
    }

    private func updatedGraphTangent(
        from initialTangent: SIMD2<Float>,
        translation: CGSize,
        handle: GraphHandleKind,
        range: ClosedRange<Float>,
        size: CGSize
    ) -> SIMD2<Float> {
        let framesPerPoint = Double(max(totalFrames, 1)) / max(size.width, 1)
        let rawDeltaFrames = Float(translation.width * framesPerPoint)
        let deltaFrames = isSnapEnabled ? rawDeltaFrames.rounded() : rawDeltaFrames
        let deltaValue = graphValueDelta(from: translation.height, range: range, height: size.height)

        var tangent = initialTangent
        tangent.x += deltaFrames
        tangent.y -= deltaValue

        switch handle {
        case .in:
            tangent.x = min(tangent.x, -0.1)
        case .out:
            tangent.x = max(tangent.x, 0.1)
        }

        return tangent
    }

    private func graphTangent(for keyframe: Keyframe, channelID: String, handle: GraphHandleKind) -> SIMD2<Float>? {
        if channelUsesPrimaryTangents(channelID) {
            return handle == .in ? keyframe.inTangent : keyframe.outTangent
        }
        return handle == .in ? keyframe.secondaryInTangent : keyframe.secondaryOutTangent
    }

    private func channelUsesPrimaryTangents(_ channelID: String) -> Bool {
        GraphSample.usesPrimaryTangents(channelID)
    }

    private func updatedPrimaryInTangent(for keyframe: Keyframe, channelID: String, handle: GraphHandleKind, updatedTangent: SIMD2<Float>) -> SIMD2<Float>? {
        guard channelUsesPrimaryTangents(channelID), handle == .in else { return keyframe.inTangent }
        return updatedTangent
    }

    private func updatedPrimaryOutTangent(for keyframe: Keyframe, channelID: String, handle: GraphHandleKind, updatedTangent: SIMD2<Float>) -> SIMD2<Float>? {
        guard channelUsesPrimaryTangents(channelID), handle == .out else { return keyframe.outTangent }
        return updatedTangent
    }

    private func updatedSecondaryInTangent(for keyframe: Keyframe, channelID: String, handle: GraphHandleKind, updatedTangent: SIMD2<Float>) -> SIMD2<Float>? {
        guard !channelUsesPrimaryTangents(channelID), handle == .in else { return keyframe.secondaryInTangent }
        return updatedTangent
    }

    private func updatedSecondaryOutTangent(for keyframe: Keyframe, channelID: String, handle: GraphHandleKind, updatedTangent: SIMD2<Float>) -> SIMD2<Float>? {
        guard !channelUsesPrimaryTangents(channelID), handle == .out else { return keyframe.secondaryOutTangent }
        return updatedTangent
    }

    /// The out-handle, projected. Where it SITS is decided by
    /// `graphControlPoints`, which the curve fitting reads too — one answer to
    /// "where is this handle", so what is drawn and what is framed cannot
    /// disagree.
    private func graphBezierOutControlPoint(
        lhs: GraphSample,
        rhs: GraphSample,
        channelID: String,
        range: ClosedRange<Float>,
        size: CGSize,
        samples: [GraphSample]
    ) -> CGPoint {
        let control = graphControlPoints(lhs: lhs, rhs: rhs, channelID: channelID,
                                         samples: samples).out
        return CGPoint(
            x: graphXPosition(for: control.x, width: size.width),
            y: graphYPosition(for: Float(control.y), range: range, height: size.height)
        )
    }

    private func graphBezierInControlPoint(
        lhs: GraphSample,
        rhs: GraphSample,
        channelID: String,
        range: ClosedRange<Float>,
        size: CGSize,
        samples: [GraphSample]
    ) -> CGPoint {
        let control = graphControlPoints(lhs: lhs, rhs: rhs, channelID: channelID,
                                         samples: samples).incoming
        return CGPoint(
            x: graphXPosition(for: control.x, width: size.width),
            y: graphYPosition(for: Float(control.y), range: range, height: size.height)
        )
    }

    private func updatedGraphKeyframeValue(
        for property: AnimationTrackProperty,
        keyframeID: UUID,
        channelID: String,
        scalarValue: Float
    ) -> KeyframeValue {
        guard let imageID = selectedTrackTargetID,
              let existing = sceneManager.keyframes(for: imageID, property: property)
                .first(where: { $0.id == keyframeID }) else {
            switch property {
            case .translate:
                return .translate(SIMD2<Float>(scalarValue, 0))
            case .rotate:
                return .rotate(scalarValue)
            case .scale:
                return .scale(SIMD2<Float>(repeating: scalarValue))
            case .shear:
                return .shear(SIMD2<Float>(scalarValue, 0))
            case .meshDeform:
                return .meshDeform([])
            case .drawOrder:
                return .drawOrder([])
            case .event:
                return .event(.inheritingDefaults)
            default:
                switch property.valueKind {
                case .scalar:  return .scalar(property.clamped(scalarValue))
                case .flag:    return .flag(scalarValue >= 0.5)
                case .vector2: return .vector2(SIMD2<Float>(scalarValue, 0))
                case .deform, .drawOrder, .event, .attachment: return .meshDeform([])
                }
            }
        }

        switch property {
        case .translate:
            var value = existing.value.translateValue ?? .zero
            if channelID.hasSuffix(".x") {
                value.x = scalarValue
            } else {
                value.y = scalarValue
            }
            return .translate(value)
        case .rotate:
            return .rotate(scalarValue)
        case .scale:
            var value = existing.value.scaleValue ?? SIMD2<Float>(repeating: 1)
            if channelID.hasSuffix(".x") {
                value.x = max(scalarValue, 0.001)
            } else {
                value.y = max(scalarValue, 0.001)
            }
            return .scale(value)
        case .shear:
            var value = existing.value.shearValue ?? .zero
            if channelID.hasSuffix(".x") {
                value.x = scalarValue
            } else {
                value.y = scalarValue
            }
            return .shear(value)
        case .meshDeform, .drawOrder, .event, .attachment:
            return existing.value
        default:
            switch property.valueKind {
            case .scalar:
                return .scalar(property.clamped(scalarValue))
            case .flag:
                return .flag(scalarValue >= 0.5)
            case .vector2:
                var value = existing.value.simd2Value ?? .zero
                if channelID.hasSuffix(".x") {
                    value.x = scalarValue
                } else {
                    value.y = scalarValue
                }
                return .vector2(value)
            case .deform, .drawOrder, .event, .attachment:
                return existing.value
            }
        }
    }

    private func formattedGraphValue(_ value: Float) -> String {
        if abs(value.rounded() - value) < 0.0001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }

    private func nearestKeyframe(to x: CGFloat, in keyframes: [Keyframe]) -> Keyframe? {
        let hitRadius: CGFloat = 11
        return keyframes
            .filter { abs(framePosition($0.frame) - x) <= hitRadius }
            .min(by: { abs(framePosition($0.frame) - x) < abs(framePosition($1.frame) - x) })
    }

    private func framePosition(_ frame: Int) -> CGFloat {
        CGFloat(frame) * frameSpacing * zoomScale + contentLeadingInset
    }

    private func framePosition(_ frame: Double) -> CGFloat {
        CGFloat(frame) * frameSpacing * zoomScale + contentLeadingInset
    }

    private func timelineLabel(for frame: Int) -> String {
        timelineLabel(for: Double(frame))
    }

    /// The playhead's label, built WITHOUT `String(format:)`.
    ///
    /// This runs once per display tick while the playhead moves — 120 times a
    /// second on a ProMotion display — and `String(format:)` bridges through
    /// NSString to do it. The value it produces changes at most thirty times a
    /// second, so most of that work is spent producing a string identical to
    /// the last one. Interpolation of two integers costs a fraction of it and
    /// gives the same two decimal places.
    private func timelineLabel(for frame: Double) -> String {
        switch unitMode {
        case .frames:
            return "\(Int(frame.rounded()))f"
        case .seconds:
            let seconds = frame / Double(max(sceneManager.projectFramesPerSecond, 1))
            let hundredths = Int((abs(seconds) * 100).rounded())
            let sign = seconds < 0 ? "-" : ""
            return "\(sign)\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)s"
        }
    }

    private func rulerLabel(for frame: Int) -> String {
        switch unitMode {
        case .frames:
            return "\(frame)"
        case .seconds:
            return String(format: "%.1f", Double(frame) / 30.0)
        }
    }

    private func gridColor(for frame: Int) -> Color {
        if frame.isMultiple(of: 10) {
            return palette.gridStrong
        }
        if frame.isMultiple(of: 5) {
            return palette.gridSoft.opacity(0.85)
        }
        return palette.gridSoft.opacity(0.45)
    }

    private func propertyForTrack(_ track: FlattenedTimelineTrack) -> AnimationTrackProperty? {
        // A group row is an object, not a property. Without this the title
        // fallback below would read a bone named "Rotate" as a rotate track.
        guard track.node.kind == .track else { return nil }
        // Rows built by `trackRowID` embed the raw value, which is unambiguous.
        let components = track.node.id.split(separator: ".")
        if components.count >= 3, components[0] == "track", components[1] == "prop",
           let property = AnimationTrackProperty(rawValue: String(components[2])) {
            return property
        }
        switch track.node.title {
        case "Translate":
            return .translate
        case "Rotate":
            return .rotate
        case "Scale":
            return .scale
        case "Shear":
            return .shear
        case "Deform":
            return .meshDeform
        default:
            return nil
        }
    }

    private var currentSelectionRect: CGRect? {
        guard let start = selectionDragStart, let current = selectionDragCurrent else { return nil }
        let origin = CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))
        let size = CGSize(width: abs(current.x - start.x), height: abs(current.y - start.y))
        guard size.width > 2 || size.height > 2 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private var selectionBoxGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard activeKeyframeDrag == nil else { return }
                selectionDragStart = value.startLocation
                selectionDragCurrent = value.location

                if let rect = currentSelectionRect {
                    let selections = keyframes(in: rect)
                    sceneManager.setSelectedKeyframes(selections, additive: isShiftModifierPressed)
                    // The box says which bones you are working on, not only
                    // which keys. Selecting them here is what makes the canvas
                    // agree with the timeline — and it is the multi-select
                    // gesture that works with a finger, where Cmd-click cannot.
                    //
                    // Only when the box actually spans bone rows: a box drawn
                    // over sprite tracks leaves the canvas selection exactly as
                    // it was, which is what it has always done.
                    let bones = boneRows(in: rect)
                    if !bones.isEmpty {
                        sceneManager.setBoneSelection(
                            bones,
                            primary: bones.contains(where: { $0 == sceneManager.selectedBoneID })
                                ? sceneManager.selectedBoneID : bones.first,
                            additive: isShiftModifierPressed)
                    }
                }
            }
            .onEnded { _ in
                selectionDragStart = nil
                selectionDragCurrent = nil
            }
    }

    private func keyframes(in rect: CGRect) -> Set<SelectedKeyframe> {
        var selections = Set<SelectedKeyframe>()
        for (rowIndex, track) in timelineRows.enumerated() {
            guard let property = propertyForTrack(track),
                  let imageID = targetID(for: track) else { continue }
            let rowMidY = CGFloat(rowIndex) * rowHeight + (rowHeight * 0.5)
            guard rect.minY <= rowMidY, rowMidY <= rect.maxY else { continue }

            let keyframes = sceneManager.keyframes(for: imageID, property: property)
            for keyframe in keyframes {
                let x = framePosition(keyframe.frame)
                if rect.minX <= x, x <= rect.maxX {
                    selections.insert(
                        SelectedKeyframe(
                            imageID: imageID,
                            property: property,
                            keyframeID: keyframe.id
                        )
                    )
                }
            }
        }
        return selections
    }

    /// The bones whose rows the marquee spans, in row order.
    ///
    /// Row order for the same reason the hierarchy uses it: the order the
    /// artist can see is the order the selection should come out in, and it is
    /// the same twice. Deduplicated because an object's property rows all point
    /// at the same bone.
    private func boneRows(in rect: CGRect) -> [UUID] {
        var found: [UUID] = []
        var seen = Set<UUID>()
        for (rowIndex, track) in timelineRows.enumerated() {
            let rowMidY = CGFloat(rowIndex) * rowHeight + (rowHeight * 0.5)
            guard rect.minY <= rowMidY, rowMidY <= rect.maxY else { continue }
            guard let targetID = rowTargetID(from: track.node.id),
                  sceneManager.skeleton.bones[targetID] != nil,
                  seen.insert(targetID).inserted else { continue }
            found.append(targetID)
        }
        return found
    }

    /// The bone rows between the active bone and this one, in row order.
    private func shiftBoneRange(to boneID: UUID) -> [UUID] {
        var rows: [UUID] = []
        var seen = Set<UUID>()
        for track in timelineRows {
            guard let targetID = rowTargetID(from: track.node.id),
                  sceneManager.skeleton.bones[targetID] != nil,
                  seen.insert(targetID).inserted else { continue }
            rows.append(targetID)
        }
        guard let anchor = sceneManager.selectedBoneID,
              let from = rows.firstIndex(of: anchor),
              let to = rows.firstIndex(of: boneID) else { return [boneID] }
        return Array(rows[min(from, to)...max(from, to)])
    }

    private var isCommandModifierPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    private var isShiftModifierPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    /// Tapping or dragging anywhere on the ruler takes the playhead there —
    /// the same resolver the head's own drag goes through, so a tap and a drag
    /// can never land on different frames.
    private func rulerScrubGesture(contentWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isScrubbing = true
                updateCurrentFrame(at: value.location.x, contentWidth: contentWidth)
            }
            .onEnded { value in
                updateCurrentFrame(at: value.location.x, contentWidth: contentWidth)
                endScrub()
            }
    }

    /// A keyframe within this many POINTS of the pointer takes the playhead.
    ///
    /// Points, not frames, so the pull feels the same at every zoom. With snap
    /// on you already land on whole frames and therefore on keys; this is for
    /// snap OFF, where without it you stop at 11.97 and the head sits a hair
    /// off the key you were aiming at.
    private let keyMagnetPoints: CGFloat = 7

    /// Where a raw, continuous frame position actually resolves to.
    private func resolvedScrubFrame(_ raw: Double) -> Double {
        let clamped = min(max(raw, 0), Double(totalFrames))
        if isSnapEnabled {
            return clamped.rounded()
        }

        let pointsPerFrame = frameSpacing * zoomScale
        var best = clamped
        var bestPoints = keyMagnetPoints
        for frame in nearbyKeyFrames(around: clamped) {
            let distance = abs(clamped - Double(frame)) * pointsPerFrame
            if distance < bestPoints {
                best = Double(frame)
                bestPoints = distance
            }
        }
        return best
    }

    /// Key frames close enough to be worth measuring, from the rows on screen.
    private func nearbyKeyFrames(around frame: Double) -> [Int] {
        let reach = Int(ceil(Double(keyMagnetPoints) / Double(max(frameSpacing * zoomScale, 0.001)))) + 1
        let low = Int(frame.rounded()) - reach
        let high = Int(frame.rounded()) + reach
        var frames: Set<Int> = []
        for row in timelineRows where row.node.kind == .track {
            guard let candidates = row.node.frames else { continue }
            for candidate in candidates where candidate >= low && candidate <= high {
                frames.insert(candidate)
            }
        }
        return frames.sorted()
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        isScrubbing = true
        scrubStartFrame = currentFrame
    }

    /// Dragging the head is 1:1 with the pointer at any zoom: the distance
    /// moved divided by the width of a frame, and nothing else.
    private func scrub(byPoints translation: CGFloat) {
        let pointsPerFrame = Double(max(frameSpacing * zoomScale, 0.001))
        let raw = scrubStartFrame + Double(translation) / pointsPerFrame
        commitScrub(to: resolvedScrubFrame(raw))
    }

    private func endScrub() {
        isScrubbing = false
        // Hand the playhead back to the model, so it follows playback again.
        scrubFrame = nil

        // AND LAND ON A FRAME. The drag itself is continuous — that is the
        // point of it — but keyframes live on whole frames, and a playhead
        // resting at 20.6 would show the pose for 20.6 while "add keyframe"
        // wrote it onto frame 20 or 21. The pose and the key would disagree by
        // up to half a frame, silently.
        //
        // So the fraction is for the drag, and the rest position is a frame.
        // Nearest, not floor, which is where the old rounded scrub left it.
        sceneManager.setCurrentFrame(Int(sceneManager.animationTime.rounded()))
    }

    private func commitScrub(to frame: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrubFrame = frame
            sceneManager.playheadClock.frame = frame
            // The FRACTIONAL position, not `Int(frame.rounded())`.
            //
            // This function already had the sub-frame position — it computed
            // it, it moved its own line with it — and then handed the model a
            // rounded one. So the line slid and the viewport snapped, and the
            // two disagreed by up to half a frame the whole way through the
            // drag. That is the reported desynchronisation between timeline
            // and viewport, and with the clip sampled at a continuous time
            // there is nothing left to round for.
            //
            // `currentFrame` still follows as a whole number inside
            // `setAnimationTime`, because that is what selects a keyframe.
            // Only the pose is continuous.
            sceneManager.setAnimationTime(frame)
        }
    }

    private func updateCurrentFrame(at x: CGFloat, contentWidth: CGFloat) {
        let clampedX = min(max(x - contentLeadingInset, 0), contentWidth)
        let raw = Double(clampedX / max(contentWidth, 1)) * Double(totalFrames)
        commitScrub(to: resolvedScrubFrame(raw))
    }

    private func flatten(node: TimelineTrackNode, depth: Int) -> [FlattenedTimelineTrack] {
        let current = FlattenedTimelineTrack(node: node, depth: depth)
        return [current] + node.children.flatMap { flatten(node: $0, depth: depth + 1) }
    }

    private var emptyTimelineState: some View {
        VStack(spacing: 14) {
            Image(systemName: selectedAnimationTargetID == nil ? "timeline.selection" : "diamond")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(palette.secondaryText)

            Text(selectedAnimationTargetID == nil ? "Timeline ready to start" : "Clean clip, no keyframes yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Text(selectedAnimationTargetID == nil
                 ? "Import a PNG and select an object to create your first clip."
                 : "This object already has its base tracks prepared. Start by adding your first keys.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }
}

private struct TransportButton: View {
    let systemImage: String
    var isProminent = false
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isProminent ? Color.black.opacity(0.82) : TimelinePalette.default.primaryText)
            .frame(width: 28, height: 28)
            .background(isProminent ? TimelinePalette.default.accent : TimelinePalette.default.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TimelinePalette.default.separator, lineWidth: isProminent ? 0 : 1)
            )
    }
}

/// Keyframe marker.
///
/// The shape encodes the interpolation leaving the key, the way a dope sheet
/// does: stepped keys are squares, everything else is a diamond. Bézier
/// keys additionally carry a bright core so a curve-edited key is legible at a
/// glance without opening the graph editor.
private struct DiamondKeyframe: View {
    let color: Color
    let isSelected: Bool
    var interpolation: KeyframeInterpolation = .linear

    private var isStepped: Bool { interpolation == .hold }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isSelected ? color : color.opacity(0.92))
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? UM.textPrimary.opacity(0.85) : color.opacity(0.35), lineWidth: 1)
                )
                .rotationEffect(.degrees(isStepped ? 0 : 45))
                .scaleEffect(isStepped ? 0.82 : 1)

            if interpolation == .bezier {
                Circle()
                    .fill(UM.textPrimary.opacity(isSelected ? 0.95 : 0.65))
                    .frame(width: 3.5, height: 3.5)
            }
        }
        .shadow(color: color.opacity(isSelected ? 0.34 : 0.14), radius: isSelected ? 6 : 0)
    }
}

private struct ActiveKeyframeDrag: Equatable {
    let anchor: SelectedKeyframe
    let startFrames: [SelectedKeyframe: Int]
}

private struct ActiveGraphPointDrag: Equatable {
    let selection: SelectedKeyframe
    let initialFrame: Int
    let initialValue: Float
}

private enum GraphHandleKind {
    case `in`
    case out
}

private struct ActiveGraphHandleDrag: Equatable {
    let keyframeID: UUID
    let channelID: String
    let handle: GraphHandleKind
    let initialTangent: SIMD2<Float>
}

private struct ActiveCurveSegmentDrag: Equatable {
    let channelID: String
    let lhsKeyframeID: UUID
    let rhsKeyframeID: UUID
    let initialLhsOutTangent: SIMD2<Float>
    let initialRhsInTangent: SIMD2<Float>
}

private struct GraphChannel: Identifiable {
    let id: String
    let title: String
    let color: Color
    let samples: [GraphSample]

    init(id: String = UUID().uuidString, title: String, color: Color, samples: [GraphSample]) {
        self.id = id
        self.title = title
        self.color = color
        self.samples = samples.sorted { $0.frame < $1.frame }
    }
}

/// How the timeline is divided, in one place.
///
/// Two columns — names, then a one-point separator, then the grid — and two
/// rows: a pinned header over a scrolling body. Every one of those numbers used
/// to be typed out where it was needed, and the two that were typed out more
/// than once were the two that drifted.
///
/// The separator was the worse of them, because it was not forgotten in one
/// place: it was NEVER counted. The header laid the ruler out after it, so the
/// ruler began at 181; the body offset its grid by 180 and the playhead took
/// 180 as its left edge. The ruler and the lanes it labels were one point
/// apart at every frame and every zoom, and on iPad the whole timeline is
/// drawn inside a `ScaledContainer`, which divides by the interface scale — so
/// that one point becomes 1.2 at 0.82 and 1.5 at 0.65. Changing the interface
/// size does not cause the misalignment; it magnifies one that was always
/// there, which is why it is noticed by changing the layout.
enum TimelineMetrics {
    /// One track lane.
    static let rowHeight: CGFloat = 28
    /// The pinned header: the names heading and the ruler.
    ///
    /// Read by the header AND by `bodyHeight = height - headerHeight`, which is
    /// how the body knows where the header stopped. Those two were separate
    /// literals, so changing one made the two overlap.
    static let headerHeight: CGFloat = 40
    /// The frozen names column.
    static let labelsWidth: CGFloat = 180
    /// The hairline between the columns.
    static let separatorWidth: CGFloat = 1

    /// Where the grid starts — after the names column AND the separator.
    ///
    /// THE origin. Anything that has to sit over a frame — a ruler tick, a
    /// keyframe diamond, the playhead — measures from this and from nothing
    /// else, so they cannot be one point apart.
    static var gridLeadingInset: CGFloat { labelsWidth + separatorWidth }
}

private struct GraphSample: Identifiable {
    let id: UUID
    let keyframeID: UUID
    let frame: Int
    let value: Float
    let interpolation: KeyframeInterpolation
    /// THIS CHANNEL'S tangents, carried rather than looked up.
    ///
    /// Drawing a Bézier control point used to call `graphKeyframe(keyframeID)`,
    /// which fetches the track's keyframes and scans them for a matching id —
    /// a linear scan, run twice per segment, inside a bounds computation that
    /// was itself run once per drawn element. The sample is BUILT from the
    /// keyframe, so it can simply keep the two numbers it will be asked for.
    ///
    /// A keyframe holds two pairs: the primary pair for x and scalar channels,
    /// the secondary pair for y. Which pair belongs to this channel is decided
    /// once, here, where the channel is known.
    let outTangent: SIMD2<Float>?
    let inTangent: SIMD2<Float>?

    /// `channelID` rather than a Bool, so the pair is chosen by the SAME rule
    /// the rest of the editor uses. Passing a flag meant restating that rule at
    /// eleven call sites, and restating it is how `constraint.flag` — which is
    /// neither `.x` nor `.scalar`, and so takes the secondary pair — ended up
    /// on the primary one the first time this was written.
    init(keyframe: Keyframe, value: Float, channelID: String) {
        self.init(keyframe: keyframe, value: value,
                  usesPrimaryTangents: GraphSample.usesPrimaryTangents(channelID))
    }

    /// The one rule. `TimelineView.channelUsesPrimaryTangents` calls this.
    static func usesPrimaryTangents(_ channelID: String) -> Bool {
        channelID.hasSuffix(".x") || channelID.hasSuffix(".scalar")
    }

    private init(keyframe: Keyframe, value: Float, usesPrimaryTangents: Bool) {
        self.id = keyframe.id
        self.keyframeID = keyframe.id
        self.frame = keyframe.frame
        self.value = value
        self.interpolation = keyframe.interpolation
        self.outTangent = usesPrimaryTangents ? keyframe.outTangent : keyframe.secondaryOutTangent
        self.inTangent = usesPrimaryTangents ? keyframe.inTangent : keyframe.secondaryInTangent
    }
}

private enum TimelineUnitMode: String, CaseIterable, Identifiable {
    case frames
    case seconds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frames: return "Frames"
        case .seconds: return "Seconds"
        }
    }
}

private enum TimelineFilter: String, CaseIterable, Identifiable {
    case all
    case keyed
    case transforms
    case selected
    case events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Tracks"
        case .keyed: return "Keyed Only"
        case .transforms: return "Transforms"
        case .selected: return "Selected"
        case .events: return "Events / Audio"
        }
    }
}

private struct TimelineTrackNode: Identifiable {
    enum Kind {
        case group
        case track
    }

    let id: String
    let title: String
    let subtitle: String?
    let tint: Color
    let kind: Kind
    let children: [TimelineTrackNode]
    let frames: [Int]?

    init(
        id: String,
        title: String,
        subtitle: String?,
        tint: Color,
        kind: Kind,
        children: [TimelineTrackNode] = [],
        frames: [Int]? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.kind = kind
        self.children = children
        self.frames = frames
    }

    static func track(id: String, title: String, tint: Color, frames: [Int]) -> TimelineTrackNode {
        TimelineTrackNode(
            id: id,
            title: title,
            subtitle: nil,
            tint: tint,
            kind: .track,
            children: [],
            frames: frames
        )
    }
}

/// Memo for the track tree. A class so a body evaluation can fill it without
/// that write counting as a state change.
private final class TrackTreeCache {
    var signature: Int?
    var nodes: [TimelineTrackNode]?
}

private struct FlattenedTimelineTrack: Identifiable {
    let node: TimelineTrackNode
    let depth: Int

    var id: String { node.id }
}

private struct TimelinePalette {
    let background: Color
    let panel: Color
    let rowA: Color
    let rowB: Color
    let selection: Color
    let separator: Color
    let gridSoft: Color
    let gridStrong: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let playhead: Color
    let loop: Color
    let onion: Color
    let graph: Color
    let workRange: Color
    let object: Color
    let transform: Color
    let rotation: Color
    let scale: Color
    let skew: Color
    let visibility: Color
    let attachment: Color
    let bone: Color
    let constraint: Color
    let deform: Color
    let event: Color
    let audio: Color

    static let `default` = TimelinePalette(
        background: UM.appBackground,
        panel: UM.surface,
        rowA: UM.surface,
        rowB: UM.surfaceRaised,
        selection: Color(red: 0.34, green: 0.52, blue: 0.78).opacity(0.18),
        separator: UM.textPrimary.opacity(0.095),
        gridSoft: UM.textPrimary.opacity(0.05),
        gridStrong: UM.textPrimary.opacity(0.12),
        primaryText: UM.textPrimary.opacity(0.95),
        secondaryText: UM.textPrimary.opacity(0.70),
        tertiaryText: UM.textPrimary.opacity(0.42),
        accent: Color(red: 0.86, green: 0.44, blue: 0.89),
        playhead: Color(red: 1.0, green: 0.66, blue: 0.32),
        loop: Color(red: 0.54, green: 0.76, blue: 0.62),
        onion: Color(red: 0.80, green: 0.66, blue: 0.36),
        graph: Color(red: 0.45, green: 0.80, blue: 0.89),
        workRange: Color(red: 0.55, green: 0.67, blue: 0.86),
        object: Color(red: 0.77, green: 0.80, blue: 0.88),
        transform: UM.channelTranslate,
        rotation: UM.channelRotate,
        scale: UM.channelScale,
        skew: UM.channelShear,
        visibility: Color(red: 0.84, green: 0.56, blue: 0.90),
        attachment: Color(red: 0.94, green: 0.37, blue: 0.78),
        bone: Color(red: 0.43, green: 0.82, blue: 0.72),
        constraint: Color(red: 0.89, green: 0.53, blue: 0.90),
        deform: Color(red: 0.33, green: 0.77, blue: 0.60),
        event: Color(red: 0.95, green: 0.75, blue: 0.36),
        audio: Color(red: 0.83, green: 0.49, blue: 0.88)
    )
}

private extension KeyframeValue {
    var translateValue: SIMD2<Float>? {
        guard case let .translate(value) = self else { return nil }
        return value
    }

    var rotateValue: Float? {
        guard case let .rotate(value) = self else { return nil }
        return value
    }

    var scaleValue: SIMD2<Float>? {
        guard case let .scale(value) = self else { return nil }
        return value
    }

    var shearValue: SIMD2<Float>? {
        guard case let .shear(value) = self else { return nil }
        return value
    }
}

#if os(macOS)
private struct TimelineScrollHost<Content: View>: NSViewRepresentable {
    @Binding var contentOffset: CGPoint
    @Binding var viewportSize: CGSize
    let contentSize: CGSize
    let content: Content

    init(
        contentOffset: Binding<CGPoint>,
        viewportSize: Binding<CGSize>,
        contentSize: CGSize,
        @ViewBuilder content: () -> Content
    ) {
        _contentOffset = contentOffset
        _viewportSize = viewportSize
        self.contentSize = contentSize
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let hostingView = FlippedHostingContainer(rootView: content, size: contentSize)
        scrollView.documentView = hostingView

        context.coordinator.scrollView = scrollView
        context.coordinator.hostingView = hostingView
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.handleScrollChange()
        }

        DispatchQueue.main.async {
            viewportSize = scrollView.contentView.bounds.size
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onScrollChange = { offset, size in
            if contentOffset != offset {
                contentOffset = offset
            }
            if viewportSize != size {
                viewportSize = size
            }
        }

        context.coordinator.hostingView?.rootView = content
        context.coordinator.hostingView?.updateSize(contentSize)

        let boundedOffset = CGPoint(
            x: min(max(contentOffset.x, 0), max(contentSize.width - nsView.contentView.bounds.width, 0)),
            y: min(max(contentOffset.y, 0), max(contentSize.height - nsView.contentView.bounds.height, 0))
        )
        let currentOffset = nsView.contentView.bounds.origin

        if abs(currentOffset.x - boundedOffset.x) > 0.5 || abs(currentOffset.y - boundedOffset.y) > 0.5 {
            context.coordinator.isSyncing = true
            nsView.contentView.scroll(to: boundedOffset)
            nsView.reflectScrolledClipView(nsView.contentView)
            context.coordinator.isSyncing = false
        }
    }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var hostingView: FlippedHostingContainer<Content>?
        var observer: NSObjectProtocol?
        var isSyncing = false
        var onScrollChange: ((CGPoint, CGSize) -> Void)?

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func handleScrollChange() {
            guard let scrollView, !isSyncing else { return }
            onScrollChange?(scrollView.contentView.bounds.origin, scrollView.contentView.bounds.size)
        }
    }
}

private final class FlippedHostingContainer<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>

    override var isFlipped: Bool { true }

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    init(rootView: Content, size: CGSize) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: CGRect(origin: .zero, size: size))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSize(_ size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        hostingView.frame = bounds
    }
}
#else
// MARK: - iOS scroll host (UIScrollView-based)
private struct TimelineScrollHost<Content: View>: UIViewRepresentable {
    @Binding var contentOffset: CGPoint
    @Binding var viewportSize: CGSize
    let contentSize: CGSize
    let content: Content

    init(
        contentOffset: Binding<CGPoint>,
        viewportSize: Binding<CGSize>,
        contentSize: CGSize,
        @ViewBuilder content: () -> Content
    ) {
        _contentOffset = contentOffset
        _viewportSize = viewportSize
        self.contentSize = contentSize
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator

        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .clear
        hosting.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.addSubview(hosting.view)
        scrollView.contentSize = contentSize

        context.coordinator.scrollView = scrollView
        context.coordinator.hostingController = hosting

        DispatchQueue.main.async { viewportSize = scrollView.bounds.size }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController?.rootView = content
        context.coordinator.hostingController?.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize

        context.coordinator.onScrollChange = { offset, size in
            if contentOffset != offset { contentOffset = offset }
            if viewportSize != size { viewportSize = size }
        }

        // This method used to end with an unconditional
        //   DispatchQueue.main.async { viewportSize = scrollView.bounds.size }
        // The write re-rendered, the re-render called updateUIView, and that
        // scheduled the write again: a loop that never settled, with the whole
        // track list rebuilt on each pass. Size is reported from the delegate
        // and from makeUIView, and only when it has actually changed.
        if viewportSize != scrollView.bounds.size {
            let size = scrollView.bounds.size
            DispatchQueue.main.async { viewportSize = size }
        }

        // Never push an offset while the user has the gesture. The clamp below
        // is exactly what rubber-band overscroll looks like — live y below
        // zero, clamped y zero — so this used to yank every bounce flat
        // mid-drag. macOS has had an isSyncing guard for this; iOS had none.
        guard !context.coordinator.isUserDriving else { return }

        let w = max(contentSize.width - scrollView.bounds.width, 0)
        let h = max(contentSize.height - scrollView.bounds.height, 0)
        let bounded = CGPoint(x: min(max(contentOffset.x, 0), w), y: min(max(contentOffset.y, 0), h))
        if abs(scrollView.contentOffset.x - bounded.x) > 0.5 || abs(scrollView.contentOffset.y - bounded.y) > 0.5 {
            context.coordinator.isSyncing = true
            scrollView.setContentOffset(bounded, animated: false)
            context.coordinator.isSyncing = false
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        var hostingController: UIHostingController<Content>?
        var onScrollChange: ((CGPoint, CGSize) -> Void)?
        /// Set while we move the scroll view ourselves, so the delegate does
        /// not echo our own write straight back into SwiftUI state.
        var isSyncing = false
        /// True from the first touch until deceleration ends.
        var isUserDriving = false

        func scrollViewDidScroll(_ sv: UIScrollView) {
            guard !isSyncing else { return }
            onScrollChange?(sv.contentOffset, sv.bounds.size)
        }

        func scrollViewWillBeginDragging(_ sv: UIScrollView) {
            isUserDriving = true
        }

        func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate: Bool) {
            if !willDecelerate { isUserDriving = false }
        }

        func scrollViewDidEndDecelerating(_ sv: UIScrollView) {
            isUserDriving = false
        }

        func scrollViewDidEndScrollingAnimation(_ sv: UIScrollView) {
            isUserDriving = false
        }
    }
}
#endif

#Preview {
    TimelineView(sceneManager: SceneManager())
        .environmentObject(AppState())
}
