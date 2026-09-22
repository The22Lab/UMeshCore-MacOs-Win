#include "umeshcore/Serialization/UMJsonBuilder.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <fstream>
#include <set>
#include <unordered_set>

#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedSceneImage.h"
#include "umeshcore/Serialization/SavedSkeleton.h"

namespace umeshcore {

namespace {

// The single choke point for precision and determinism.
float roundTo(float v, int precision) {
    if (!std::isfinite(v)) return 0.0f;
    if (precision < 0) return v;
    const double scale = std::pow(10.0, static_cast<double>(precision));
    return static_cast<float>(std::round(static_cast<double>(v) * scale) / scale);
}

std::vector<float> round2(const Vec2& v, int precision) {
    return {roundTo(v.x, precision), roundTo(v.y, precision)};
}

const char* interpName(KeyframeInterpolation interpolation) {
    switch (interpolation) {
        // Spelled "stepped" here, not "hold" -- this format's vocabulary,
        // not the native one's.
        case KeyframeInterpolation::Hold: return "stepped";
        case KeyframeInterpolation::Linear: return "linear";
        case KeyframeInterpolation::Bezier: return "bezier";
    }
    return "linear";
}

UMJsonKeyframe convertKeyframe(const Keyframe& kf, int precision) {
    UMJsonKeyframe out;
    out.frame = kf.frame;
    out.interp = interpName(kf.interpolation);

    // Exactly one payload field, chosen by the value's kind. drawOrder,
    // event, meshDeform and attachment carry none: they travel in their own
    // dedicated timelines, not as generic keyframes.
    if (const auto* v = std::get_if<RotateValue>(&kf.value)) out.scalar = roundTo(v->value, precision);
    else if (const auto* v = std::get_if<ScalarValue>(&kf.value)) out.scalar = roundTo(v->value, precision);
    else if (const auto* v = std::get_if<TranslateValue>(&kf.value)) out.vector = round2(v->value, precision);
    else if (const auto* v = std::get_if<ScaleValue>(&kf.value)) out.vector = round2(v->value, precision);
    else if (const auto* v = std::get_if<ShearValue>(&kf.value)) out.vector = round2(v->value, precision);
    else if (const auto* v = std::get_if<Vector2Value>(&kf.value)) out.vector = round2(v->value, precision);
    else if (const auto* v = std::get_if<FlagValue>(&kf.value)) out.flag = v->value;

    if (kf.inTangent.has_value()) out.inTangent = round2(*kf.inTangent, precision);
    if (kf.outTangent.has_value()) out.outTangent = round2(*kf.outTangent, precision);
    if (kf.secondaryInTangent.has_value()) out.secondaryInTangent = round2(*kf.secondaryInTangent, precision);
    if (kf.secondaryOutTangent.has_value()) out.secondaryOutTangent = round2(*kf.secondaryOutTangent, precision);
    return out;
}

bool sameValue(const UMJsonKeyframe& a, const UMJsonKeyframe& b) {
    return a.scalar == b.scalar && a.flag == b.flag && a.vector == b.vector;
}

bool hasCurveData(const UMJsonKeyframe& k) {
    return k.interp == "bezier" || k.inTangent.has_value() || k.outTangent.has_value() ||
           k.secondaryInTangent.has_value() || k.secondaryOutTangent.has_value();
}

std::string iso8601UtcNow() {
    const std::time_t now = std::time(nullptr);
    std::tm utc{};
#if defined(_WIN32)
    gmtime_s(&utc, &now);
#else
    gmtime_r(&now, &utc);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &utc);
    return buf;
}

JsonValue floatArrayToJson(const std::vector<float>& values) {
    JsonValue::Array arr;
    arr.reserve(values.size());
    for (float v : values) arr.push_back(JsonValue::makeNumber(v));
    return JsonValue::makeArray(std::move(arr));
}

JsonValue intArrayToJson(const std::vector<int>& values) {
    JsonValue::Array arr;
    arr.reserve(values.size());
    for (int v : values) arr.push_back(JsonValue::makeNumber(v));
    return JsonValue::makeArray(std::move(arr));
}

JsonValue stringArrayToJson(const std::vector<std::string>& values) {
    JsonValue::Array arr;
    arr.reserve(values.size());
    for (const std::string& v : values) arr.push_back(JsonValue::makeString(v));
    return JsonValue::makeArray(std::move(arr));
}

JsonValue poseToJson(const UMJsonAttachmentPose& pose) {
    JsonValue j = JsonValue::makeObject();
    j.set("position", floatArrayToJson(pose.position));
    j.set("rotation", JsonValue::makeNumber(pose.rotation));
    j.set("scale", floatArrayToJson(pose.scale));
    j.set("shear", floatArrayToJson(pose.shear));
    return j;
}

JsonValue keyframeToJson(const UMJsonKeyframe& key) {
    JsonValue j = JsonValue::makeObject();
    j.set("frame", JsonValue::makeNumber(key.frame));
    j.set("interp", JsonValue::makeString(key.interp));
    // Omitted when absent, matching Swift's encodeIfPresent.
    if (key.scalar.has_value()) j.set("scalar", JsonValue::makeNumber(*key.scalar));
    if (key.vector.has_value()) j.set("vector", floatArrayToJson(*key.vector));
    if (key.flag.has_value()) j.set("flag", JsonValue::makeBool(*key.flag));
    if (key.inTangent.has_value()) j.set("inTangent", floatArrayToJson(*key.inTangent));
    if (key.outTangent.has_value()) j.set("outTangent", floatArrayToJson(*key.outTangent));
    if (key.secondaryInTangent.has_value()) {
        j.set("secondaryInTangent", floatArrayToJson(*key.secondaryInTangent));
    }
    if (key.secondaryOutTangent.has_value()) {
        j.set("secondaryOutTangent", floatArrayToJson(*key.secondaryOutTangent));
    }
    return j;
}

JsonValue keyframesToJson(const std::vector<UMJsonKeyframe>& keys) {
    JsonValue::Array arr;
    arr.reserve(keys.size());
    for (const UMJsonKeyframe& key : keys) arr.push_back(keyframeToJson(key));
    return JsonValue::makeArray(std::move(arr));
}

} // namespace

bool UMJsonSetupValue::matches(const UMJsonKeyframe& key, float epsilon) const {
    if (isVector) {
        if (!key.vector.has_value() || key.vector->size() != 2) return false;
        return std::fabs((*key.vector)[0] - x) <= epsilon && std::fabs((*key.vector)[1] - y) <= epsilon;
    }
    if (!key.scalar.has_value()) return false;
    return std::fabs(*key.scalar - x) <= epsilon;
}

