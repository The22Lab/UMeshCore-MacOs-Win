#include "umeshcore/Serialization/SavedSceneImage.h"

#include <algorithm>

#include "umeshcore/Serialization/SavedAnimation.h"
#include "umeshcore/Serialization/SavedGeometry.h"

namespace umeshcore {

namespace {

JsonValue vec2ArrayToJson(const std::vector<Vec2>& values) {
    JsonValue::Array arr;
    arr.reserve(values.size());
    for (const Vec2& v : values) arr.push_back(toJson(v));
    return JsonValue::makeArray(std::move(arr));
}

std::vector<Vec2> vec2ArrayFromJson(const JsonValue* j) {
    std::vector<Vec2> out;
    if (j == nullptr) return out;
    for (const JsonValue& v : j->asArray()) out.push_back(vec2FromJson(v));
    return out;
}

JsonValue u16ArrayToJson(const std::vector<std::uint16_t>& values) {
    JsonValue::Array arr;
    arr.reserve(values.size());
    for (std::uint16_t v : values) arr.push_back(JsonValue::makeNumber(v));
    return JsonValue::makeArray(std::move(arr));
}

std::vector<std::uint16_t> u16ArrayFromJson(const JsonValue* j) {
    std::vector<std::uint16_t> out;
    if (j == nullptr) return out;
    for (const JsonValue& v : j->asArray()) out.push_back(v.asUint16());
    return out;
}

} // namespace

JsonValue toJson(const MeshBindPose& pose) {
    JsonValue j = JsonValue::makeObject();
    j.set("position", toJson(pose.position));
    j.set("rotation", JsonValue::makeNumber(pose.rotation));
    j.set("scale", toJson(pose.scale));
    j.set("skew", toJson(pose.skew));
    return j;
}

MeshBindPose meshBindPoseFromJson(const JsonValue& j) {
    MeshBindPose pose;
    pose.position = vec2FromJson(*j.find("position"));
    pose.rotation = j.find("rotation")->asFloat();
    pose.scale = vec2FromJson(*j.find("scale"));
    pose.skew = vec2FromJson(*j.find("skew"));
    return pose;
}

JsonValue toJson(const Mesh& mesh) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(mesh.id));
    j.set("name", JsonValue::makeString(mesh.name));
    j.set("vertices", vec2ArrayToJson(mesh.vertices));
    j.set("uvs", vec2ArrayToJson(mesh.uvs));
    j.set("indices", u16ArrayToJson(mesh.indices));
    j.set("hullVertexIndices", u16ArrayToJson(mesh.hullVertexIndices));

    JsonValue::Array edges;
    edges.reserve(mesh.internalEdges.size());
    for (const MeshEdge& e : mesh.internalEdges) {
        JsonValue edge = JsonValue::makeObject();
        edge.set("a", JsonValue::makeNumber(e.a));
        edge.set("b", JsonValue::makeNumber(e.b));
        edges.push_back(edge);
    }
    j.set("internalEdges", JsonValue::makeArray(std::move(edges)));

    JsonValue::Array triangles;
    triangles.reserve(mesh.manualTriangles.size());
    for (const MeshTriangle& t : mesh.manualTriangles) {
        JsonValue triangle = JsonValue::makeObject();
        triangle.set("a", JsonValue::makeNumber(t.a));
        triangle.set("b", JsonValue::makeNumber(t.b));
        triangle.set("c", JsonValue::makeNumber(t.c));
        triangles.push_back(triangle);
    }
    j.set("manualTriangles", JsonValue::makeArray(std::move(triangles)));

    JsonValue::Array weightsPerVertex;
    weightsPerVertex.reserve(mesh.vertexBoneWeights.size());
    for (const std::vector<VertexBoneWeight>& influences : mesh.vertexBoneWeights) {
        JsonValue::Array weights;
        weights.reserve(influences.size());
        for (const VertexBoneWeight& w : influences) {
            JsonValue weight = JsonValue::makeObject();
            weight.set("boneID", toJson(w.boneID));
            weight.set("weight", JsonValue::makeNumber(w.weight));
            weights.push_back(weight);
        }
        weightsPerVertex.push_back(JsonValue::makeArray(std::move(weights)));
    }
    j.set("vertexBoneWeights", JsonValue::makeArray(std::move(weightsPerVertex)));

    j.set("bindVertices", vec2ArrayToJson(mesh.bindVertices));

    // A UUID-keyed map becomes an array of records, sorted for stable
    // output -- the Swift source's own convention for every such map.
    std::vector<std::pair<Uuid, Mat4>> inverseBinds(
        mesh.boneInverseBindMatrices.begin(), mesh.boneInverseBindMatrices.end());
    std::sort(inverseBinds.begin(), inverseBinds.end(), [](const auto& a, const auto& b) {
        return a.first.toString() < b.first.toString();
    });
    JsonValue::Array matrices;
    matrices.reserve(inverseBinds.size());
    for (const auto& [boneID, matrix] : inverseBinds) {
        JsonValue entry = JsonValue::makeObject();
        entry.set("boneID", toJson(boneID));
        entry.set("matrix", toJson(matrix));
        matrices.push_back(entry);
    }
    j.set("boneInverseBindMatrices", JsonValue::makeArray(std::move(matrices)));

    if (mesh.bindImagePose.has_value()) j.set("bindImagePose", toJson(*mesh.bindImagePose));
    return j;
}

