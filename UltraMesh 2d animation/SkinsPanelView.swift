import SwiftUI

/// Skins panel.
///
/// Two halves, matching how skins are actually authored. The top half
/// manages the skins themselves; the bottom half is the slot table, where each
/// variant point shows the sprite the active skin puts in it.
///
/// Slots are not created explicitly: a slot exists as soon as two sprites share
/// a slot name, so the panel's job is to make that grouping easy and then let
/// the artist pick per skin.
struct SkinsPanelView: View {
    @ObservedObject var sceneManager: SceneManager

    @State private var renamingSkinID: UUID?
    @State private var renameText: String = ""
    @State private var newSlotName: String = ""

    private let accent = Color(red: 0.62, green: 0.78, blue: 1.00)
    private let panelFill = UM.textPrimary.opacity(0.04)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                skinListSection
                Divider().overlay(UM.textPrimary.opacity(0.06))
                slotGroupingSection
                Divider().overlay(UM.textPrimary.opacity(0.06))
                slotTableSection
            }
            .padding(12)
        }
    }

    // MARK: - Skins

    private var skinListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("SKINS")
                Spacer()
                Button {
                    sceneManager.createSkin()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }

            // The setup arrangement is always available and is not a skin; it is
            // what shows when no skin is active.
            skinRow(
                id: nil,
                name: "Setup",
                subtitle: "No skin — authored arrangement",
                isActive: sceneManager.activeSkinID == nil
            )

            ForEach(sceneManager.skins) { skin in
                skinRow(
                    id: skin.id,
                    name: skin.name,
                    subtitle: subtitle(for: skin),
                    isActive: sceneManager.activeSkinID == skin.id
                )
            }

            if sceneManager.skins.isEmpty {
                Text("No skins yet. Create one to swap between sprite variants.")
                    .font(.system(size: 10))
                    .foregroundStyle(UM.textPrimary.opacity(0.4))
                    .padding(.top, 2)
            }
        }
    }

    private func subtitle(for skin: Skin) -> String {
        var parts: [String] = []
        let described = skin.attachments.count
        parts.append("\(described) slot\(described == 1 ? "" : "s")")
        if !skin.includedSkinIDs.isEmpty {
            let names = skin.includedSkinIDs.compactMap { id in
                sceneManager.skins.first(where: { $0.id == id })?.name
            }
            if !names.isEmpty {
                parts.append("includes \(names.joined(separator: ", "))")
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func skinRow(id: UUID?, name: String, subtitle: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? accent : UM.textPrimary.opacity(0.3))

            VStack(alignment: .leading, spacing: 1) {
                if let id, renamingSkinID == id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .onSubmit {
                            sceneManager.renameSkin(id, to: renameText)
                            renamingSkinID = nil
                        }
                } else {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.9))
                }
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(UM.textPrimary.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let id {
                Menu {
                    Button("Rename") {
                        renameText = name
                        renamingSkinID = id
                    }
                    Button("Duplicate") { sceneManager.duplicateSkin(id) }
                    Button("Capture Current Arrangement") {
                        sceneManager.captureCurrentArrangement(into: id)
                    }

                    let candidates = sceneManager.skins.filter { $0.id != id }
                    if !candidates.isEmpty {
                        Menu("Include Skin") {
                            ForEach(candidates) { candidate in
                                Button(candidate.name) {
                                    sceneManager.addSkinInclusion(skinID: id, includedID: candidate.id)
                                }
                            }
                        }
                    }

                    let included = sceneManager.skins.first(where: { $0.id == id })?.includedSkinIDs ?? []
                    if !included.isEmpty {
                        Menu("Stop Including") {
                            ForEach(included, id: \.self) { includedID in
                                let includedName = sceneManager.skins
                                    .first(where: { $0.id == includedID })?.name ?? "Skin"
                                Button(includedName) {
                                    sceneManager.removeSkinInclusion(skinID: id, includedID: includedID)
                                }
                            }
                        }
                    }

                    Divider()
                    Button("Delete", role: .destructive) { sceneManager.deleteSkin(id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UM.textPrimary.opacity(0.45))
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? accent.opacity(0.12) : panelFill)
        )
        .contentShape(Rectangle())
        .onTapGesture { sceneManager.setActiveSkin(id) }
    }

    // MARK: - Grouping sprites into a slot

    private var slotGroupingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("GROUP SELECTION INTO A SLOT")

            Text("Select the sprite variants in the hierarchy, name the slot, and group them. Only one sprite of a slot is shown at a time.")
                .font(.system(size: 9))
                .foregroundStyle(UM.textPrimary.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("Slot name", text: $newSlotName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(UM.textPrimary.opacity(0.06))
                    )

                Button("Group") {
                    sceneManager.assignSlot(newSlotName, to: Array(sceneManager.selectedImageIDs))
                    newSlotName = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(canGroup ? accent : UM.textPrimary.opacity(0.25))
                .disabled(!canGroup)
            }
        }
    }

    private var canGroup: Bool {
        !newSlotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sceneManager.selectedImageIDs.isEmpty
    }

    // MARK: - Slot table

    private var slotTableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SLOTS")

            let slots = sceneManager.variantSlotNames
            if slots.isEmpty {
                Text("No variant slots. A slot appears once two or more sprites share a slot name.")
                    .font(.system(size: 10))
                    .foregroundStyle(UM.textPrimary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(slots, id: \.self) { slot in
                    slotRow(slot)
                }
            }
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: String) -> some View {
        let members = sceneManager.slotMembers[slot] ?? []
        let resolved = sceneManager.skinResolution.slots[slot] ?? nil
        let activeSkinID = sceneManager.activeSkinID
        let isOverridden = activeSkinID
            .flatMap { id in sceneManager.skins.first(where: { $0.id == id })?.attachments[slot] } != nil

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(slot)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UM.textPrimary.opacity(0.75))
                // A dot marks slots this skin overrides itself, as opposed to
                // ones it inherits or leaves at the setup arrangement.
                if isOverridden {
                    Circle()
                        .fill(accent)
                        .frame(width: 4, height: 4)
                }
                Spacer(minLength: 0)
                Text("\(members.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(UM.textPrimary.opacity(0.35))
            }

            if let activeSkinID {
                Menu {
                    Button("Empty") {
                        sceneManager.setSkinAttachment(skinID: activeSkinID, slot: slot, imageID: nil)
                    }
                    Divider()
                    ForEach(members, id: \.self) { memberID in
                        let memberName = sceneManager.image(for: memberID)?.name ?? "Sprite"
                        Button(memberName) {
                            sceneManager.setSkinAttachment(
                                skinID: activeSkinID,
                                slot: slot,
                                imageID: memberID
                            )
                        }
                    }
                    if isOverridden {
                        Divider()
                        Button("Inherit") {
                            sceneManager.clearSkinAttachment(skinID: activeSkinID, slot: slot)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(resolvedLabel(resolved))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(UM.textPrimary.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(UM.textPrimary.opacity(0.35))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(UM.textPrimary.opacity(0.06))
                    )
                }
                .menuIndicator(.hidden)
            } else {
                // Setup arrangement is read-only here: it is driven by the
                // sprites' own hide toggles, not by a skin.
                Text(resolvedLabel(resolved))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(UM.textPrimary.opacity(0.55))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(panelFill)
        )
    }

    private func resolvedLabel(_ imageID: UUID?) -> String {
        guard let imageID else { return "Empty" }
        return sceneManager.image(for: imageID)?.name ?? "Missing sprite"
    }

    // MARK: - Shared

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .kerning(0.6)
            .foregroundStyle(UM.textPrimary.opacity(0.45))
    }
}
