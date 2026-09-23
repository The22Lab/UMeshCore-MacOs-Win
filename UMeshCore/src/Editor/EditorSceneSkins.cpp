// EditorScene -- skins, slots and attachments.
//
// Ported from the `// MARK: - Skins` extension of `Data/SceneManager.swift`
// plus `attachments(inSlot:)` and `attachmentHiddenImageIDs`.
//
// Slots are derived from the sprites themselves: every sprite carries a
// slot name, and sprites sharing one are variants of the same attachment
// point. A skin records which variant each slot shows. A plain rig needs no
// setup at all -- one sprite per slot, nothing for a skin to override.

#include "umeshcore/Editor/EditorScene.h"

#include <algorithm>
#include <cctype>

namespace umeshcore {

namespace {

std::string trimmed(const std::string& s) {
    std::size_t b = 0, e = s.size();
    while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return s.substr(b, e - b);
}

} // namespace

// ---- Derived slot data ------------------------------------------------------

std::unordered_map<std::string, std::vector<Uuid>> EditorScene::slotMembers() const {
    std::unordered_map<std::string, std::vector<Uuid>> out;
    for (const SceneImage& img : images) out[img.effectiveSlotName()].push_back(img.id);
    return out;
}

std::vector<std::string> EditorScene::variantSlotNames() const {
    std::vector<std::string> out;
    for (const auto& [slot, members] : slotMembers()) {
        if (members.size() > 1) out.push_back(slot);
    }
    std::sort(out.begin(), out.end());
    return out;
}

std::vector<std::string> EditorScene::allSlotNames() const {
    std::vector<std::string> out;
    for (const auto& entry : slotMembers()) out.push_back(entry.first);
    std::sort(out.begin(), out.end());
    return out;
}

// What each slot shows with no skin active: the first sprite the artist has
// not hidden, falling back to the first member so a slot whose sprites are
// all hidden still resolves to something stable.
std::unordered_map<std::string, std::optional<Uuid>> EditorScene::setupAttachments() const {
    std::unordered_map<std::string, std::optional<Uuid>> out;
    for (const auto& [slot, members] : slotMembers()) {
        std::optional<Uuid> visible;
        for (Uuid id : members) {
            const SceneImage* img = image(id);
            if (img != nullptr && !img->isHidden) {
                visible = id;
                break;
            }
        }
        out[slot] = visible.has_value() ? visible
                                        : (members.empty() ? std::nullopt : std::optional<Uuid>(members.front()));
    }
    return out;
}

const Skin* EditorScene::activeSkin() const {
    if (!activeSkinID.has_value()) return nullptr;
    for (const Skin& skin : skins) {
        if (skin.id == *activeSkinID) return &skin;
    }
    return nullptr;
}

void EditorScene::refreshSkinResolution() {
    skinResolution = SkinResolver::resolve(activeSkinID, skins, slotMembers(), setupAttachments());
}

bool EditorScene::isHiddenByActiveSkin(Uuid imageID) const {
    return skinResolution.hiddenImageIDs.contains(imageID);
}

std::unordered_set<Uuid, UuidHash> EditorScene::attachmentHiddenImageIDs() const {
    // Merged into the same set the skins use, so there is ONE answer to "is
    // this sprite drawn".
    std::unordered_set<Uuid, UuidHash> hidden;
    if (animatedAttachments.empty()) return hidden;
    for (const auto& [slot, shown] : animatedAttachments) {
        for (const SceneImage& img : images) {
            if (img.effectiveSlotName() != slot) continue;
            if (!(shown.has_value() && *shown == img.id)) hidden.insert(img.id);
        }
    }
    return hidden;
}

std::vector<SceneImage> EditorScene::attachments(const std::string& slotName) const {
    std::vector<SceneImage> out;
    for (const SceneImage& img : images) {
        if (img.effectiveSlotName() == slotName) out.push_back(img);
    }
    return out;
}

std::optional<Uuid> EditorScene::shownAttachment(const std::string& slotName) const {
    if (auto keyed = animatedAttachments.find(slotName); keyed != animatedAttachments.end()) return keyed->second;
    if (auto fromSkin = skinResolution.slots.find(slotName); fromSkin != skinResolution.slots.end()) {
        return fromSkin->second;
    }
    for (const SceneImage& img : images) {
        if (img.effectiveSlotName() == slotName) return img.id;
    }
    return std::nullopt;
}

// ---- Slot editing -----------------------------------------------------------

void EditorScene::setSlotName(const std::string& slotName, Uuid imageID) {
    SceneImage* img = image(imageID);
    if (img == nullptr) return;
    const std::string name = trimmed(slotName);
    if (img->slotName == name) return;
    pushUndoState();
    // pushUndoState copies `images`; it does not reallocate them.
    image(imageID)->slotName = name;
    refreshSkinResolution();
}

void EditorScene::assignSlot(const std::string& slotName, const std::vector<Uuid>& imageIDs) {
    const std::string name = trimmed(slotName);
    if (name.empty() || imageIDs.empty()) return;
    pushUndoState();
    for (Uuid id : imageIDs) {
        if (SceneImage* img = image(id)) img->slotName = name;
    }
    refreshSkinResolution();
}

void EditorScene::renameSlot(const std::string& oldName, const std::string& newName) {
    const std::string name = trimmed(newName);
    if (name.empty() || name == oldName) return;
    pushUndoState();
    for (SceneImage& img : images) {
        if (img.effectiveSlotName() == oldName) img.slotName = name;
    }
    for (Skin& skin : skins) {
        auto it = skin.attachments.find(oldName);
        if (it == skin.attachments.end()) continue;
        // The value may legitimately be nullopt (an emptied slot); it moves
        // as it is rather than being dropped.
        const std::optional<Uuid> value = it->second;
        skin.attachments.erase(it);
        skin.attachments[name] = value;
    }
    refreshSkinResolution();
}

// ---- Skin CRUD ----------------------------------------------------------------

std::string EditorScene::uniqueSkinName(const std::string& requested, std::optional<Uuid> excluding) const {
    std::unordered_set<std::string> taken;
    for (const Skin& skin : skins) {
        if (!(excluding.has_value() && skin.id == *excluding)) taken.insert(skin.name);
    }
    if (!taken.contains(requested)) return requested;
    int suffix = 2;
    while (taken.contains(requested + " " + std::to_string(suffix))) suffix += 1;
    return requested + " " + std::to_string(suffix);
}

Uuid EditorScene::createSkin(std::optional<std::string> requestedName, bool activate) {
    pushUndoState();
    Skin skin(uniqueSkinName(requestedName.value_or("Skin"), std::nullopt));
    const Uuid id = skin.id;
    skins.push_back(skin);
    if (activate) {
        setActiveSkin(id);
    } else {
        refreshSkinResolution();
    }
    return id;
}

std::optional<Uuid> EditorScene::duplicateSkin(Uuid id) {
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == id; });
    if (it == skins.end()) return std::nullopt;
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    const Skin source = skins[index];
    Skin copy(uniqueSkinName(source.name + " copy", std::nullopt));
    copy.attachments = source.attachments;
    copy.includedSkinIDs = source.includedSkinIDs;
    const Uuid copyID = copy.id;
    skins.insert(skins.begin() + static_cast<std::ptrdiff_t>(index) + 1, copy);
    setActiveSkin(copyID);
    return copyID;
}

