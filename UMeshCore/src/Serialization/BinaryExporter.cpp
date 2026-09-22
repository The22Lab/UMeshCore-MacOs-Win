#include "umeshcore/Serialization/BinaryExporter.h"

#include <algorithm>
#include <ctime>
#include <fstream>
#include <unordered_set>
#include <variant>

#include "umeshcore/Serialization/UMeshBinaryFormat.h"

namespace umeshcore {

namespace {

// `UM.unboundBone` (`UltraMeshTheme.swift:150`) -- the single color-theme
// constant `writeSkeletonChunk` needs as a fallback for a bone with no
// weight-paint color assigned. Ported as a literal, not the surrounding
// (UI-only) theme file.
constexpr Vec4 kUnboundBoneColor(0.55f, 0.58f, 0.66f, 1.0f);

// Matches `URL.lastPathComponent`: the text after the final '/' or '\\',
// or the whole string if there is no separator.
std::string lastPathComponent(const std::string& path) {
    const std::size_t slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::optional<std::vector<std::uint8_t>> readFileBytes(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return std::nullopt;
    const std::streamsize size = file.tellg();
    if (size < 0) return std::nullopt;
    file.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
    if (size > 0 && !file.read(reinterpret_cast<char*>(bytes.data()), size)) return std::nullopt;
    return bytes;
}

} // namespace

std::vector<std::uint8_t> BinaryExporter::exportScene(
    const EditorScene& scene,
    const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets) const {
    return exportScene(scene, assets, {});
}

std::vector<std::uint8_t> BinaryExporter::exportScene(
    const EditorScene& scene, const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets,
    const std::vector<SceneComposition>& compositions) const {
    // Rough sizing heuristic mirroring the Swift source's own estimate:
    // average bone ~64B, image header ~96B. Over-reserving avoids
    // reallocation for typical projects.
    const std::size_t estimate =
        64 * 1024 + scene.images.size() * 4096 + scene.skeleton.bones().size() * 256;
    BinaryWriter writer(estimate);

    // ---------- Header ----------
    writer.writeU32(UMeshBinaryFormat::magic);
    writer.writeU16(UMeshBinaryFormat::version);
    writer.writeU16(
        options_.textureEmbedMode == TextureEmbedMode::Embed
            ? static_cast<std::uint16_t>(UMeshBinaryFormat::HeaderFlag::EmbeddedTextures)
            : 0);
    const std::size_t chunkCountOffset = writer.count();
    writer.writeU32(0); // chunkCount placeholder
    const std::size_t payloadSizeOffset = writer.count();
    writer.writeU32(0); // payloadSize placeholder
    writer.writeU64(0); // reserved

    const std::size_t payloadStart = writer.count();
    std::uint32_t chunkCount = 0;

    writeMetaChunk(writer, scene);
    chunkCount += 1;

    writeAssetsChunk(writer, scene, assets);
    chunkCount += 1;

    writeSkeletonChunk(writer, scene);
    chunkCount += 1;

    writeImagesChunk(writer, scene);
    chunkCount += 1;
    writeMeshesChunk(writer, scene);
    chunkCount += 1;

    writeAnimationsChunk(writer, scene);
    chunkCount += 1;

    // Swift's own gate, kept exactly: no compositions, no chunk. A rig
    // that never used Scene mode therefore produces a file identical to
    // one from before this chunk existed, and a runtime predating it skips
    // an unknown chunk by its size field -- which is what the format was
    // designed for.
    if (!compositions.empty()) {
        writeScenesChunk(writer, scene, compositions);
        chunkCount += 1;
    }

    writer.patchU32(chunkCount, chunkCountOffset);
    writer.patchU32(static_cast<std::uint32_t>(writer.count() - payloadStart), payloadSizeOffset);
    return writer.data();
}

// SCENES layout (version 1), as the Swift source documents it:
//   u16 version, u32 compositionCount
//   per composition: uuid, string name, u32 duration, u32 fps,
//                    f32[2] renderSize, f32[8] background (top then bottom),
//                    f32[9] camera, u32 layerCount,
//     per layer: uuid, string name, u8 kind, u8 hidden, f32 opacity,
//                f32[2] pos, f32 z, f32 rot, f32[3] rot3D, f32[2] scale,
//                then the kind's payload
//     u32 cameraTrackCount
//       per track: u8 property, u32 keyCount, then (u32 frame, f32[n] value)
void BinaryExporter::writeScenesChunk(
    BinaryWriter& writer, const EditorScene& scene,
    const std::vector<SceneComposition>& compositions) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Scenes);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::scenes);
    writer.writeU32(static_cast<std::uint32_t>(compositions.size()));

    const auto writeColor = [&writer](const Vec4& c) {
        writer.writeF32(c.x);
        writer.writeF32(c.y);
        writer.writeF32(c.z);
        writer.writeF32(c.w);
    };

    for (const SceneComposition& composition : compositions) {
        writer.writeUuid(composition.id);
        writer.writeString(composition.name);
        // Floored at 1, as Swift does: a zero-frame or zero-fps scene has
        // no playhead, and the field is unsigned so a negative would wrap
        // to a duration of four billion frames.
        writer.writeU32(static_cast<std::uint32_t>(std::max(composition.durationInFrames, 1)));
        writer.writeU32(static_cast<std::uint32_t>(std::max(composition.fps, 1)));
        writer.writeF32(composition.renderSize.x);
        writer.writeF32(composition.renderSize.y);

        writeColor(composition.background.topColor);
        writeColor(composition.background.bottomColor);

        const SceneCamera& camera = composition.camera;
        writer.writeF32(camera.position.x);
        writer.writeF32(camera.position.y);
        writer.writeF32(camera.positionZ);
        writer.writeF32(camera.rotation3D.x);
        writer.writeF32(camera.rotation3D.y);
        writer.writeF32(camera.rotation3D.z);
        writer.writeF32(camera.fieldOfView);
        writer.writeF32(camera.nearZ);
        writer.writeF32(camera.farZ);

        // IN DRAW ORDER, back first. The array is only the tie-break now,
        // so writing it raw would hand the runtime a stacking that is not
        // the one the editor draws -- and the chunk carries no layer
        // number for it to re-sort by, on purpose: what a player needs is
        // the order, not the arithmetic that produced it.
        writer.writeU32(static_cast<std::uint32_t>(composition.layers.size()));
        for (const SceneLayer& layer : composition.drawOrderedLayers()) {
            writer.writeUuid(layer.id);
            writer.writeString(layer.name);

            // The wire codes, by explicit branch. Never a cast off the
            // variant's index: the alternative order is a C++ detail and
            // this is a frozen format.
            std::uint8_t kind = 2;
            if (std::holds_alternative<SceneRigContent>(layer.content)) {
                kind = 0;
            } else if (std::holds_alternative<ScenePlateContent>(layer.content)) {
                kind = 1;
            }
            writer.writeU8(kind);
            writer.writeU8(layer.isHidden ? 1 : 0);
            writer.writeF32(layer.opacity);
            writer.writeF32(layer.position.x);
            writer.writeF32(layer.position.y);
            writer.writeF32(layer.positionZ);
            writer.writeF32(layer.rotation);
            writer.writeF32(layer.rotation3D.x);
            writer.writeF32(layer.rotation3D.y);
            writer.writeF32(layer.rotation3D.z);
            writer.writeF32(layer.scale.x);
            writer.writeF32(layer.scale.y);

            // NOTE the shear and the material are NOT in this chunk. That
            // is Swift's layout, not an omission here: the runtime format
            // predates both, and adding fields to a frozen chunk without a
            // version bump is how a reader starts parsing the next record
            // as part of this one.
            if (const SceneRigContent* rig = std::get_if<SceneRigContent>(&layer.content)) {
                writer.writeUuid(rig->clipId);
                writer.writeF32(rig->speed);
                writer.writeU32(static_cast<std::uint32_t>(std::max(rig->startFrame, 0)));
                writer.writeU8(rig->loops ? 1 : 0);
            } else if (const ScenePlateContent* plate =
                           std::get_if<ScenePlateContent>(&layer.content)) {
                writer.writeUuid(plate->assetId);
            } else if (const SceneFillContent* fill =
                           std::get_if<SceneFillContent>(&layer.content)) {
                writeColor(fill->fill.topColor);
                writeColor(fill->fill.bottomColor);
            }
        }

        // Once per composition, and every composition gets the SAME
        // tracks, because they come from the project's single
        // `sceneAnimationClip`. Swift's behaviour and the format's shape,
        // reproduced rather than "fixed" -- but it does mean the format
        // cannot express per-composition camera animation today.
        writeSceneCameraTracks(writer, scene);
    }

    writer.closeChunk(off);
}

