#include "umeshcore/Interop/SwiftBridge.h"

#include <type_traits>
#include <variant>

namespace umeshcore {

// ---- KeyframeValue --------------------------------------------------------

FlatKeyframeValue toFlat(const KeyframeValue& value) {
    FlatKeyframeValue flat;
    std::visit(
        [&flat](const auto& v) {
            using T = std::decay_t<decltype(v)>;
            if constexpr (std::is_same_v<T, TranslateValue>) {
                flat.kind = KeyframeValueCase::Translate;
                flat.vec2 = v.value;
            } else if constexpr (std::is_same_v<T, RotateValue>) {
                flat.kind = KeyframeValueCase::Rotate;
                flat.scalar = v.value;
            } else if constexpr (std::is_same_v<T, ScaleValue>) {
                flat.kind = KeyframeValueCase::Scale;
                flat.vec2 = v.value;
            } else if constexpr (std::is_same_v<T, ShearValue>) {
                flat.kind = KeyframeValueCase::Shear;
                flat.vec2 = v.value;
            } else if constexpr (std::is_same_v<T, MeshDeformValue>) {
                flat.kind = KeyframeValueCase::MeshDeform;
                flat.meshDeform = v.value;
            } else if constexpr (std::is_same_v<T, ScalarValue>) {
                flat.kind = KeyframeValueCase::Scalar;
                flat.scalar = v.value;
            } else if constexpr (std::is_same_v<T, FlagValue>) {
                flat.kind = KeyframeValueCase::Flag;
                flat.flag = v.value;
            } else if constexpr (std::is_same_v<T, Vector2Value>) {
                flat.kind = KeyframeValueCase::Vector2;
                flat.vec2 = v.value;
            } else if constexpr (std::is_same_v<T, DrawOrderValue>) {
                flat.kind = KeyframeValueCase::DrawOrder;
                flat.drawOrder = v.value;
            } else if constexpr (std::is_same_v<T, EventValue>) {
                flat.kind = KeyframeValueCase::Event;
                flat.event = v.value;
            } else if constexpr (std::is_same_v<T, AttachmentValue>) {
                flat.kind = KeyframeValueCase::Attachment;
                flat.hasAttachment = v.value.has_value();
                if (v.value.has_value()) flat.attachment = *v.value;
            } else {
                static_assert(!sizeof(T), "KeyframeValue gained a case SwiftBridge does not flatten");
            }
        },
        value);
    return flat;
}

KeyframeValue fromFlat(const FlatKeyframeValue& flat) {
    switch (flat.kind) {
        case KeyframeValueCase::Translate: return TranslateValue{flat.vec2};
        case KeyframeValueCase::Rotate: return RotateValue{flat.scalar};
        case KeyframeValueCase::Scale: return ScaleValue{flat.vec2};
        case KeyframeValueCase::Shear: return ShearValue{flat.vec2};
        case KeyframeValueCase::MeshDeform: return MeshDeformValue{flat.meshDeform};
        case KeyframeValueCase::Scalar: return ScalarValue{flat.scalar};
        case KeyframeValueCase::Flag: return FlagValue{flat.flag};
        case KeyframeValueCase::Vector2: return Vector2Value{flat.vec2};
        case KeyframeValueCase::DrawOrder: return DrawOrderValue{flat.drawOrder};
        case KeyframeValueCase::Event: return EventValue{flat.event};
        case KeyframeValueCase::Attachment:
            return AttachmentValue{
                flat.hasAttachment ? std::optional<Uuid>(flat.attachment) : std::nullopt};
    }
    return ScalarValue{0.0f};
}

FlatKeyframeValue flatKeyframeValue(const Keyframe& keyframe) { return toFlat(keyframe.value); }

void setFlatKeyframeValue(Keyframe& keyframe, const FlatKeyframeValue& value) {
    keyframe.value = fromFlat(value);
    const TrackValueKind k = kind(keyframe.value);
    if (k == TrackValueKind::Flag || k == TrackValueKind::DrawOrder ||
        k == TrackValueKind::Event || k == TrackValueKind::Attachment) {
        keyframe.interpolation = KeyframeInterpolation::Hold;
    }
}

Keyframe makeKeyframe(
    const Uuid& id, int frame, const FlatKeyframeValue& value,
    KeyframeInterpolation interpolation) {
    // The constructor applies the stepped-kinds-hold rule.
    Keyframe keyframe(frame, fromFlat(value), interpolation);
    keyframe.id = id;
    return keyframe;
}

// ---- SceneLayerContent ----------------------------------------------------

FlatSceneLayerContent toFlat(const SceneLayerContent& content) {
    FlatSceneLayerContent flat;
    if (const auto* rig = std::get_if<SceneRigContent>(&content)) {
        flat.kind = SceneLayerContentCase::Rig;
        flat.rig = *rig;
    } else if (const auto* plate = std::get_if<ScenePlateContent>(&content)) {
        flat.kind = SceneLayerContentCase::Plate;
        flat.plateAssetId = plate->assetId;
    } else if (const auto* fill = std::get_if<SceneFillContent>(&content)) {
        flat.kind = SceneLayerContentCase::Fill;
        flat.fill = fill->fill;
    }
    return flat;
}

SceneLayerContent fromFlat(const FlatSceneLayerContent& flat) {
    switch (flat.kind) {
        case SceneLayerContentCase::Rig: return flat.rig;
        case SceneLayerContentCase::Plate: return ScenePlateContent{flat.plateAssetId};
        case SceneLayerContentCase::Fill: return SceneFillContent{flat.fill};
    }
    return SceneFillContent{flat.fill};
}

FlatSceneLayerContent flatLayerContent(const SceneLayer& layer) { return toFlat(layer.content); }

void setFlatLayerContent(SceneLayer& layer, const FlatSceneLayerContent& content) {
    layer.content = fromFlat(content);
}

// ---- GizmoHandle ----------------------------------------------------------

FlatGizmoHandle toFlat(const GizmoHandle& handle) {
    FlatGizmoHandle flat;
    std::visit(
        [&flat](const auto& h) {
            using T = std::decay_t<decltype(h)>;
            if constexpr (std::is_same_v<T, MoveCenterHandle>) {
                flat.kind = GizmoHandleCase::MoveCenter;
            } else if constexpr (std::is_same_v<T, MoveXHandle>) {
                flat.kind = GizmoHandleCase::MoveX;
            } else if constexpr (std::is_same_v<T, MoveYHandle>) {
                flat.kind = GizmoHandleCase::MoveY;
            } else if constexpr (std::is_same_v<T, BoneHandle>) {
                flat.kind = GizmoHandleCase::Bone;
                flat.boneID = h.id;
            } else if constexpr (std::is_same_v<T, MeshVertexHandle>) {
                flat.kind = GizmoHandleCase::MeshVertex;
                flat.index = h.index;
            } else if constexpr (std::is_same_v<T, MeshInternalEdgeHandle>) {
                flat.kind = GizmoHandleCase::MeshInternalEdge;
                flat.index = h.index;
            } else if constexpr (std::is_same_v<T, RotateRingHandle>) {
                flat.kind = GizmoHandleCase::RotateRing;
            } else if constexpr (std::is_same_v<T, ScaleCornerHandle>) {
                flat.kind = GizmoHandleCase::ScaleCorner;
                flat.index = h.index;
            } else if constexpr (std::is_same_v<T, SkewEdgeHandle>) {
                flat.kind = GizmoHandleCase::SkewEdge;
                flat.index = h.index;
            } else {
                static_assert(!sizeof(T), "GizmoHandle gained a case SwiftBridge does not flatten");
            }
        },
        handle);
    return flat;
}

GizmoHandle fromFlat(const FlatGizmoHandle& flat) {
    switch (flat.kind) {
        case GizmoHandleCase::MoveCenter: return MoveCenterHandle{};
        case GizmoHandleCase::MoveX: return MoveXHandle{};
        case GizmoHandleCase::MoveY: return MoveYHandle{};
        case GizmoHandleCase::Bone: return BoneHandle{flat.boneID};
        case GizmoHandleCase::MeshVertex: return MeshVertexHandle{flat.index};
        case GizmoHandleCase::MeshInternalEdge: return MeshInternalEdgeHandle{flat.index};
        case GizmoHandleCase::RotateRing: return RotateRingHandle{};
        case GizmoHandleCase::ScaleCorner: return ScaleCornerHandle{flat.index};
        case GizmoHandleCase::SkewEdge: return SkewEdgeHandle{flat.index};
    }
    return MoveCenterHandle{};
}

} // namespace umeshcore