std::vector<UMJsonKeyframe> cleanedTrack(
    const std::vector<UMJsonKeyframe>& keys, const std::optional<UMJsonSetupValue>& setup) {
    if (keys.size() <= 1) return keys;

    // Rule 1 -- a constant, curve-free track is redundant ONLY when its
    // value is the setup value. Without a known setup we must keep it, or
    // dropping it would re-pose the rig.
    const bool allEqual =
        std::all_of(keys.begin() + 1, keys.end(), [&](const UMJsonKeyframe& k) { return sameValue(k, keys[0]); });
    const bool anyCurve = std::any_of(keys.begin(), keys.end(), hasCurveData);
    if (allEqual && !anyCurve && setup.has_value() && setup->matches(keys[0])) return {};

    // Rule 2 -- drop interior keys of equal-value runs, keeping endpoints so
    // the hold's timing survives exactly.
    std::vector<UMJsonKeyframe> out;
    out.reserve(keys.size());
    for (std::size_t index = 0; index < keys.size(); ++index) {
        const bool isEndpoint = (index == 0 || index == keys.size() - 1);
        if (isEndpoint || hasCurveData(keys[index])) {
            out.push_back(keys[index]);
            continue;
        }
        const UMJsonKeyframe& previous = keys[index - 1];
        const UMJsonKeyframe& next = keys[index + 1];
        const bool redundant = sameValue(previous, keys[index]) && sameValue(keys[index], next) &&
                               !hasCurveData(previous) && !hasCurveData(next);
        if (!redundant) out.push_back(keys[index]);
    }
    return out;
}

std::vector<Bone> deterministicBoneOrder(const Skeleton& skeleton) {
    std::vector<Bone> out;
    std::unordered_set<Uuid, UuidHash> visited;

    const std::function<void(Uuid)> visit = [&](Uuid id) {
        if (!visited.insert(id).second) return;
        const auto it = skeleton.bones().find(id);
        if (it == skeleton.bones().end()) return;
        out.push_back(it->second);

        std::vector<Uuid> children = skeleton.childrenOf(id);
        std::sort(children.begin(), children.end(), [](const Uuid& a, const Uuid& b) {
            return a.toString() < b.toString();
        });
        for (const Uuid& childID : children) visit(childID);
    };

    for (const Uuid& rootID : skeleton.rootIDs) visit(rootID);

    // Any bone not reachable from a declared root (orphan/defensive).
    std::vector<Uuid> remaining;
    remaining.reserve(skeleton.bones().size());
    for (const auto& [id, bone] : skeleton.bones()) {
        (void)bone;
        remaining.push_back(id);
    }
    std::sort(remaining.begin(), remaining.end(), [](const Uuid& a, const Uuid& b) {
        return a.toString() < b.toString();
    });
    for (const Uuid& id : remaining) visit(id);

    return out;
}

UMJsonAnimationSource animationSourceFrom(const NamedAnimation& animation) {
    UMJsonAnimationSource source;
    source.name = animation.name;
    source.boneClips = animation.boneClips;
    source.imageClips = animation.imageClips;
    source.sceneClip = animation.sceneClip;
    source.duration = animation.duration;
    return source;
}

namespace {

std::vector<Uuid> sortedIDs(const std::unordered_map<Uuid, AnimationClip, UuidHash>& clips) {
    std::vector<Uuid> ids;
    ids.reserve(clips.size());
    for (const auto& [id, clip] : clips) {
        (void)clip;
        ids.push_back(id);
    }
    std::sort(ids.begin(), ids.end(), [](const Uuid& a, const Uuid& b) { return a.toString() < b.toString(); });
    return ids;
}

std::optional<std::vector<UMJsonKeyframe>> buildTrack(
    const AnimationClip& clip, Uuid targetID, AnimationTrackProperty property,
    const std::optional<UMJsonSetupValue>& setup, const UMJsonExportOptions& options) {
    const std::vector<Keyframe>& keys = clip.keyframesFor(targetID, property);
    if (keys.empty()) return std::nullopt;

    std::vector<UMJsonKeyframe> converted;
    converted.reserve(keys.size());
    for (const Keyframe& key : keys) converted.push_back(convertKeyframe(key, options.floatPrecision));
    if (!options.animationCleanUp) return converted;

    std::vector<UMJsonKeyframe> cleaned = cleanedTrack(converted, setup);
    if (cleaned.empty()) return std::nullopt;
    return cleaned;
}

// Mesh-deformation keys for one attachment, or nullopt when the animation
// does not deform it. Keys whose vertex count disagrees with the mesh are
// dropped: the editor ignores them at playback, so exporting them would
// hand the runtime data the editor itself would never show.
std::optional<std::vector<UMJsonDeformKey>> buildDeformKeys(
    const AnimationClip& clip, Uuid imageID, const Mesh& mesh, const UMJsonExportOptions& options) {
    const std::vector<Keyframe>& keys = clip.keyframesFor(imageID, AnimationTrackProperty::MeshDeform);
    if (keys.empty() || mesh.vertices.empty()) return std::nullopt;

    std::vector<UMJsonDeformKey> out;
    out.reserve(keys.size());
    for (const Keyframe& key : keys) {
        const auto* deform = std::get_if<MeshDeformValue>(&key.value);
        if (deform == nullptr || deform->value.size() != mesh.vertices.size()) continue;

        UMJsonDeformKey entry;
        entry.frame = key.frame;
        // Only stepped and linear exist here -- the editor's deform sampler
        // never consults tangents, so claiming "bezier" would be a lie the
        // runtime could act on.
        entry.interp = key.interpolation == KeyframeInterpolation::Hold ? "stepped" : "linear";
        entry.vertices.reserve(deform->value.size() * 2);
        for (const Vec2& v : deform->value) {
            entry.vertices.push_back(roundTo(v.x, options.floatPrecision));
            entry.vertices.push_back(roundTo(v.y, options.floatPrecision));
        }
        out.push_back(std::move(entry));
    }
    if (out.empty()) return std::nullopt;

    // A single key that reproduces the rest shape deforms nothing.
    if (options.animationCleanUp && out.size() == 1) {
        std::vector<float> rest;
        rest.reserve(mesh.vertices.size() * 2);
        for (const Vec2& v : mesh.vertices) {
            rest.push_back(roundTo(v.x, options.floatPrecision));
            rest.push_back(roundTo(v.y, options.floatPrecision));
        }
        if (out[0].vertices == rest) return std::nullopt;
    }
    return out;
}

} // namespace