// The camera's keyframes. Channel counts are implied by the property, so a
// reader that knows the property list can skip a track it does not
// recognise without knowing what it meant.
void BinaryExporter::writeSceneCameraTracks(BinaryWriter& writer, const EditorScene& scene) const {
    const Uuid target = SceneAnimationTarget::camera();

    std::vector<const AnimationTrack*> tracks;
    for (const AnimationTrack& track : scene.sceneAnimationClip.tracks()) {
        if (track.targetID == target && !track.keyframes.empty()) tracks.push_back(&track);
    }
    writer.writeU32(static_cast<std::uint32_t>(tracks.size()));

    for (const AnimationTrack* track : tracks) {
        std::uint8_t code = 255;
        switch (track->property) {
            case AnimationTrackProperty::CameraTranslate: code = 0; break;
            case AnimationTrackProperty::CameraTranslateZ: code = 1; break;
            case AnimationTrackProperty::CameraRotate3D: code = 2; break;
            case AnimationTrackProperty::CameraRoll: code = 3; break;
            case AnimationTrackProperty::CameraFOV: code = 4; break;
            default: code = 255; break;
        }
        writer.writeU8(code);
        writer.writeU32(static_cast<std::uint32_t>(track->keyframes.size()));

        // Sorted by frame. `AnimationTrack`'s constructor already sorts,
        // but a track assembled another way must not write a timeline that
        // runs backwards, and the cost is nothing next to the file.
        std::vector<const Keyframe*> keys;
        keys.reserve(track->keyframes.size());
        for (const Keyframe& key : track->keyframes) keys.push_back(&key);
        std::sort(keys.begin(), keys.end(),
                  [](const Keyframe* a, const Keyframe* b) { return a->frame < b->frame; });

        for (const Keyframe* key : keys) {
            writer.writeU32(static_cast<std::uint32_t>(std::max(key->frame, 0)));
            if (const Vector2Value* v = std::get_if<Vector2Value>(&key->value)) {
                writer.writeF32(v->value.x);
                writer.writeF32(v->value.y);
            } else if (const ScalarValue* s = std::get_if<ScalarValue>(&key->value)) {
                writer.writeF32(s->value);
            } else {
                // A camera track can only hold those two kinds; anything
                // else is a bug upstream, and writing a zero keeps the
                // stream aligned so the rest of the file still parses.
                writer.writeF32(0.0f);
            }
        }
    }
}

