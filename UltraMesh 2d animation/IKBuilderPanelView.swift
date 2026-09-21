import SwiftUI

// ======================================================================
// Design tokens
//
// Deliberately not system materials or stock controls: the panel floats over
// the viewport and has to read as part of UltraMesh, not as a sheet the OS
// dropped on top of it.
// ======================================================================

enum IKBuilderStyle {
    static let chainAccent  = Color(red: 0.68, green: 0.48, blue: 1.00)
    static let targetAccent = Color(red: 1.00, green: 0.72, blue: 0.24)
    static let okAccent     = Color(red: 0.36, green: 0.88, blue: 0.56)
    static let errAccent    = Color(red: 1.00, green: 0.42, blue: 0.38)

    static let panelTop     = Color(white: 0.155)
    static let panelBottom  = Color(white: 0.115)
    static let wellFill     = Color.white.opacity(0.035)
    static let hairline     = Color.white.opacity(0.10)
    static let corner: CGFloat = 14
}

/// Floating, NON-modal builder for an IK constraint.
///
/// Non-modal is the whole point: the artist keeps clicking bones in the canvas
/// while it is open. A sheet would block exactly the interaction the panel
/// exists to support.
struct IKBuilderPanelView: View {
    @ObservedObject var sceneManager: SceneManager

    @State private var chainListExpanded = false
    @State private var targetListExpanded = false
    @State private var chainSearch = ""
    @State private var targetSearch = ""

