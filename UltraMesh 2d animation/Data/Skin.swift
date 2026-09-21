import Foundation

/// A named set of attachment choices, one per slot.
///
/// The slot/skin model. A slot is a named position in the rig ("head",
/// "left-hand"); the sprites that share a slot name are the variants that can
/// occupy it. A skin says which variant each slot shows, and anything it does
/// not mention falls through to the skins it includes, and finally to the setup
/// arrangement — so a skin only has to describe what it changes.
struct Skin: Identifiable, Equatable {
    let id: UUID
    var name: String

    /// Slot name → the sprite that occupies it under this skin.
    ///
    /// A present key with a `nil` value means "this slot is deliberately empty
    /// in this skin", which is different from an absent key ("this skin has no
    /// opinion, ask the skins I include"). The distinction is what lets a skin
    /// remove a hat rather than merely not mention it.
    var attachments: [String: UUID?]

    /// Other skins this one builds on, nearest first. Several includes rather
    /// than a single parent chain, so variants compose instead of forking.
    var includedSkinIDs: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        attachments: [String: UUID?] = [:],
        includedSkinIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.attachments = attachments
        self.includedSkinIDs = includedSkinIDs
    }

    /// Slots this skin has an explicit opinion about.
    var describedSlots: [String] {
        attachments.keys.sorted()
    }

    func attachment(for slot: String) -> UUID?? {
        attachments[slot]
    }

    mutating func setAttachment(_ imageID: UUID?, for slot: String) {
        // `attachments[slot] = imageID` would DELETE the entry when imageID is
        // nil, because assigning nil through a dictionary subscript removes the
        // key. That would turn "this skin empties the slot" into "this skin has
        // no opinion", which are different things here. updateValue stores the
        // empty value instead.
        attachments.updateValue(imageID, forKey: slot)
    }

    mutating func clearAttachment(for slot: String) {
        attachments.removeValue(forKey: slot)
    }
}

/// The resolved state of every slot for a given skin, plus the sprites that end
/// up hidden as a result. Computed once per change rather than per draw call.
struct SkinResolution: Equatable {
    /// Slot name → the sprite shown in it, or `nil` for a deliberately empty slot.
    var slots: [String: UUID?] = [:]
    /// Sprites that the active skin displaces. Independent of the artist's own
    /// hide toggles, which stay in `SceneImage.isHidden`.
    var hiddenImageIDs: Set<UUID> = []

    static let empty = SkinResolution()
}

enum SkinResolver {

    /// Walk a skin and everything it includes, nearest wins.
    ///
    /// Cycles are broken by tracking visited IDs: a skin that (directly or
    /// indirectly) includes itself resolves to what was reachable before the
    /// loop closed, rather than hanging the editor.
    static func flatten(
        skinID: UUID,
        in skins: [Skin]
    ) -> [String: UUID?] {
        var out: [String: UUID?] = [:]
        var visited = Set<UUID>()

        func visit(_ id: UUID) {
            guard visited.insert(id).inserted,
                  let skin = skins.first(where: { $0.id == id }) else { return }
            // Own attachments take priority over inherited ones, so they are
            // written first and never overwritten below.
            for (slot, imageID) in skin.attachments where out[slot] == nil {
                out.updateValue(imageID, forKey: slot)
            }
            for included in skin.includedSkinIDs {
                visit(included)
            }
        }

        visit(skinID)
        return out
    }

    /// Resolve which sprite occupies each slot, and therefore which sprites the
    /// skin displaces.
    ///
    /// - Parameters:
    ///   - slotMembers: slot name → every sprite that can occupy it.
    ///   - setupAttachments: the arrangement to fall back on for slots the skin
    ///     says nothing about — normally the first non-hidden sprite of the slot.
    static func resolve(
        activeSkinID: UUID?,
        skins: [Skin],
        slotMembers: [String: [UUID]],
        setupAttachments: [String: UUID?]
    ) -> SkinResolution {
        var resolution = SkinResolution()

        let overrides: [String: UUID?] = activeSkinID
            .map { flatten(skinID: $0, in: skins) } ?? [:]

        for (slot, members) in slotMembers {
            // A slot with a single possible sprite is not a real variant point;
            // leaving it alone keeps plain rigs untouched by the skin system.
            let chosen: UUID?
            if let override = overrides[slot] {
                chosen = override
            } else if let setup = setupAttachments[slot] {
                chosen = setup
            } else {
                chosen = members.first
            }

            resolution.slots.updateValue(chosen, forKey: slot)

            guard members.count > 1 || overrides[slot] != nil else { continue }
            for member in members where member != chosen {
                resolution.hiddenImageIDs.insert(member)
            }
        }

        return resolution
    }
}