void BinaryExporter::writeMetaChunk(BinaryWriter& writer, const EditorScene& scene) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Meta);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::meta);
    writer.writeString(options_.prettyName.value_or("UltraMeshExport"));
    // Timestamp (seconds since 1970). Non-deterministic, matching the
    // Swift source's own `Date().timeIntervalSince1970` -- informational
    // metadata, not something a golden test needs to reproduce exactly.
    writer.writeF32(static_cast<float>(std::time(nullptr)));
    // Scene playback hints. Order matches the Swift source exactly: end
    // frame is written before start frame.
    writer.writeU32(static_cast<std::uint32_t>(std::max(scene.playbackEndFrame, 0)));
    writer.writeU32(static_cast<std::uint32_t>(std::max(scene.playbackStartFrame, 0)));
    writer.closeChunk(off);
}

void BinaryExporter::writeAssetsChunk(
    BinaryWriter& writer, const EditorScene& scene,
    const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Assets);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::assets);

    // Distinct asset IDs referenced by scene images, first-seen order.
    std::unordered_set<Uuid, UuidHash> seen;
    std::vector<Uuid> ordered;
    for (const SceneImage& image : scene.images) {
        if (seen.insert(image.assetID).second) ordered.push_back(image.assetID);
    }

    writer.writeU32(static_cast<std::uint32_t>(ordered.size()));

    for (const Uuid& assetID : ordered) {
        writer.writeUuid(assetID);

        const auto it = assets.find(assetID);
        if (it == assets.end()) {
            // See UMeshBinaryFormat.h's ChunkVersion::assets comment: v2
            // adds this explicit flag rather than replicating Swift's
            // byte-ambiguous "not found" record.
            writer.writeU8(0); // found = false
            continue;
        }
        writer.writeU8(1); // found = true

        const AssetRecord& asset = it->second;
        writer.writeString(asset.name);
        writer.writeVec2(asset.size);

        std::optional<std::vector<std::uint8_t>> payload;
        if (options_.textureEmbedMode == TextureEmbedMode::Embed) payload = readFileBytes(asset.filePath);

        if (payload.has_value()) {
            writer.writeU32(static_cast<std::uint32_t>(payload->size()));
            writer.appendData(*payload);
        } else {
            // Reference mode, or an embed read failure falls back to it
            // (matching the Swift source's `try?`-swallowed error path).
            writer.writeU32(0);
            writer.writeString(lastPathComponent(asset.filePath));
        }
    }

    writer.closeChunk(off);
}