Mesh meshFromJson(const JsonValue& j) {
    Mesh mesh;
    // id/name/vertices/uvs/indices/hullVertexIndices are required -- the
    // fields that always existed. Everything below them is `?? []`, exactly
    // as SavedMesh's hand-written init(from:) has it.
    mesh.id = uuidFromJson(*j.find("id"));
    mesh.name = j.find("name")->asString();
    mesh.vertices = vec2ArrayFromJson(j.find("vertices"));
    mesh.uvs = vec2ArrayFromJson(j.find("uvs"));
    mesh.indices = u16ArrayFromJson(j.find("indices"));
    mesh.hullVertexIndices = u16ArrayFromJson(j.find("hullVertexIndices"));

    const JsonValue* internalEdges = j.find("internalEdges");
    if (internalEdges != nullptr) {
        for (const JsonValue& e : internalEdges->asArray()) {
            mesh.internalEdges.emplace_back(e.find("a")->asUint16(), e.find("b")->asUint16());
        }
    }

    const JsonValue* manualTriangles = j.find("manualTriangles");
    if (manualTriangles != nullptr) {
        for (const JsonValue& t : manualTriangles->asArray()) {
            mesh.manualTriangles.push_back(
                MeshTriangle{t.find("a")->asUint16(), t.find("b")->asUint16(), t.find("c")->asUint16()});
        }
    }

    const JsonValue* vertexBoneWeights = j.find("vertexBoneWeights");
    if (vertexBoneWeights != nullptr) {
        for (const JsonValue& perVertex : vertexBoneWeights->asArray()) {
            std::vector<VertexBoneWeight> influences;
            for (const JsonValue& w : perVertex.asArray()) {
                influences.push_back(
                    VertexBoneWeight{uuidFromJson(*w.find("boneID")), w.find("weight")->asFloat()});
            }
            mesh.vertexBoneWeights.push_back(std::move(influences));
        }
    }

    mesh.bindVertices = vec2ArrayFromJson(j.find("bindVertices"));

    const JsonValue* inverseBinds = j.find("boneInverseBindMatrices");
    if (inverseBinds != nullptr) {
        for (const JsonValue& entry : inverseBinds->asArray()) {
            mesh.boneInverseBindMatrices[uuidFromJson(*entry.find("boneID"))] = mat4FromJson(*entry.find("matrix"));
        }
    }

    const JsonValue* bindImagePose = j.find("bindImagePose");
    if (bindImagePose != nullptr) mesh.bindImagePose = meshBindPoseFromJson(*bindImagePose);

    // The load-time sanitize + repair pass, in Swift's own order -- see
    // this file's header for why it exists.
    return mesh.sanitizedSkinningData().repairedIfInvalid().first;
}

JsonValue toJson(const BoneImageBinding& binding) {
    JsonValue j = JsonValue::makeObject();
    j.set("boneID", toJson(binding.boneID));
    j.set("localPosition", toJson(binding.localPosition));
    j.set("localScale", toJson(binding.localScale));
    j.set("localRotation", JsonValue::makeNumber(binding.localRotation));
    j.set("localSkew", toJson(binding.localSkew));
    return j;
}