    var body: some View {
        if let draft = sceneManager.ikBuilder {
            content(draft)
                .frame(width: 320)
                .background(panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: IKBuilderStyle.corner, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
        }
    }

    // MARK: Shell

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: IKBuilderStyle.corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [IKBuilderStyle.panelTop, IKBuilderStyle.panelBottom],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: IKBuilderStyle.corner, style: .continuous)
                    .stroke(IKBuilderStyle.hairline, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func content(_ draft: IKBuilderDraft) -> some View {
        let validation = sceneManager.ikBuilderValidation

        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            VStack(alignment: .leading, spacing: 14) {
                chainStep(draft)
                targetStep(draft)
                optionsStep(draft)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)

            divider
            statusArea(draft, validation)
            footer(validation)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("IK")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(IKBuilderStyle.chainAccent)
                )

            Text("New IK Constraint")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))

            Spacer(minLength: 0)

            Button(action: { sceneManager.cancelIKBuilder() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    // MARK: Step 1 — chain

    @ViewBuilder
    private func chainStep(_ draft: IKBuilderDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IKStepHeader(
                index: 1,
                title: "Chain",
                subtitle: "The bones that bend",
                accent: IKBuilderStyle.chainAccent,
                isComplete: !draft.chain.isEmpty
            )

            if draft.chain.isEmpty {
                IKEmptyWell(
                    text: draft.pickingSlot == .chain
                        ? "Click a bone in the canvas"
                        : "No bones yet",
                    isArmed: draft.pickingSlot == .chain
                )
            } else {
                IKChainChips(
                    boneIDs: draft.chain,
                    skeleton: sceneManager.skeleton,
                    accent: IKBuilderStyle.chainAccent,
                    onRemove: { id in
                        let next = IKBuilderRules.addToChain(
                            id, chain: draft.chain, skeleton: sceneManager.skeleton)
                        sceneManager.ikBuilderSetChain(next)
                    }
                )
            }

            HStack(spacing: 7) {
                IKPillButton(
                    title: draft.pickingSlot == .chain ? "Picking…" : "Pick on canvas",
                    icon: "hand.tap",
                    accent: IKBuilderStyle.chainAccent,
                    isActive: draft.pickingSlot == .chain
                ) {
                    sceneManager.ikBuilderSetPicking(.chain)
                    if sceneManager.ikBuilder?.pickingSlot == .chain { targetListExpanded = false }
                }

                IKPillButton(
                    title: "List",
                    icon: chainListExpanded ? "chevron.up" : "chevron.down",
                    accent: IKBuilderStyle.chainAccent,
                    isActive: chainListExpanded
                ) {
                    chainListExpanded.toggle()
                    if chainListExpanded { targetListExpanded = false }
                }

                if !draft.chain.isEmpty {
                    IKPillButton(title: "Clear", icon: "xmark", accent: Color.white.opacity(0.5), isActive: false) {
                        sceneManager.ikBuilderSetChain([])
                    }
                }
                Spacer(minLength: 0)
            }

            if chainListExpanded {
                IKBoneList(
                    bones: IKBuilderRules.hierarchicalOrder(skeleton: sceneManager.skeleton),
                    search: $chainSearch,
                    accent: IKBuilderStyle.chainAccent,
                    selectedIDs: Set(draft.chain),
                    onPick: { id in
                        let next = IKBuilderRules.addToChain(
                            id, chain: draft.chain, skeleton: sceneManager.skeleton)
                        sceneManager.ikBuilderSetChain(next)
                    }
                )
            }
        }
    }

    // MARK: Step 2 — target

    @ViewBuilder
    private func targetStep(_ draft: IKBuilderDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IKStepHeader(
                index: 2,
                title: "Target",
                subtitle: "What the chain reaches for",
                accent: IKBuilderStyle.targetAccent,
                isComplete: draft.targetID != nil
            )

            if let targetID = draft.targetID, let bone = sceneManager.skeleton.bone(targetID) {
                IKBoneChip(
                    name: bone.name,
                    accent: IKBuilderStyle.targetAccent,
                    onRemove: { sceneManager.ikBuilderSetTarget(nil) }
                )
            } else {
                IKEmptyWell(
                    text: draft.pickingSlot == .target
                        ? "Click the target bone in the canvas"
                        : "No target yet",
                    isArmed: draft.pickingSlot == .target
                )
            }

            HStack(spacing: 7) {
                IKPillButton(
                    title: draft.pickingSlot == .target ? "Picking…" : "Pick on canvas",
                    icon: "hand.tap",
                    accent: IKBuilderStyle.targetAccent,
                    isActive: draft.pickingSlot == .target
                ) {
                    sceneManager.ikBuilderSetPicking(.target)
                    if sceneManager.ikBuilder?.pickingSlot == .target { chainListExpanded = false }
                }

                IKPillButton(
                    title: "List",
                    icon: targetListExpanded ? "chevron.up" : "chevron.down",
                    accent: IKBuilderStyle.targetAccent,
                    isActive: targetListExpanded
                ) {
                    targetListExpanded.toggle()
                    if targetListExpanded { chainListExpanded = false }
                }
                Spacer(minLength: 0)
            }

            if targetListExpanded {
                IKBoneList(
                    bones: IKBuilderRules.hierarchicalOrder(skeleton: sceneManager.skeleton),
                    search: $targetSearch,
                    accent: IKBuilderStyle.targetAccent,
                    selectedIDs: draft.targetID.map { Set([$0]) } ?? [],
                    onPick: { id in
                        sceneManager.ikBuilderSetTarget(id)
                        targetListExpanded = false
                    }
                )
            }
        }
    }

    // MARK: Step 3 — options

    @ViewBuilder
    private func optionsStep(_ draft: IKBuilderDraft) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            IKStepHeader(
                index: 3,
                title: "Options",
                subtitle: "Tune it now or later",
                accent: Color.white.opacity(0.45),
                isComplete: true
            )

            HStack(spacing: 8) {
                Text("Name")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 46, alignment: .leading)

                TextField("", text: Binding(
                    get: { draft.name },
                    set: { sceneManager.ikBuilderSetName($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(IKBuilderStyle.wellFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(IKBuilderStyle.hairline, lineWidth: 1)
                        )
                )
            }

            HStack(spacing: 8) {
                Text("Bend")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 46, alignment: .leading)

                IKSegmented(
                    options: ["Positive", "Negative"],
                    selectedIndex: draft.bendPositive ? 0 : 1,
                    accent: IKBuilderStyle.chainAccent
                ) { index in
                    sceneManager.ikBuilderSetBendPositive(index == 0)
                }
            }

            HStack(spacing: 8) {
                Text("Mix")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 46, alignment: .leading)

                CapsuleSlider(
                    value: Binding(
                        get: { Double(draft.mix) },
                        set: { sceneManager.ikBuilderSetMix(Float($0)) }
                    ),
                    in: 0...1
                )
                .frame(height: 20)

                Text("\(Int((draft.mix * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private func statusArea(_ draft: IKBuilderDraft, _ validation: IKBuilderValidation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(IKBuilderRules.summary(draft, skeleton: sceneManager.skeleton))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(validation.canCreate ? 0.82 : 0.55))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(validation.problems) { problem in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: problem.isBlocking ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(problem.isBlocking ? IKBuilderStyle.errAccent : Color.white.opacity(0.4))
                        .padding(.top, 1)
                    Text(problem.message)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(problem.isBlocking ? 0.78 : 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ validation: IKBuilderValidation) -> some View {
        HStack(spacing: 8) {
            Button(action: { sceneManager.cancelIKBuilder() }) {
                Text("Cancel")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: { sceneManager.commitIKBuilder() }) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                    Text("Create Constraint")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(validation.canCreate ? Color.black.opacity(0.85) : Color.white.opacity(0.3))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(validation.canCreate
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [IKBuilderStyle.chainAccent,
                                             IKBuilderStyle.chainAccent.opacity(0.82)],
                                    startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.white.opacity(0.05)))
                )
            }
            .buttonStyle(.plain)
            .disabled(!validation.canCreate)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

// ======================================================================
// Small parts
// ======================================================================

private struct IKStepHeader: View {
    let index: Int
    let title: String
    let subtitle: String
    let accent: Color
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(isComplete ? accent.opacity(0.9) : Color.white.opacity(0.08))
                    .frame(width: 16, height: 16)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.8))
                } else {
                    Text("\(index)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.38))

            Spacer(minLength: 0)
        }
    }
}