void EditorScene::renameSkin(Uuid id, const std::string& newName) {
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == id; });
    if (it == skins.end()) return;
    const std::string name = trimmed(newName);
    if (name.empty() || name == it->name) return;
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    skins[index].name = uniqueSkinName(name, id);
}

void EditorScene::deleteSkin(Uuid id) {
    if (std::none_of(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == id; })) return;
    pushUndoState();
    std::erase_if(skins, [&](const Skin& s) { return s.id == id; });
    // Anything that included the deleted skin forgets it, or the resolver
    // would walk a dangling reference.
    for (Skin& skin : skins) std::erase(skin.includedSkinIDs, id);
    if (activeSkinID == id) {
        setActiveSkin(std::nullopt);
    } else {
        refreshSkinResolution();
    }
}

void EditorScene::setActiveSkin(std::optional<Uuid> id) {
    if (activeSkinID == id) return;
    activeSkinID = id;
    refreshSkinResolution();
}

// ---- Attachment editing ---------------------------------------------------------

void EditorScene::showAttachment(const std::string& slotName, std::optional<Uuid> imageID) {
    // One verb, two meanings decided by the mode: in Editor it edits the
    // active skin; in Animator it keys the attachment timeline.
    if (slotName.empty()) return;
    if (isAnimationEditingEnabled) {
        keyAttachment(slotName, imageID);
        return;
    }
    if (!activeSkinID.has_value()) return;
    setSkinAttachment(*activeSkinID, slotName, imageID);
}

void EditorScene::keyAttachment(const std::string& slotName, std::optional<Uuid> imageID) {
    if (slotName.empty()) return;
    pushUndoState();
    sceneAnimationClip.upsertKeyframe(
        SlotAnimationTarget::id(slotName), AnimationTrackProperty::Attachment, currentFrame,
        AttachmentValue{imageID}, KeyframeInterpolation::Hold);
    applyAnimationsNow();
}