BoneImageBinding boneImageBindingFromJson(const JsonValue& j) {
    BoneImageBinding binding;
    binding.boneID = uuidFromJson(*j.find("boneID"));
    binding.localPosition = vec2FromJson(*j.find("localPosition"));
    // localScale is a SavedScale2 -- may be a bare number in old files.
    binding.localScale = scale2FromJson(*j.find("localScale"));
    binding.localRotation = j.find("localRotation")->asFloat();
    binding.localSkew = vec2FromJson(*j.find("localSkew"));
    return binding;
}

const char* blendModeName(ImageBlendMode mode) {
    switch (mode) {
        case ImageBlendMode::Normal: return "normal";
        case ImageBlendMode::Additive: return "additive";
        case ImageBlendMode::Multiply: return "multiply";
        case ImageBlendMode::Screen: return "screen";
    }
    return "normal";
}

ImageBlendMode blendModeFromName(const std::string& name) {
    if (name == "additive") return ImageBlendMode::Additive;
    if (name == "multiply") return ImageBlendMode::Multiply;
    if (name == "screen") return ImageBlendMode::Screen;
    return ImageBlendMode::Normal; // matches Swift's `?? .normal`.
}

JsonValue toJson(const SceneImage& image) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(image.id));
    j.set("assetID", toJson(image.assetID));
    j.set("name", JsonValue::makeString(image.name));

    j.set("basePosition", toJson(image.basePosition));
    j.set("position", toJson(image.position));
    j.set("baseScale", toJson(image.baseScale));
    j.set("scale", toJson(image.scale));
    j.set("baseRotation", JsonValue::makeNumber(image.baseRotation));
    j.set("rotation", JsonValue::makeNumber(image.rotation));
    j.set("baseRotation3D", toJson(image.baseRotation3D));
    j.set("rotation3D", toJson(image.rotation3D));
    j.set("baseSkew", toJson(image.baseSkew));
    j.set("skew", toJson(image.skew));

    j.set("mesh", toJson(image.mesh));
    if (image.boneBinding.has_value()) j.set("boneBinding", toJson(*image.boneBinding));
    j.set("isHidden", JsonValue::makeBool(image.isHidden));
    j.set("slotName", JsonValue::makeString(image.slotName));
    if (image.normalMapAssetID.has_value()) j.set("normalMapAssetID", toJson(*image.normalMapAssetID));

    JsonValue::Array tint;
    tint.push_back(JsonValue::makeNumber(image.tintColor.x));
    tint.push_back(JsonValue::makeNumber(image.tintColor.y));
    tint.push_back(JsonValue::makeNumber(image.tintColor.z));
    tint.push_back(JsonValue::makeNumber(image.tintColor.w));
    j.set("tintColor", JsonValue::makeArray(std::move(tint)));

    j.set("blendMode", JsonValue::makeString(blendModeName(image.blendMode)));
    j.set("animationClip", toJson(image.animationClip));

    JsonValue space = JsonValue::makeObject();
    if (image.animationTransformSpace.boneID.has_value()) {
        space.set("kind", JsonValue::makeString("boneLocal"));
        space.set("boneID", toJson(*image.animationTransformSpace.boneID));
    } else {
        space.set("kind", JsonValue::makeString("world"));
    }
    j.set("animationTransformSpace", space);

    return j;
}