private struct IKEmptyWell: View {
    let text: String
    let isArmed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isArmed ? "cursorarrow.click" : "circle.dashed")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white.opacity(isArmed ? 0.72 : 0.34))
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(IKBuilderStyle.wellFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isArmed ? Color.white.opacity(0.22) : Color.white.opacity(0.07),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
        )
    }
}

private struct IKBoneChip: View {
    let name: String
    let accent: Color
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(accent.opacity(0.42), lineWidth: 1)
                )
        )
    }
}

/// The chain in order, root → tip, with arrows between links.
///
/// Order is the whole reason this is not a plain unordered list: which end is
/// the root decides which way the limb bends.
private struct IKChainChips: View {
    let boneIDs: [UUID]
    let skeleton: Skeleton
    let accent: Color
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(boneIDs.enumerated()), id: \.element) { pair in
                HStack(spacing: 6) {
                    Text(pair.offset == 0 ? "root" : (pair.offset == boneIDs.count - 1 ? "tip" : "  ↓"))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.33))
                        .frame(width: 26, alignment: .leading)

                    IKBoneChip(
                        name: skeleton.bone(pair.element)?.name ?? "?",
                        accent: accent,
                        onRemove: { onRemove(pair.element) }
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct IKPillButton: View {
    let title: String
    let icon: String
    let accent: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.white.opacity(0.7))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? accent.opacity(0.92) : Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isActive ? Color.clear : IKBuilderStyle.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IKSegmented: View {
    let options: [String]
    let selectedIndex: Int
    let accent: Color
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { pair in
                Button(action: { onSelect(pair.offset) }) {
                    Text(pair.element)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(pair.offset == selectedIndex
                                         ? Color.black.opacity(0.85)
                                         : Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(pair.offset == selectedIndex ? accent.opacity(0.9) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(IKBuilderStyle.wellFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(IKBuilderStyle.hairline, lineWidth: 1)
                )
        )
    }
}

/// Searchable bone list, inline rather than a popover so it never steals the
/// clicks the canvas is waiting for.
private struct IKBoneList: View {
    let bones: [IKBuilderRules.OrderedBone]
    @Binding var search: String
    let accent: Color
    let selectedIDs: Set<UUID>
    let onPick: (UUID) -> Void

    private var filtered: [IKBuilderRules.OrderedBone] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return bones }
        return bones.filter { $0.bone.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
                TextField("Search bones", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { entry in
                        Button(action: { onPick(entry.bone.id) }) {
                            HStack(spacing: 6) {
                                // Indent by hierarchy depth: finding the right
                                // "arm_2" is guesswork in a flat list.
                                Spacer().frame(width: CGFloat(entry.depth) * 10)
                                Circle()
                                    .fill(selectedIDs.contains(entry.bone.id) ? accent : Color.white.opacity(0.18))
                                    .frame(width: 5, height: 5)
                                Text(entry.bone.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if selectedIDs.contains(entry.bone.id) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(accent)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: 148)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(IKBuilderStyle.hairline, lineWidth: 1)
                )
        )
    }
}