void BinaryExporter::writeSkeletonChunk(BinaryWriter& writer, const EditorScene& scene) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Skeleton);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::skeleton);

    const std::vector<Bone> bones = scene.skeleton.orderedBones(); // DFS-ordered, roots first.
    writer.writeU32(static_cast<std::uint32_t>(bones.size()));

    for (const Bone& bone : bones) {
        writer.writeUuid(bone.id);
        writer.writeString(bone.name);
        // Compact parent: 1-byte presence flag, then UUID only if present.
        if (bone.parentID.has_value()) {
            writer.writeBool(true);
            writer.writeUuid(*bone.parentID);
        } else {
            writer.writeBool(false);
        }
        writeTransform(writer, bone.baseTransform);
        writeTransform(writer, bone.localTransform);
        writer.writeF32(bone.length);
        writer.writeVec4(bone.color.value_or(kUnboundBoneColor));
    }

    writer.writeU32(static_cast<std::uint32_t>(scene.skeleton.rootIDs.size()));
    for (const Uuid& id : scene.skeleton.rootIDs) writer.writeUuid(id);

    writer.closeChunk(off);
}

void BinaryExporter::writeTransform(BinaryWriter& writer, const Transform3D2D& transform) const {
    writer.writeVec3(transform.position);
    writer.writeVec3(transform.rotation);
    writer.writeVec3(transform.scale);
    writer.writeVec2(transform.skew);
}

void BinaryExporter::writeImagesChunk(BinaryWriter& writer, const EditorScene& scene) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Images);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::images);

    writer.writeU32(static_cast<std::uint32_t>(scene.images.size()));

    for (const SceneImage& image : scene.images) {
        writer.writeUuid(image.id);
        writer.writeUuid(image.assetID);
        writer.writeString(image.name);

        // Base pose.
        writer.writeVec2(image.basePosition);
        writer.writeF32(image.baseRotation);
        writer.writeVec2(image.baseScale);
        writer.writeVec2(image.baseSkew);
        writer.writeVec3(image.baseRotation3D);

        // Flags.
        UMeshBinaryFormat::ImageFlags flags;
        if (image.boneBinding.has_value()) flags.insert(UMeshBinaryFormat::ImageFlags::hasBoneBinding);
        if (image.isHidden) flags.insert(UMeshBinaryFormat::ImageFlags::isHidden);
        if (image.animationTransformSpace.boneID.has_value()) {
            flags.insert(UMeshBinaryFormat::ImageFlags::boneLocalSpace);
        }
        writer.writeU8(flags.rawValue);

        // Bone binding (optional).
        if (image.boneBinding.has_value()) {
            const BoneImageBinding& binding = *image.boneBinding;
            writer.writeUuid(binding.boneID);
            writer.writeVec2(binding.localPosition);
            writer.writeVec2(binding.localScale);
            writer.writeF32(binding.localRotation);
            writer.writeVec2(binding.localSkew);
        }

        // Animation space (only the bone ID if boneLocal).
        if (image.animationTransformSpace.boneID.has_value()) {
            writer.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::AnimationSpaceCode::BoneLocal));
            writer.writeUuid(*image.animationTransformSpace.boneID);
        } else {
            writer.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::AnimationSpaceCode::World));
        }
    }

    writer.closeChunk(off);
}