SceneImage sceneImageFromJson(const JsonValue& j) {
    SceneImage image;
    image.id = uuidFromJson(*j.find("id"));
    image.assetID = uuidFromJson(*j.find("assetID"));
    image.name = j.find("name")->asString();

    image.basePosition = vec2FromJson(*j.find("basePosition"));
    image.position = vec2FromJson(*j.find("position"));
    image.baseScale = scale2FromJson(*j.find("baseScale"));
    image.scale = scale2FromJson(*j.find("scale"));
    image.baseRotation = j.find("baseRotation")->asFloat();
    image.rotation = j.find("rotation")->asFloat();
    image.baseRotation3D = vec3FromJson(*j.find("baseRotation3D"));
    image.rotation3D = vec3FromJson(*j.find("rotation3D"));
    image.baseSkew = vec2FromJson(*j.find("baseSkew"));
    image.skew = vec2FromJson(*j.find("skew"));

    const JsonValue* mesh = j.find("mesh");
    // `mesh ?? Mesh(name: "\(name) Mesh")`.
    image.mesh = mesh != nullptr ? meshFromJson(*mesh) : Mesh(image.name + " Mesh");

    const JsonValue* boneBinding = j.find("boneBinding");
    if (boneBinding != nullptr) image.boneBinding = boneImageBindingFromJson(*boneBinding);

    image.isHidden = j.find("isHidden")->asBool();

    const JsonValue* slotName = j.find("slotName");
    image.slotName = slotName != nullptr ? slotName->asString() : std::string(); // `?? ""`.

    const JsonValue* normalMapAssetID = j.find("normalMapAssetID");
    if (normalMapAssetID != nullptr) image.normalMapAssetID = uuidFromJson(*normalMapAssetID);

    // A tint that isn't exactly four components is ignored, not
    // partially applied -- matching Swift's `count == 4` guard.
    const JsonValue* tintColor = j.find("tintColor");
    if (tintColor != nullptr && tintColor->asArray().size() == 4) {
        const JsonValue::Array& t = tintColor->asArray();
        image.tintColor = Vec4(t[0].asFloat(), t[1].asFloat(), t[2].asFloat(), t[3].asFloat());
    } else {
        image.tintColor = Vec4(1, 1, 1, 1);
    }

    const JsonValue* blendMode = j.find("blendMode");
    image.blendMode = blendMode != nullptr ? blendModeFromName(blendMode->asString()) : ImageBlendMode::Normal;

    image.animationClip = animationClipFromJson(*j.find("animationClip"));

    // Three-tier fallback -- see this file's header.
    const JsonValue* space = j.find("animationTransformSpace");
    const std::optional<Uuid> bindingBoneID =
        image.boneBinding.has_value() ? std::optional<Uuid>(image.boneBinding->boneID) : std::nullopt;
    if (space != nullptr) {
        const JsonValue* kind = space->find("kind");
        if (kind != nullptr && kind->asString() == "boneLocal") {
            const JsonValue* boneID = space->find("boneID");
            const std::optional<Uuid> resolved =
                boneID != nullptr ? std::optional<Uuid>(uuidFromJson(*boneID)) : bindingBoneID;
            image.animationTransformSpace = TransformAnimationSpace{resolved};
        } else {
            image.animationTransformSpace = TransformAnimationSpace::world();
        }
    } else {
        image.animationTransformSpace = TransformAnimationSpace{bindingBoneID};
    }

    return image;
}

JsonValue toJson(const Skin& skin) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(skin.id));
    j.set("name", JsonValue::makeString(skin.name));

    // Sorted array of {slot, imageID?} records -- see this file's header
    // for why this cannot be a JSON object keyed by slot.
    std::vector<std::string> slots = skin.describedSlots(); // already sorted.
    JsonValue::Array attachments;
    attachments.reserve(slots.size());
    for (const std::string& slot : slots) {
        JsonValue entry = JsonValue::makeObject();
        entry.set("slot", JsonValue::makeString(slot));
        const SlotAttachment& imageID = skin.attachments.at(slot);
        // Present-but-null is the point: the slot is described AND empty.
        entry.set("imageID", imageID.has_value() ? toJson(*imageID) : JsonValue::makeNull());
        attachments.push_back(entry);
    }
    j.set("attachments", JsonValue::makeArray(std::move(attachments)));

    JsonValue::Array included;
    included.reserve(skin.includedSkinIDs.size());
    for (const Uuid& id : skin.includedSkinIDs) included.push_back(toJson(id));
    j.set("includedSkinIDs", JsonValue::makeArray(std::move(included)));

    return j;
}

Skin skinFromJson(const JsonValue& j) {
    Skin skin;
    skin.id = uuidFromJson(*j.find("id"));
    skin.name = j.find("name")->asString();

    const JsonValue* attachments = j.find("attachments");
    if (attachments != nullptr) {
        for (const JsonValue& entry : attachments->asArray()) {
            const std::string slot = entry.find("slot")->asString();
            const JsonValue* imageID = entry.find("imageID");
            // A record that exists with a null id is a described-but-empty
            // slot, NOT an absent one -- the whole reason for the array.
            skin.attachments[slot] =
                (imageID != nullptr && !imageID->isNull()) ? SlotAttachment(uuidFromJson(*imageID)) : std::nullopt;
        }
    }

    const JsonValue* included = j.find("includedSkinIDs");
    if (included != nullptr) {
        for (const JsonValue& id : included->asArray()) skin.includedSkinIDs.push_back(uuidFromJson(id));
    }

    return skin;
}

} // namespace umeshcore