UMJsonDocument buildUMJsonDocument(
    const EditorScene& scene, const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets,
    const std::vector<UMJsonAnimationSource>& animations, const UMJsonExportOptions& options) {
    const int precision = options.floatPrecision;
    UMJsonDocument document;

    document.format = "UltraMesh";
    document.version = "1.0.0";
    document.engineVersion = "UltraMesh 1.0";
    document.generator = "UltraMesh JSON Exporter 1.0.0";
    // A timestamp by definition -- the one non-deterministic field, same as
    // the binary META chunk's.
    document.exportDate = iso8601UtcNow();
    document.compatibility.minRuntimeVersion = "1.0.0";
    document.compatibility.featureFlags = {"ik",    "transform", "path",      "physics",
                                           "skins", "events",    "drawOrder", "meshSkinning"};

    // ---- Metadata ----
    // The setup draw order is implicit in the `attachments` array order, so
    // it is redundant for a runtime and drops out with nonessential data.
    document.metadata.projectName = options.nonessentialData ? options.projectName : "";
    document.metadata.framesPerSecond = options.framesPerSecond;
    document.metadata.playbackStartFrame = std::max(scene.playbackStartFrame, 0);
    document.metadata.playbackEndFrame = std::max(scene.playbackEndFrame, 0);
    document.metadata.units = "pixels";
    if (options.nonessentialData) {
        for (const SceneImage& image : scene.images) document.metadata.drawOrder.push_back(image.id.toString());
    }

    // ---- Atlas ----
    std::unordered_set<Uuid, UuidHash> seenAssets;
    for (const SceneImage& image : scene.images) {
        if (!seenAssets.insert(image.assetID).second) continue;
        const auto it = assets.find(image.assetID);

        UMJsonAtlasRegion region;
        region.id = image.assetID.toString();
        // The human-facing region name is editor convenience; the id and
        // path are what a runtime resolves against.
        region.name = options.nonessentialData && it != assets.end() ? it->second.name : "";
        region.width = roundTo(it != assets.end() ? it->second.size.x : 0.0f, precision);
        region.height = roundTo(it != assets.end() ? it->second.size.y : 0.0f, precision);
        region.embedded = false;
        if (it != assets.end()) {
            const std::string& path = it->second.filePath;
            const std::size_t slash = path.find_last_of("/\\");
            region.path = slash == std::string::npos ? path : path.substr(slash + 1);
        }
        if (options.embedTextures && it != assets.end()) {
            // Reading the bytes is the caller's business in this port --
            // base64 embedding needs an encoder and file access that the
            // asset record alone does not carry. Left as a reference
            // export rather than silently pretending it embedded.
            region.embedded = false;
        }
        document.atlas.regions.push_back(std::move(region));
    }

    // ---- Bones ----
    const std::vector<Bone> orderedBones = deterministicBoneOrder(scene.skeleton);
    const std::unordered_set<Uuid, UuidHash> rootIDs(scene.skeleton.rootIDs.begin(), scene.skeleton.rootIDs.end());
    for (const Bone& bone : orderedBones) {
        const Transform3D2D& t = bone.baseTransform;
        UMJsonBone out;
        out.id = bone.id.toString();
        out.name = bone.name;
        if (bone.parentID.has_value()) out.parent = bone.parentID->toString();
        out.transform.position = {roundTo(t.position.x, precision), roundTo(t.position.y, precision)};
        out.transform.rotation = roundTo(t.rotation.z, precision);
        out.transform.scale = {roundTo(t.scale.x, precision), roundTo(t.scale.y, precision)};
        out.transform.shear = round2(t.skew, precision);

        // The 3D depth block is editor-only state; a 2D runtime ignores it.
        if (options.nonessentialData &&
            (std::fabs(t.position.z) > 1e-6f || std::fabs(t.rotation.x) > 1e-6f ||
             std::fabs(t.rotation.y) > 1e-6f || std::fabs(t.scale.z - 1.0f) > 1e-6f)) {
            UMJsonTransformDepth depth;
            depth.positionZ = roundTo(t.position.z, precision);
            depth.rotationX = roundTo(t.rotation.x, precision);
            depth.rotationY = roundTo(t.rotation.y, precision);
            depth.scaleZ = roundTo(t.scale.z, precision);
            out.transform.depth = depth;
        }

        out.length = roundTo(bone.length, precision);
        // Bone color exists to tint gizmos in the editor; runtimes never
        // read it. `UM.unboundBone` is the fallback, as everywhere else.
        if (options.nonessentialData) {
            const Vec4 c = bone.color.value_or(Vec4(0.55f, 0.58f, 0.66f, 1.0f));
            out.color = std::vector<float>{
                roundTo(c.x, precision), roundTo(c.y, precision), roundTo(c.z, precision),
                roundTo(c.w, precision)};
        }
        out.root = rootIDs.count(bone.id) == 1;
        document.bones.push_back(std::move(out));
    }

    // ---- Slots (sorted by name, members in scene order) ----
    std::vector<std::string> slotOrder;
    std::unordered_map<std::string, std::vector<std::string>> slotMembers;
    for (const SceneImage& image : scene.images) {
        const std::string slot = image.effectiveSlotName();
        if (slotMembers.find(slot) == slotMembers.end()) slotOrder.push_back(slot);
        slotMembers[slot].push_back(image.id.toString());
    }
    std::sort(slotOrder.begin(), slotOrder.end());
    for (const std::string& slot : slotOrder) {
        document.slots.push_back(UMJsonSlot{slot, slotMembers[slot]});
    }

    // ---- Attachments ----
    for (const SceneImage& image : scene.images) {
        UMJsonAttachment out;
        out.id = image.id.toString();
        out.name = image.name;
        out.slot = image.effectiveSlotName();
        out.region = image.assetID.toString();
        out.mesh = image.mesh.id.toString();
        out.hidden = image.isHidden;

        // Neutral values are left out entirely: a runtime treats an absent
        // color as untinted, so writing it would be noise.
        const Vec4& tint = image.tintColor;
        if (!(tint.x == 1.0f && tint.y == 1.0f && tint.z == 1.0f && tint.w == 1.0f)) {
            out.color = std::vector<float>{
                roundTo(tint.x, precision), roundTo(tint.y, precision), roundTo(tint.z, precision),
                roundTo(tint.w, precision)};
        }
        if (image.blendMode != ImageBlendMode::Normal) out.blend = blendModeName(image.blendMode);

        if (image.animationTransformSpace.boneID.has_value()) {
            out.animationSpace = "boneLocal";
            out.animationSpaceBone = image.animationTransformSpace.boneID->toString();
        } else {
            out.animationSpace = "world";
        }

        out.setupPose.position = round2(image.basePosition, precision);
        out.setupPose.rotation = roundTo(image.baseRotation, precision);
        out.setupPose.scale = round2(image.baseScale, precision);
        out.setupPose.shear = round2(image.baseSkew, precision);

        if (image.boneBinding.has_value()) {
            const BoneImageBinding& b = *image.boneBinding;
            UMJsonBoneBinding binding;
            binding.bone = b.boneID.toString();
            binding.localPose.position = round2(b.localPosition, precision);
            binding.localPose.rotation = roundTo(b.localRotation, precision);
            binding.localPose.scale = round2(b.localScale, precision);
            binding.localPose.shear = round2(b.localSkew, precision);
            out.boneBinding = binding;
        }
        document.attachments.push_back(std::move(out));
    }

    // ---- Meshes ----
    for (const SceneImage& image : scene.images) {
        const Vec2 assetSize = [&] {
            const auto it = assets.find(image.assetID);
            return it != assets.end() ? it->second.size : Vec2(64, 64);
        }();
        const Mesh mesh =
            image.mesh.vertices.empty() ? Mesh::makeQuad(image.mesh.name, assetSize) : image.mesh;

        UMJsonMesh out;
        out.id = mesh.id.toString();
        out.name = mesh.name;
        for (const Vec2& v : mesh.vertices) {
            out.vertices.push_back(roundTo(v.x, precision));
            out.vertices.push_back(roundTo(v.y, precision));
        }
        for (const Vec2& v : mesh.uvs) {
            out.uvs.push_back(roundTo(v.x, precision));
            out.uvs.push_back(roundTo(v.y, precision));
        }
        for (std::uint16_t i : mesh.indices) out.triangles.push_back(static_cast<int>(i));
        for (std::uint16_t i : mesh.hullVertexIndices) out.hull.push_back(static_cast<int>(i));
        for (const MeshEdge& e : mesh.internalEdges) {
            out.edges.push_back(static_cast<int>(e.a));
            out.edges.push_back(static_cast<int>(e.b));
        }
        for (const MeshTriangle& t : mesh.manualTriangles) {
            out.manualTriangles.push_back(static_cast<int>(t.a));
            out.manualTriangles.push_back(static_cast<int>(t.b));
            out.manualTriangles.push_back(static_cast<int>(t.c));
        }

        if (mesh.hasSkinningData()) {
            const std::vector<Vec2>& bind =
                mesh.bindVertices.size() == mesh.vertices.size() ? mesh.bindVertices : mesh.vertices;
            std::vector<float> flatBind;
            flatBind.reserve(bind.size() * 2);
            for (const Vec2& v : bind) {
                flatBind.push_back(roundTo(v.x, precision));
                flatBind.push_back(roundTo(v.y, precision));
            }
            out.bindVertices = std::move(flatBind);

            std::vector<std::vector<UMJsonMeshWeight>> weights;
            weights.reserve(mesh.vertexBoneWeights.size());
            for (const std::vector<VertexBoneWeight>& influences : mesh.vertexBoneWeights) {
                std::vector<VertexBoneWeight> sorted = influences;
                std::sort(sorted.begin(), sorted.end(), [](const VertexBoneWeight& a, const VertexBoneWeight& b) {
                    return a.boneID.toString() < b.boneID.toString();
                });
                std::vector<UMJsonMeshWeight> row;
                row.reserve(sorted.size());
                for (const VertexBoneWeight& w : sorted) {
                    row.push_back(UMJsonMeshWeight{w.boneID.toString(), roundTo(w.weight, precision)});
                }
                weights.push_back(std::move(row));
            }
            out.weights = std::move(weights);

            std::vector<std::pair<Uuid, Mat4>> binds(
                mesh.boneInverseBindMatrices.begin(), mesh.boneInverseBindMatrices.end());
            std::sort(binds.begin(), binds.end(), [](const auto& a, const auto& b) {
                return a.first.toString() < b.first.toString();
            });
            std::vector<UMJsonInverseBind> inverseBinds;
            inverseBinds.reserve(binds.size());
            for (const auto& [boneID, matrix] : binds) {
                UMJsonInverseBind entry;
                entry.bone = boneID.toString();
                for (int c = 0; c < 4; ++c) {
                    entry.matrix.push_back(roundTo(matrix.columns[c].x, precision));
                    entry.matrix.push_back(roundTo(matrix.columns[c].y, precision));
                    entry.matrix.push_back(roundTo(matrix.columns[c].z, precision));
                    entry.matrix.push_back(roundTo(matrix.columns[c].w, precision));
                }
                inverseBinds.push_back(std::move(entry));
            }
            out.inverseBindMatrices = std::move(inverseBinds);

            if (mesh.bindImagePose.has_value()) {
                const MeshBindPose& p = *mesh.bindImagePose;
                UMJsonAttachmentPose pose;
                pose.position = round2(p.position, precision);
                pose.rotation = roundTo(p.rotation, precision);
                pose.scale = round2(p.scale, precision);
                pose.shear = round2(p.skew, precision);
                out.bindPose = pose;
            }
        }
        document.meshes.push_back(std::move(out));
    }

    // ---- Skins ----
    for (const Skin& skin : scene.skins) {
        UMJsonSkin out;
        out.id = skin.id.toString();
        out.name = skin.name;
        for (const std::string& slot : skin.describedSlots()) { // already sorted
            const SlotAttachment& imageID = skin.attachments.at(slot);
            UMJsonSkinSlot entry;
            entry.slot = slot;
            if (imageID.has_value()) entry.attachment = imageID->toString();
            out.slots.push_back(std::move(entry));
        }
        for (const Uuid& id : skin.includedSkinIDs) out.includes.push_back(id.toString());
        document.skins.push_back(std::move(out));
    }

    // ---- Constraints ----
    for (const IKConstraint& c : scene.skeleton.ikConstraints) {
        UMJsonIKConstraint out;
        out.id = c.id_.toString();
        out.name = c.name_;
        out.enabled = c.enabled_;
        out.order = c.order_;
        out.mix = roundTo(c.mix_, precision);
        for (const Uuid& id : c.boneChain) out.bones.push_back(id.toString());
        out.target = c.targetBoneID.toString();
        out.bendPositive = c.bendPositive;
        out.stretch = c.stretch;
        out.compress = c.compress;
        out.uniformScale = c.uniformScale;
        out.softness = roundTo(c.softness, precision);
        document.constraints.ik.push_back(std::move(out));
    }
    for (const TransformConstraint& c : scene.skeleton.transformConstraints) {
        UMJsonTransformConstraint out;
        out.id = c.id_.toString();
        out.name = c.name_;
        out.enabled = c.enabled_;
        out.order = c.order_;
        out.mix = roundTo(c.mix_, precision);
        out.target = c.targetBoneID.toString();
        for (const Uuid& id : c.affectedBones) out.bones.push_back(id.toString());
        out.copyPosition = c.copyPosition;
        out.copyRotation = c.copyRotation;
        out.copyScale = c.copyScale;
        out.copyShear = c.copyShear;
        out.positionMix = roundTo(c.positionMix, precision);
        out.rotationMix = roundTo(c.rotationMix, precision);
        out.scaleMix = roundTo(c.scaleMix, precision);
        out.shearMix = roundTo(c.shearMix, precision);
        out.offsetPosition = {roundTo(c.offsetPositionX, precision), roundTo(c.offsetPositionY, precision)};
        out.offsetRotation = roundTo(c.offsetRotation, precision);
        out.offsetScale = {roundTo(c.offsetScaleX, precision), roundTo(c.offsetScaleY, precision)};
        out.offsetShear = roundTo(c.offsetShear, precision);
        document.constraints.transform.push_back(std::move(out));
    }
    for (const PathConstraint& c : scene.skeleton.pathConstraints) {
        UMJsonPathConstraint out;
        out.id = c.id_.toString();
        out.name = c.name_;
        out.enabled = c.enabled_;
        out.order = c.order_;
        out.mix = roundTo(c.mix_, precision);
        for (const Uuid& id : c.pathBones) out.pathBones.push_back(id.toString());
        for (const Uuid& id : c.bones) out.bones.push_back(id.toString());
        out.position = roundTo(c.position, precision);
        out.spacing = roundTo(c.spacing, precision);
        out.spacingMode = pathSpacingModeName(c.spacingMode);
        out.positionMix = roundTo(c.positionMix, precision);
        out.rotateMix = roundTo(c.rotateMix, precision);
        out.offsetRotation = roundTo(c.offsetRotation, precision);
        out.closed = c.closed;
        out.reversed = c.reversed;
        out.rotateMode = pathRotateModeName(c.rotateMode);
        document.constraints.path.push_back(std::move(out));
    }

    // ---- Physics ----
    for (const PhysicsConstraint& c : scene.skeleton.physicsConstraints) {
        UMJsonPhysics out;
        out.id = c.id_.toString();
        out.name = c.name_;
        out.enabled = c.enabled_;
        out.order = c.order_;
        out.mix = roundTo(c.mix_, precision);
        out.type = physicsTypeName(c.physicsType);
        for (const Uuid& id : c.affectedBones) out.bones.push_back(id.toString());
        const PhysicsSettings& s = c.settings;
        out.settings.mass = roundTo(s.mass, precision);
        out.settings.damping = roundTo(s.damping, precision);
        out.settings.stiffness = roundTo(s.stiffness, precision);
        out.settings.gravity = roundTo(s.gravity, precision);
        out.settings.drag = roundTo(s.drag, precision);
        out.settings.wind = round2(s.wind, precision);
        out.settings.stretchLimit = roundTo(s.stretchLimit, precision);
        out.settings.angleLimitMin = roundTo(s.angleLimitMin, precision);
        out.settings.angleLimitMax = roundTo(s.angleLimitMax, precision);
        document.physics.push_back(std::move(out));
    }

    // ---- Events ----
    for (const AnimationEvent& e : scene.animationEvents) {
        UMJsonEvent out;
        out.id = e.id.toString();
        out.name = e.name;
        out.intValue = e.defaultInt;
        out.floatValue = roundTo(e.defaultFloat, precision);
        out.stringValue = e.defaultString;
        out.audioPath = e.audioPath;
        out.volume = roundTo(e.volume, precision);
        out.balance = roundTo(e.balance, precision);
        document.events.push_back(std::move(out));
    }

    // ---- Animations ----
    for (const UMJsonAnimationSource& source : animations) {
        UMJsonAnimation out;
        out.name = source.name;
        out.durationFrames = std::max(source.duration, 0);

        for (const Uuid& boneID : sortedIDs(source.boneClips)) {
            const AnimationClip& clip = source.boneClips.at(boneID);
            // The bone's setup pose is what the runtime falls back to, so
            // it is the only safe basis for dropping a constant track.
            std::optional<UMJsonSetupValue> translateSetup, rotateSetup, scaleSetup, shearSetup;
            const auto it = scene.skeleton.bones().find(boneID);
            if (it != scene.skeleton.bones().end()) {
                const Transform3D2D& base = it->second.baseTransform;
                translateSetup =
                    UMJsonSetupValue::vector(roundTo(base.position.x, precision), roundTo(base.position.y, precision));
                rotateSetup = UMJsonSetupValue::scalar(roundTo(base.rotation.z, precision));
                scaleSetup =
                    UMJsonSetupValue::vector(roundTo(base.scale.x, precision), roundTo(base.scale.y, precision));
                shearSetup = UMJsonSetupValue::vector(roundTo(base.skew.x, precision), roundTo(base.skew.y, precision));
            }

            UMJsonBoneTimelines timelines;
            timelines.bone = boneID.toString();
            timelines.translate =
                buildTrack(clip, boneID, AnimationTrackProperty::Translate, translateSetup, options);
            timelines.rotate = buildTrack(clip, boneID, AnimationTrackProperty::Rotate, rotateSetup, options);
            timelines.scale = buildTrack(clip, boneID, AnimationTrackProperty::Scale, scaleSetup, options);
            timelines.shear = buildTrack(clip, boneID, AnimationTrackProperty::Shear, shearSetup, options);
            if (timelines.translate.has_value() || timelines.rotate.has_value() || timelines.scale.has_value() ||
                timelines.shear.has_value()) {
                out.bones.push_back(std::move(timelines));
            }
        }

        for (const Uuid& imageID : sortedIDs(source.imageClips)) {
            const AnimationClip& clip = source.imageClips.at(imageID);
            const SceneImage* image = scene.image(imageID);

            // A bound sprite animates in its binding's local space, so that
            // -- not the world base pose -- is the fallback the runtime uses.
            std::optional<UMJsonSetupValue> translateSetup, rotateSetup, scaleSetup, shearSetup;
            if (image != nullptr) {
                const SceneImageAnimationPose pose =
                    image->boneBinding.has_value() ? image->boneBinding->localPose() : image->basePose();
                translateSetup =
                    UMJsonSetupValue::vector(roundTo(pose.position.x, precision), roundTo(pose.position.y, precision));
                rotateSetup = UMJsonSetupValue::scalar(roundTo(pose.rotation, precision));
                scaleSetup =
                    UMJsonSetupValue::vector(roundTo(pose.scale.x, precision), roundTo(pose.scale.y, precision));
                shearSetup = UMJsonSetupValue::vector(roundTo(pose.skew.x, precision), roundTo(pose.skew.y, precision));
            }

            UMJsonAttachmentTimelines timelines;
            timelines.attachment = imageID.toString();
            timelines.translate =
                buildTrack(clip, imageID, AnimationTrackProperty::Translate, translateSetup, options);
            timelines.rotate = buildTrack(clip, imageID, AnimationTrackProperty::Rotate, rotateSetup, options);
            timelines.scale = buildTrack(clip, imageID, AnimationTrackProperty::Scale, scaleSetup, options);
            timelines.shear = buildTrack(clip, imageID, AnimationTrackProperty::Shear, shearSetup, options);
            if (image != nullptr) timelines.deform = buildDeformKeys(clip, imageID, image->mesh, options);
            if (timelines.translate.has_value() || timelines.rotate.has_value() || timelines.scale.has_value() ||
                timelines.shear.has_value() || timelines.deform.has_value()) {
                out.attachments.push_back(std::move(timelines));
            }
        }

        // Constraint property timelines, from the scene clip.
        std::vector<Uuid> constraintIDs;
        for (const BoneConstraint* c : scene.skeleton.allConstraints()) constraintIDs.push_back(c->id());
        std::sort(constraintIDs.begin(), constraintIDs.end(), [](const Uuid& a, const Uuid& b) {
            return a.toString() < b.toString();
        });
        for (const Uuid& constraintID : constraintIDs) {
            UMJsonConstraintTimelines timelines;
            timelines.constraint = constraintID.toString();
            for (AnimationTrackProperty property : allAnimationTrackProperties()) {
                if (domain(property) != AnimationTrackDomain::Constraint) continue;
                const std::vector<Keyframe>& keys = source.sceneClip.keyframesFor(constraintID, property);
                if (keys.empty()) continue;

                UMJsonConstraintTrack track;
                track.property = trackPropertyName(property);
                track.keys.reserve(keys.size());
                for (const Keyframe& key : keys) track.keys.push_back(convertKeyframe(key, precision));
                timelines.properties.push_back(std::move(track));
            }
            if (!timelines.properties.empty()) out.constraints.push_back(std::move(timelines));
        }

        // Draw order.
        for (const Keyframe& key :
             source.sceneClip.keyframesFor(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder)) {
            UMJsonDrawOrderKey entry;
            entry.frame = key.frame;
            if (const auto* ids = drawOrderValue(key.value)) {
                for (const Uuid& id : *ids) entry.order.push_back(id.toString());
            }
            out.drawOrder.push_back(std::move(entry));
        }

        // Events, per definition.
        for (const AnimationEvent& definition : scene.animationEvents) {
            const std::vector<Keyframe>& keys =
                source.sceneClip.keyframesFor(definition.id, AnimationTrackProperty::Event);
            if (keys.empty()) continue;

            UMJsonEventTimeline timeline;
            timeline.event = definition.id.toString();
            for (const Keyframe& key : keys) {
                UMJsonEventKey entry;
                entry.frame = key.frame;
                if (const AnimationEventPayload* payload = eventPayload(key.value)) {
                    entry.intValue = payload->intValue;
                    if (payload->floatValue.has_value()) entry.floatValue = roundTo(*payload->floatValue, precision);
                    entry.stringValue = payload->stringValue;
                }
                timeline.keys.push_back(std::move(entry));
            }
            out.events.push_back(std::move(timeline));
        }

        document.animations.push_back(std::move(out));
    }

    return document;
}