void BinaryExporter::writeMeshesChunk(BinaryWriter& writer, const EditorScene& scene) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Meshes);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::meshes);

    writer.writeU32(static_cast<std::uint32_t>(scene.images.size()));

    for (const SceneImage& image : scene.images) {
        const Mesh& mesh = image.mesh;
        writer.writeUuid(image.id); // owner key
        writer.writeUuid(mesh.id);
        writer.writeString(mesh.name);
        writer.writeVec2Array(mesh.vertices);
        writer.writeVec2Array(mesh.uvs);
        writer.writeU16Array(mesh.indices);
        writer.writeU16Array(mesh.hullVertexIndices);

        writer.writeU32(static_cast<std::uint32_t>(mesh.internalEdges.size()));
        for (const MeshEdge& e : mesh.internalEdges) {
            writer.writeU16(e.a);
            writer.writeU16(e.b);
        }

        writer.writeU32(static_cast<std::uint32_t>(mesh.manualTriangles.size()));
        for (const MeshTriangle& t : mesh.manualTriangles) {
            writer.writeU16(t.a);
            writer.writeU16(t.b);
            writer.writeU16(t.c);
        }

        writer.writeVec2Array(mesh.bindVertices);

        writer.writeU32(static_cast<std::uint32_t>(mesh.vertexBoneWeights.size()));
        for (const std::vector<VertexBoneWeight>& influences : mesh.vertexBoneWeights) {
            const std::size_t n = std::min<std::size_t>(influences.size(), 255);
            writer.writeU8(static_cast<std::uint8_t>(n));
            for (std::size_t i = 0; i < n; ++i) {
                writer.writeUuid(influences[i].boneID);
                writer.writeF32(influences[i].weight);
            }
        }

        writer.writeU32(static_cast<std::uint32_t>(mesh.boneInverseBindMatrices.size()));
        for (const auto& [boneID, matrix] : mesh.boneInverseBindMatrices) {
            writer.writeUuid(boneID);
            writer.writeMat4(matrix);
        }
    }

    writer.closeChunk(off);
}

void BinaryExporter::writeAnimationsChunk(BinaryWriter& writer, const EditorScene& scene) const {
    const std::size_t off = writer.openChunk(UMeshBinaryFormat::ChunkID::Animations);
    writer.writeU16(UMeshBinaryFormat::ChunkVersion::animations);

    // Bones + images each carry an AnimationClip; one clip per source with
    // non-empty tracks, keyed by owner id. Bones first, then images --
    // matching the Swift source's collection order.
    //
    // `orderedBones()` returns by value; it's bound to a named local here
    // (not iterated directly in the loop below) so it outlives the loop --
    // `clips` holds pointers into it, and a range-for's implicit temporary
    // would otherwise be destroyed at the end of ITS OWN loop, leaving
    // those pointers dangling for the rest of this function.
    const std::vector<Bone> bones = scene.skeleton.orderedBones();
    std::vector<std::pair<Uuid, const AnimationClip*>> clips;
    for (const Bone& bone : bones) {
        if (!bone.animationClip.tracks().empty()) clips.emplace_back(bone.id, &bone.animationClip);
    }
    for (const SceneImage& image : scene.images) {
        if (!image.animationClip.tracks().empty()) clips.emplace_back(image.id, &image.animationClip);
    }

    writer.writeU32(static_cast<std::uint32_t>(clips.size()));

    for (const auto& [ownerID, clip] : clips) {
        writer.writeUuid(ownerID);
        writer.writeUuid(clip->id);
        writer.writeString(clip->name);
        writer.writeU32(static_cast<std::uint32_t>(std::max(clip->durationInFrames, 0)));

        writer.writeU32(static_cast<std::uint32_t>(clip->tracks().size()));
        for (const AnimationTrack& track : clip->tracks()) {
            writer.writeUuid(track.id);
            writer.writeUuid(track.targetID);
            writer.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::toWireCode(track.property)));

            writer.writeU32(static_cast<std::uint32_t>(track.keyframes.size()));
            for (const Keyframe& kf : track.keyframes) writeKeyframe(writer, kf);
        }
    }

    writer.closeChunk(off);
}