bool EditorScene::attachmentHasKeyAtPlayhead(const std::string& slotName) const {
    for (const Keyframe& k :
         sceneAnimationClip.keyframesFor(SlotAnimationTarget::id(slotName), AnimationTrackProperty::Attachment)) {
        if (k.frame == currentFrame) return true;
    }
    return false;
}

void EditorScene::removeAttachmentKeyAtPlayhead(const std::string& slotName) {
    const Uuid target = SlotAnimationTarget::id(slotName);
    for (const Keyframe& k : sceneAnimationClip.keyframesFor(target, AnimationTrackProperty::Attachment)) {
        if (k.frame != currentFrame) continue;
        const Uuid keyID = k.id;
        pushUndoState();
        sceneAnimationClip.deleteKeyframes(target, AnimationTrackProperty::Attachment, {keyID});
        applyAnimationsNow();
        return;
    }
}

void EditorScene::setSkinAttachment(Uuid skinID, const std::string& slot, std::optional<Uuid> imageID) {
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == skinID; });
    if (it == skins.end()) return;
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    skins[index].setAttachment(imageID, slot);
    refreshSkinResolution();
}

void EditorScene::clearSkinAttachment(Uuid skinID, const std::string& slot) {
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == skinID; });
    if (it == skins.end() || !it->attachments.contains(slot)) return;
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    skins[index].clearAttachment(slot);
    refreshSkinResolution();
}

void EditorScene::captureCurrentArrangement(Uuid skinID) {
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == skinID; });
    if (it == skins.end()) return;
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    for (const auto& [slot, members] : slotMembers()) {
        if (members.size() <= 1) continue;
        std::optional<Uuid> shown;
        for (Uuid id : members) {
            const SceneImage* img = image(id);
            if (img != nullptr && !img->isHidden && !isHiddenByActiveSkin(id)) {
                shown = id;
                break;
            }
        }
        skins[index].setAttachment(shown, slot);
    }
    refreshSkinResolution();
}

// ---- Inclusion ------------------------------------------------------------------

bool EditorScene::skinChainContains(Uuid start, Uuid target) const {
    std::unordered_set<Uuid, UuidHash> visited;
    std::vector<Uuid> stack{start};
    while (!stack.empty()) {
        const Uuid current = stack.back();
        stack.pop_back();
        if (current == target) return true;
        if (!visited.insert(current).second) continue;
        for (const Skin& skin : skins) {
            if (skin.id == current) {
                stack.insert(stack.end(), skin.includedSkinIDs.begin(), skin.includedSkinIDs.end());
                break;
            }
        }
    }
    return false;
}

bool EditorScene::addSkinInclusion(Uuid skinID, Uuid includedID) {
    // Refuses a cycle: a skin may not include something that already leads
    // back to it, which would make resolution order meaningless.
    if (skinID == includedID) return false;
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == skinID; });
    if (it == skins.end()) return false;
    if (std::none_of(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == includedID; })) return false;
    if (std::find(it->includedSkinIDs.begin(), it->includedSkinIDs.end(), includedID) != it->includedSkinIDs.end()) {
        return false;
    }
    if (skinChainContains(includedID, skinID)) return false;
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    skins[index].includedSkinIDs.push_back(includedID);
    refreshSkinResolution();
    return true;
}

void EditorScene::removeSkinInclusion(Uuid skinID, Uuid includedID) {
    auto it = std::find_if(skins.begin(), skins.end(), [&](const Skin& s) { return s.id == skinID; });
    if (it == skins.end() ||
        std::find(it->includedSkinIDs.begin(), it->includedSkinIDs.end(), includedID) == it->includedSkinIDs.end()) {
        return;
    }
    const std::size_t index = static_cast<std::size_t>(it - skins.begin());
    pushUndoState();
    std::erase(skins[index].includedSkinIDs, includedID);
    refreshSkinResolution();
}

void EditorScene::pruneSkins() {
    std::unordered_set<Uuid, UuidHash> live;
    for (const SceneImage& img : images) live.insert(img.id);
    bool changed = false;
    for (Skin& skin : skins) {
        for (auto& [slot, imageID] : skin.attachments) {
            if (!imageID.has_value() || live.contains(*imageID)) continue;
            imageID = std::nullopt;
            changed = true;
        }
    }
    if (changed) refreshSkinResolution();
}

} // namespace umeshcore