JsonValue toJson(const UMJsonDocument& document) {
    JsonValue j = JsonValue::makeObject();
    j.set("format", JsonValue::makeString(document.format));
    j.set("version", JsonValue::makeString(document.version));
    j.set("engineVersion", JsonValue::makeString(document.engineVersion));
    j.set("generator", JsonValue::makeString(document.generator));
    j.set("exportDate", JsonValue::makeString(document.exportDate));

    JsonValue compatibility = JsonValue::makeObject();
    compatibility.set("minRuntimeVersion", JsonValue::makeString(document.compatibility.minRuntimeVersion));
    compatibility.set("featureFlags", stringArrayToJson(document.compatibility.featureFlags));
    j.set("compatibility", compatibility);

    JsonValue metadata = JsonValue::makeObject();
    metadata.set("projectName", JsonValue::makeString(document.metadata.projectName));
    metadata.set("framesPerSecond", JsonValue::makeNumber(document.metadata.framesPerSecond));
    metadata.set("playbackStartFrame", JsonValue::makeNumber(document.metadata.playbackStartFrame));
    metadata.set("playbackEndFrame", JsonValue::makeNumber(document.metadata.playbackEndFrame));
    metadata.set("units", JsonValue::makeString(document.metadata.units));
    metadata.set("drawOrder", stringArrayToJson(document.metadata.drawOrder));
    JsonValue custom = JsonValue::makeObject();
    for (const auto& [key, value] : document.metadata.custom) custom.set(key, JsonValue::makeString(value));
    metadata.set("custom", custom);
    j.set("metadata", metadata);

    JsonValue::Array regions;
    for (const UMJsonAtlasRegion& region : document.atlas.regions) {
        JsonValue r = JsonValue::makeObject();
        r.set("id", JsonValue::makeString(region.id));
        r.set("name", JsonValue::makeString(region.name));
        r.set("width", JsonValue::makeNumber(region.width));
        r.set("height", JsonValue::makeNumber(region.height));
        r.set("embedded", JsonValue::makeBool(region.embedded));
        if (region.path.has_value()) r.set("path", JsonValue::makeString(*region.path));
        if (region.dataBase64.has_value()) r.set("dataBase64", JsonValue::makeString(*region.dataBase64));
        regions.push_back(r);
    }
    JsonValue atlas = JsonValue::makeObject();
    atlas.set("regions", JsonValue::makeArray(std::move(regions)));
    j.set("atlas", atlas);

    JsonValue::Array bones;
    for (const UMJsonBone& bone : document.bones) {
        JsonValue b = JsonValue::makeObject();
        b.set("id", JsonValue::makeString(bone.id));
        b.set("name", JsonValue::makeString(bone.name));
        if (bone.parent.has_value()) b.set("parent", JsonValue::makeString(*bone.parent));

        JsonValue transform = JsonValue::makeObject();
        transform.set("position", floatArrayToJson(bone.transform.position));
        transform.set("rotation", JsonValue::makeNumber(bone.transform.rotation));
        transform.set("scale", floatArrayToJson(bone.transform.scale));
        transform.set("shear", floatArrayToJson(bone.transform.shear));
        if (bone.transform.depth.has_value()) {
            JsonValue depth = JsonValue::makeObject();
            depth.set("positionZ", JsonValue::makeNumber(bone.transform.depth->positionZ));
            depth.set("rotationX", JsonValue::makeNumber(bone.transform.depth->rotationX));
            depth.set("rotationY", JsonValue::makeNumber(bone.transform.depth->rotationY));
            depth.set("scaleZ", JsonValue::makeNumber(bone.transform.depth->scaleZ));
            transform.set("depth", depth);
        }
        b.set("transform", transform);

        b.set("length", JsonValue::makeNumber(bone.length));
        if (bone.color.has_value()) b.set("color", floatArrayToJson(*bone.color));
        b.set("root", JsonValue::makeBool(bone.root));
        bones.push_back(b);
    }
    j.set("bones", JsonValue::makeArray(std::move(bones)));

    JsonValue::Array slots;
    for (const UMJsonSlot& slot : document.slots) {
        JsonValue s = JsonValue::makeObject();
        s.set("name", JsonValue::makeString(slot.name));
        s.set("attachments", stringArrayToJson(slot.attachments));
        slots.push_back(s);
    }
    j.set("slots", JsonValue::makeArray(std::move(slots)));

    JsonValue::Array attachments;
    for (const UMJsonAttachment& attachment : document.attachments) {
        JsonValue a = JsonValue::makeObject();
        a.set("id", JsonValue::makeString(attachment.id));
        a.set("name", JsonValue::makeString(attachment.name));
        a.set("slot", JsonValue::makeString(attachment.slot));
        a.set("region", JsonValue::makeString(attachment.region));
        if (attachment.mesh.has_value()) a.set("mesh", JsonValue::makeString(*attachment.mesh));
        a.set("hidden", JsonValue::makeBool(attachment.hidden));
        if (attachment.color.has_value()) a.set("color", floatArrayToJson(*attachment.color));
        if (attachment.blend.has_value()) a.set("blend", JsonValue::makeString(*attachment.blend));
        a.set("animationSpace", JsonValue::makeString(attachment.animationSpace));
        if (attachment.animationSpaceBone.has_value()) {
            a.set("animationSpaceBone", JsonValue::makeString(*attachment.animationSpaceBone));
        }
        a.set("setupPose", poseToJson(attachment.setupPose));
        if (attachment.boneBinding.has_value()) {
            JsonValue binding = JsonValue::makeObject();
            binding.set("bone", JsonValue::makeString(attachment.boneBinding->bone));
            binding.set("localPose", poseToJson(attachment.boneBinding->localPose));
            a.set("boneBinding", binding);
        }
        attachments.push_back(a);
    }
    j.set("attachments", JsonValue::makeArray(std::move(attachments)));

    JsonValue::Array meshes;
    for (const UMJsonMesh& mesh : document.meshes) {
        JsonValue m = JsonValue::makeObject();
        m.set("id", JsonValue::makeString(mesh.id));
        m.set("name", JsonValue::makeString(mesh.name));
        m.set("vertices", floatArrayToJson(mesh.vertices));
        m.set("uvs", floatArrayToJson(mesh.uvs));
        m.set("triangles", intArrayToJson(mesh.triangles));
        m.set("hull", intArrayToJson(mesh.hull));
        m.set("edges", intArrayToJson(mesh.edges));
        m.set("manualTriangles", intArrayToJson(mesh.manualTriangles));
        if (mesh.bindVertices.has_value()) m.set("bindVertices", floatArrayToJson(*mesh.bindVertices));
        if (mesh.weights.has_value()) {
            JsonValue::Array perVertex;
            for (const std::vector<UMJsonMeshWeight>& influences : *mesh.weights) {
                JsonValue::Array row;
                for (const UMJsonMeshWeight& w : influences) {
                    JsonValue weight = JsonValue::makeObject();
                    weight.set("bone", JsonValue::makeString(w.bone));
                    weight.set("weight", JsonValue::makeNumber(w.weight));
                    row.push_back(weight);
                }
                perVertex.push_back(JsonValue::makeArray(std::move(row)));
            }
            m.set("weights", JsonValue::makeArray(std::move(perVertex)));
        }
        if (mesh.inverseBindMatrices.has_value()) {
            JsonValue::Array binds;
            for (const UMJsonInverseBind& bind : *mesh.inverseBindMatrices) {
                JsonValue entry = JsonValue::makeObject();
                entry.set("bone", JsonValue::makeString(bind.bone));
                entry.set("matrix", floatArrayToJson(bind.matrix));
                binds.push_back(entry);
            }
            m.set("inverseBindMatrices", JsonValue::makeArray(std::move(binds)));
        }
        if (mesh.bindPose.has_value()) m.set("bindPose", poseToJson(*mesh.bindPose));
        meshes.push_back(m);
    }
    j.set("meshes", JsonValue::makeArray(std::move(meshes)));

    JsonValue::Array skins;
    for (const UMJsonSkin& skin : document.skins) {
        JsonValue s = JsonValue::makeObject();
        s.set("id", JsonValue::makeString(skin.id));
        s.set("name", JsonValue::makeString(skin.name));
        JsonValue::Array slotEntries;
        for (const UMJsonSkinSlot& slot : skin.slots) {
            JsonValue entry = JsonValue::makeObject();
            entry.set("slot", JsonValue::makeString(slot.slot));
            // Explicit null when the skin deliberately empties the slot --
            // distinct from the slot being absent entirely.
            entry.set(
                "attachment",
                slot.attachment.has_value() ? JsonValue::makeString(*slot.attachment) : JsonValue::makeNull());
            slotEntries.push_back(entry);
        }
        s.set("slots", JsonValue::makeArray(std::move(slotEntries)));
        s.set("includes", stringArrayToJson(skin.includes));
        skins.push_back(s);
    }
    j.set("skins", JsonValue::makeArray(std::move(skins)));

    JsonValue constraints = JsonValue::makeObject();
    JsonValue::Array ik;
    for (const UMJsonIKConstraint& c : document.constraints.ik) {
        JsonValue e = JsonValue::makeObject();
        e.set("id", JsonValue::makeString(c.id));
        e.set("name", JsonValue::makeString(c.name));
        e.set("enabled", JsonValue::makeBool(c.enabled));
        e.set("order", JsonValue::makeNumber(c.order));
        e.set("mix", JsonValue::makeNumber(c.mix));
        e.set("bones", stringArrayToJson(c.bones));
        e.set("target", JsonValue::makeString(c.target));
        e.set("bendPositive", JsonValue::makeBool(c.bendPositive));
        e.set("stretch", JsonValue::makeBool(c.stretch));
        e.set("compress", JsonValue::makeBool(c.compress));
        e.set("uniformScale", JsonValue::makeBool(c.uniformScale));
        e.set("softness", JsonValue::makeNumber(c.softness));
        ik.push_back(e);
    }
    constraints.set("ik", JsonValue::makeArray(std::move(ik)));

    JsonValue::Array transform;
    for (const UMJsonTransformConstraint& c : document.constraints.transform) {
        JsonValue e = JsonValue::makeObject();
        e.set("id", JsonValue::makeString(c.id));
        e.set("name", JsonValue::makeString(c.name));
        e.set("enabled", JsonValue::makeBool(c.enabled));
        e.set("order", JsonValue::makeNumber(c.order));
        e.set("mix", JsonValue::makeNumber(c.mix));
        e.set("target", JsonValue::makeString(c.target));
        e.set("bones", stringArrayToJson(c.bones));
        e.set("copyPosition", JsonValue::makeBool(c.copyPosition));
        e.set("copyRotation", JsonValue::makeBool(c.copyRotation));
        e.set("copyScale", JsonValue::makeBool(c.copyScale));
        e.set("copyShear", JsonValue::makeBool(c.copyShear));
        e.set("positionMix", JsonValue::makeNumber(c.positionMix));
        e.set("rotationMix", JsonValue::makeNumber(c.rotationMix));
        e.set("scaleMix", JsonValue::makeNumber(c.scaleMix));
        e.set("shearMix", JsonValue::makeNumber(c.shearMix));
        e.set("offsetPosition", floatArrayToJson(c.offsetPosition));
        e.set("offsetRotation", JsonValue::makeNumber(c.offsetRotation));
        e.set("offsetScale", floatArrayToJson(c.offsetScale));
        e.set("offsetShear", JsonValue::makeNumber(c.offsetShear));
        transform.push_back(e);
    }
    constraints.set("transform", JsonValue::makeArray(std::move(transform)));

    JsonValue::Array path;
    for (const UMJsonPathConstraint& c : document.constraints.path) {
        JsonValue e = JsonValue::makeObject();
        e.set("id", JsonValue::makeString(c.id));
        e.set("name", JsonValue::makeString(c.name));
        e.set("enabled", JsonValue::makeBool(c.enabled));
        e.set("order", JsonValue::makeNumber(c.order));
        e.set("mix", JsonValue::makeNumber(c.mix));
        e.set("pathBones", stringArrayToJson(c.pathBones));
        e.set("bones", stringArrayToJson(c.bones));
        e.set("position", JsonValue::makeNumber(c.position));
        e.set("spacing", JsonValue::makeNumber(c.spacing));
        e.set("spacingMode", JsonValue::makeString(c.spacingMode));
        e.set("positionMix", JsonValue::makeNumber(c.positionMix));
        e.set("rotateMix", JsonValue::makeNumber(c.rotateMix));
        e.set("offsetRotation", JsonValue::makeNumber(c.offsetRotation));
        e.set("closed", JsonValue::makeBool(c.closed));
        e.set("reversed", JsonValue::makeBool(c.reversed));
        e.set("rotateMode", JsonValue::makeString(c.rotateMode));
        path.push_back(e);
    }
    constraints.set("path", JsonValue::makeArray(std::move(path)));
    j.set("constraints", constraints);

    JsonValue::Array physics;
    for (const UMJsonPhysics& p : document.physics) {
        JsonValue e = JsonValue::makeObject();
        e.set("id", JsonValue::makeString(p.id));
        e.set("name", JsonValue::makeString(p.name));
        e.set("enabled", JsonValue::makeBool(p.enabled));
        e.set("order", JsonValue::makeNumber(p.order));
        e.set("mix", JsonValue::makeNumber(p.mix));
        e.set("type", JsonValue::makeString(p.type));
        e.set("bones", stringArrayToJson(p.bones));
        JsonValue settings = JsonValue::makeObject();
        settings.set("mass", JsonValue::makeNumber(p.settings.mass));
        settings.set("damping", JsonValue::makeNumber(p.settings.damping));
        settings.set("stiffness", JsonValue::makeNumber(p.settings.stiffness));
        settings.set("gravity", JsonValue::makeNumber(p.settings.gravity));
        settings.set("drag", JsonValue::makeNumber(p.settings.drag));
        settings.set("wind", floatArrayToJson(p.settings.wind));
        settings.set("stretchLimit", JsonValue::makeNumber(p.settings.stretchLimit));
        settings.set("angleLimitMin", JsonValue::makeNumber(p.settings.angleLimitMin));
        settings.set("angleLimitMax", JsonValue::makeNumber(p.settings.angleLimitMax));
        e.set("settings", settings);
        physics.push_back(e);
    }
    j.set("physics", JsonValue::makeArray(std::move(physics)));

    JsonValue::Array events;
    for (const UMJsonEvent& e : document.events) {
        JsonValue entry = JsonValue::makeObject();
        entry.set("id", JsonValue::makeString(e.id));
        entry.set("name", JsonValue::makeString(e.name));
        entry.set("int", JsonValue::makeNumber(e.intValue));
        entry.set("float", JsonValue::makeNumber(e.floatValue));
        entry.set("string", JsonValue::makeString(e.stringValue));
        entry.set("audioPath", JsonValue::makeString(e.audioPath));
        entry.set("volume", JsonValue::makeNumber(e.volume));
        entry.set("balance", JsonValue::makeNumber(e.balance));
        events.push_back(entry);
    }
    j.set("events", JsonValue::makeArray(std::move(events)));

    JsonValue::Array animations;
    for (const UMJsonAnimation& animation : document.animations) {
        JsonValue a = JsonValue::makeObject();
        a.set("name", JsonValue::makeString(animation.name));
        a.set("durationFrames", JsonValue::makeNumber(animation.durationFrames));

        JsonValue::Array boneTimelines;
        for (const UMJsonBoneTimelines& timelines : animation.bones) {
            JsonValue t = JsonValue::makeObject();
            t.set("bone", JsonValue::makeString(timelines.bone));
            if (timelines.translate.has_value()) t.set("translate", keyframesToJson(*timelines.translate));
            if (timelines.rotate.has_value()) t.set("rotate", keyframesToJson(*timelines.rotate));
            if (timelines.scale.has_value()) t.set("scale", keyframesToJson(*timelines.scale));
            if (timelines.shear.has_value()) t.set("shear", keyframesToJson(*timelines.shear));
            boneTimelines.push_back(t);
        }
        a.set("bones", JsonValue::makeArray(std::move(boneTimelines)));

        JsonValue::Array attachmentTimelines;
        for (const UMJsonAttachmentTimelines& timelines : animation.attachments) {
            JsonValue t = JsonValue::makeObject();
            t.set("attachment", JsonValue::makeString(timelines.attachment));
            if (timelines.translate.has_value()) t.set("translate", keyframesToJson(*timelines.translate));
            if (timelines.rotate.has_value()) t.set("rotate", keyframesToJson(*timelines.rotate));
            if (timelines.scale.has_value()) t.set("scale", keyframesToJson(*timelines.scale));
            if (timelines.shear.has_value()) t.set("shear", keyframesToJson(*timelines.shear));
            if (timelines.deform.has_value()) {
                JsonValue::Array deform;
                for (const UMJsonDeformKey& key : *timelines.deform) {
                    JsonValue entry = JsonValue::makeObject();
                    entry.set("frame", JsonValue::makeNumber(key.frame));
                    entry.set("interp", JsonValue::makeString(key.interp));
                    entry.set("vertices", floatArrayToJson(key.vertices));
                    deform.push_back(entry);
                }
                t.set("deform", JsonValue::makeArray(std::move(deform)));
            }
            attachmentTimelines.push_back(t);
        }
        a.set("attachments", JsonValue::makeArray(std::move(attachmentTimelines)));

        JsonValue::Array constraintTimelines;
        for (const UMJsonConstraintTimelines& timelines : animation.constraints) {
            JsonValue t = JsonValue::makeObject();
            t.set("constraint", JsonValue::makeString(timelines.constraint));
            JsonValue::Array properties;
            for (const UMJsonConstraintTrack& track : timelines.properties) {
                JsonValue entry = JsonValue::makeObject();
                entry.set("property", JsonValue::makeString(track.property));
                entry.set("keys", keyframesToJson(track.keys));
                properties.push_back(entry);
            }
            t.set("properties", JsonValue::makeArray(std::move(properties)));
            constraintTimelines.push_back(t);
        }
        a.set("constraints", JsonValue::makeArray(std::move(constraintTimelines)));

        JsonValue::Array drawOrder;
        for (const UMJsonDrawOrderKey& key : animation.drawOrder) {
            JsonValue entry = JsonValue::makeObject();
            entry.set("frame", JsonValue::makeNumber(key.frame));
            entry.set("order", stringArrayToJson(key.order));
            drawOrder.push_back(entry);
        }
        a.set("drawOrder", JsonValue::makeArray(std::move(drawOrder)));

        JsonValue::Array eventTimelines;
        for (const UMJsonEventTimeline& timeline : animation.events) {
            JsonValue t = JsonValue::makeObject();
            t.set("event", JsonValue::makeString(timeline.event));
            JsonValue::Array keys;
            for (const UMJsonEventKey& key : timeline.keys) {
                JsonValue entry = JsonValue::makeObject();
                entry.set("frame", JsonValue::makeNumber(key.frame));
                // Each override omitted when absent: absent means "inherit
                // the definition's default", not 0 or "".
                if (key.intValue.has_value()) entry.set("int", JsonValue::makeNumber(*key.intValue));
                if (key.floatValue.has_value()) entry.set("float", JsonValue::makeNumber(*key.floatValue));
                if (key.stringValue.has_value()) entry.set("string", JsonValue::makeString(*key.stringValue));
                keys.push_back(entry);
            }
            t.set("keys", JsonValue::makeArray(std::move(keys)));
            eventTimelines.push_back(t);
        }
        a.set("events", JsonValue::makeArray(std::move(eventTimelines)));

        animations.push_back(a);
    }
    j.set("animations", JsonValue::makeArray(std::move(animations)));

    return j;
}

std::string writeUMJson(const UMJsonDocument& document, const UMJsonExportOptions& options) {
    return toJson(document).dump(options.prettyPrint);
}

} // namespace umeshcore