void BinaryExporter::writeKeyframe(BinaryWriter& writer, const Keyframe& kf) const {
    writer.writeUuid(kf.id);
    writer.writeI32(kf.frame);
    writer.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::toWireCode(kf.interpolation)));

    struct ValueVisitor {
        BinaryWriter& w;
        void operator()(const TranslateValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Translate));
            w.writeVec2(v.value);
        }
        void operator()(const RotateValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Rotate));
            w.writeF32(v.value);
        }
        void operator()(const ScaleValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Scale));
            w.writeVec2(v.value);
        }
        void operator()(const ShearValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Shear));
            w.writeVec2(v.value);
        }
        void operator()(const ScalarValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Scalar));
            w.writeF32(v.value);
        }
        void operator()(const FlagValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Flag));
            w.writeU8(v.value ? 1 : 0);
        }
        void operator()(const Vector2Value& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Vector2));
            w.writeVec2(v.value);
        }
        void operator()(const DrawOrderValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::DrawOrder));
            w.writeI32(static_cast<std::int32_t>(v.value.size()));
            for (const Uuid& id : v.value) w.writeUuid(id);
        }
        // Fix for the confirmed Swift `break` bug -- see
        // UMeshBinaryFormat.h's ChunkVersion::animations comment.
        void operator()(const MeshDeformValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::MeshDeform));
            w.writeVec2Array(v.value);
        }
        void operator()(const EventValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Event));
            w.writeU8(v.value.intValue.has_value() ? 1 : 0);
            w.writeI32(v.value.intValue.value_or(0));
            w.writeU8(v.value.floatValue.has_value() ? 1 : 0);
            w.writeF32(v.value.floatValue.value_or(0.0f));
            w.writeString(v.value.stringValue.value_or(""));
        }
        void operator()(const AttachmentValue& v) const {
            w.writeU8(static_cast<std::uint8_t>(UMeshBinaryFormat::KeyframeValueCode::Attachment));
            w.writeU8(v.value.has_value() ? 1 : 0);
            if (v.value.has_value()) w.writeUuid(*v.value);
        }
    };
    std::visit(ValueVisitor{writer}, kf.value);

    // Tangent flags + values (compact: linear/hold keyframes pay 1 byte total).
    UMeshBinaryFormat::KeyframeFlags flags;
    if (kf.inTangent.has_value()) flags.insert(UMeshBinaryFormat::KeyframeFlags::inTangent);
    if (kf.outTangent.has_value()) flags.insert(UMeshBinaryFormat::KeyframeFlags::outTangent);
    if (kf.secondaryInTangent.has_value()) flags.insert(UMeshBinaryFormat::KeyframeFlags::secondaryInTangent);
    if (kf.secondaryOutTangent.has_value()) flags.insert(UMeshBinaryFormat::KeyframeFlags::secondaryOutTangent);
    writer.writeU8(flags.rawValue);
    if (kf.inTangent.has_value()) writer.writeVec2(*kf.inTangent);
    if (kf.outTangent.has_value()) writer.writeVec2(*kf.outTangent);
    if (kf.secondaryInTangent.has_value()) writer.writeVec2(*kf.secondaryInTangent);
    if (kf.secondaryOutTangent.has_value()) writer.writeVec2(*kf.secondaryOutTangent);
}

} // namespace umeshcore
