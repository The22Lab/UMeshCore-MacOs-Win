#pragma once

// 1:1 port of `Data/Skin.swift`.
//
// The slot/skin model. A slot is a named position in the rig ("head",
// "left-hand"); the sprites that share a slot name are the variants that
// can occupy it. A skin says which variant each slot shows, and anything
// it does not mention falls through to the skins it includes, and finally
// to the setup arrangement.
//
// `attachments` needs Swift's "double optional" semantics: a PRESENT key
// with an EMPTY value means "this slot is deliberately empty in this
// skin" (different from an ABSENT key, "this skin has no opinion, ask the
// skins I include"). `std::unordered_map<std::string, std::optional<Uuid>>`
// gives this directly in C++ (key presence and value-optionality are
// independent axes of the same map), unlike Swift where
// `attachments[slot] = nil` would DELETE the key through the subscript
// setter -- that footgun is exactly why the Swift source uses
// `updateValue` instead of subscript assignment for `setAttachment`; the
// C++ port's `operator[]` assignment doesn't have that problem, so no
// equivalent workaround is needed here (see setAttachment below).

#include <algorithm>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

using SlotAttachment = std::optional<Uuid>; // nullopt = deliberately empty slot.
using SlotAttachments = std::unordered_map<std::string, SlotAttachment>;

struct Skin {
    Uuid id = Uuid::generate();
    std::string name;

    // Slot name -> the sprite that occupies it under this skin.
    SlotAttachments attachments;

    // Other skins this one builds on, nearest first.
    std::vector<Uuid> includedSkinIDs;

    Skin() = default;
    explicit Skin(std::string name_) : name(std::move(name_)) {}

    // Slots this skin has an explicit opinion about, sorted by name.
    std::vector<std::string> describedSlots() const {
        std::vector<std::string> out;
        out.reserve(attachments.size());
        for (const auto& [slot, _] : attachments) out.push_back(slot);
        std::sort(out.begin(), out.end());
        return out;
    }

    // nullopt (outer) = no opinion (key absent); {nullopt} (present,
    // empty inner) = deliberately empty slot; {Uuid} = shows that sprite.
    std::optional<SlotAttachment> attachment(const std::string& slot) const {
        auto it = attachments.find(slot);
        if (it == attachments.end()) return std::nullopt;
        return it->second;
    }

    void setAttachment(SlotAttachment imageID, const std::string& slot) { attachments[slot] = imageID; }

    void clearAttachment(const std::string& slot) { attachments.erase(slot); }
};

// The resolved state of every slot for a given skin, plus the sprites that
// end up hidden as a result.
struct SkinResolution {
    // Slot name -> the sprite shown in it, or nullopt for a deliberately
    // empty slot. Presence of the key means the slot was considered at all.
    std::unordered_map<std::string, SlotAttachment> slots;
    // Sprites the active skin displaces, independent of the artist's own
    // hide toggles.
    std::unordered_set<Uuid, UuidHash> hiddenImageIDs;
};

namespace SkinResolver {

// Walk a skin and everything it includes, nearest wins. Cycles are broken
// by tracking visited IDs: a skin that (directly or indirectly) includes
// itself resolves to what was reachable before the loop closed.
inline SlotAttachments flatten(Uuid skinID, const std::vector<Skin>& skins) {
    SlotAttachments out;
    std::unordered_set<Uuid, UuidHash> visited;

    std::function<void(Uuid)> visit = [&](Uuid id) {
        if (!visited.insert(id).second) return;
        const Skin* skin = nullptr;
        for (const auto& s : skins) {
            if (s.id == id) {
                skin = &s;
                break;
            }
        }
        if (skin == nullptr) return;
        // Own attachments take priority over inherited ones: written
        // first and never overwritten below.
        for (const auto& [slot, imageID] : skin->attachments) {
            if (!out.contains(slot)) out.emplace(slot, imageID);
        }
        for (Uuid included : skin->includedSkinIDs) visit(included);
    };

    visit(skinID);
    return out;
}

// Resolve which sprite occupies each slot, and therefore which sprites the
// skin displaces.
// `slotMembers`: slot name -> every sprite that can occupy it.
// `setupAttachments`: the fallback arrangement for slots the skin says
// nothing about (normally the first non-hidden sprite of the slot).
inline SkinResolution resolve(
    std::optional<Uuid> activeSkinID, const std::vector<Skin>& skins,
    const std::unordered_map<std::string, std::vector<Uuid>>& slotMembers,
    const std::unordered_map<std::string, SlotAttachment>& setupAttachments) {
    SkinResolution resolution;

    const SlotAttachments overrides = activeSkinID.has_value() ? flatten(*activeSkinID, skins) : SlotAttachments{};

    for (const auto& [slot, members] : slotMembers) {
        SlotAttachment chosen;
        const bool hasOverride = overrides.contains(slot);
        if (hasOverride) {
            chosen = overrides.at(slot);
        } else if (auto setupIt = setupAttachments.find(slot); setupIt != setupAttachments.end()) {
            chosen = setupIt->second;
        } else {
            chosen = members.empty() ? std::nullopt : SlotAttachment(members.front());
        }

        resolution.slots[slot] = chosen;

        // A slot with a single possible sprite is not a real variant
        // point; leaving it alone keeps plain rigs untouched by the skin
        // system.
        if (!(members.size() > 1 || hasOverride)) continue;
        for (Uuid member : members) {
            if (!(chosen.has_value() && *chosen == member)) resolution.hiddenImageIDs.insert(member);
        }
    }

    return resolution;
}

} // namespace SkinResolver
} // namespace umeshcore
