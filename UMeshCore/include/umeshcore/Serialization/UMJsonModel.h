#pragma once

// 1:1 port of `Export/JSON/UMJSONModel.swift` -- the UltraMesh JSON
// interchange format: the engine-agnostic contract between the editor and
// any runtime (Unity, Unreal, Godot, custom C++, WASM).
//
// A FULLY SEPARATE MODEL from the `Saved*` project format, deliberately so,
// and the differences are the point rather than inconsistency:
//   - IDs are strings, not `Uuid`, because the consumer is not Swift (or
//     C++) and should not need a UUID type to read a rig.
//   - Vectors are flat `[Float]` arrays, not `{x,y}` objects.
//   - Units are documented per field and differ by convention: a BONE's
//     rotation and shear are radians, a SPRITE's rotation is radians but
//     its shear is DEGREES. That asymmetry is the editor's internal
//     convention (see `Transform3D2D.h` vs `MatrixUtilities::shearedAxes`),
//     and the format preserves it rather than normalizing, so a runtime
//     reproduces the rig with zero conversion drift.
//   - Interpolation is spelled "stepped", not "hold".
//
// Design rules the Swift header states, which this port keeps: versioned
// (unknown keys ignored by conforming readers), sectioned and flat (records
// keyed by stable string IDs, never by array index, so references survive
// reordering), deterministic (sorted keys and sorted records, so exporting
// an unchanged project twice yields byte-identical JSON), and lossless.
//
// Optionals are omitted from the output when empty, matching Swift's
// synthesized `encodeIfPresent` -- a rig that never tints an attachment
// produces the same file as one from before tinting existed.
//
// Like the binary export format, UMJSON is WRITE-ONLY in the Swift app
// (confirmed by grep: no decoder or importer type exists anywhere in the
// tree), so this port provides a builder and a writer, not a reader.

#include <optional>
#include <string>
#include <vector>

namespace umeshcore {

struct UMJsonCompatibility {
    std::string minRuntimeVersion;
    // Named capabilities a reader may probe. An absent capability must be
    // treated as "not present", never as an error.
    std::vector<std::string> featureFlags;
};

struct UMJsonMetadata {
    std::string projectName;
    double framesPerSecond = 30.0;
    int playbackStartFrame = 0;
    int playbackEndFrame = 0;
    // Length unit the coordinates are expressed in. UltraMesh authors in pixels.
    std::string units;
    // Authored (setup) draw order: attachment IDs, back-to-front.
    std::vector<std::string> drawOrder;
    // Free-form user data, preserved verbatim across round-trips.
    std::vector<std::pair<std::string, std::string>> custom;
};

struct UMJsonAtlasRegion {
    std::string id;
    std::string name;
    float width = 0.0f;
    float height = 0.0f;
    // When true, `dataBase64` carries the PNG bytes; otherwise load `path`
    // relative to the exported file.
    bool embedded = false;
    std::optional<std::string> path;
    std::optional<std::string> dataBase64;
};

struct UMJsonAtlas {
    std::vector<UMJsonAtlasRegion> regions;
};

struct UMJsonTransformDepth {
    float positionZ = 0.0f;
    float rotationX = 0.0f; // radians
    float rotationY = 0.0f; // radians
    float scaleZ = 1.0f;
};

// A bone's decomposed 2D transform. `rotation` and `shear` are RADIANS
// (bone convention). The optional `depth` block preserves the rarely-used
// 3D components losslessly.
struct UMJsonTransform {
    std::vector<float> position; // [x, y]
    float rotation = 0.0f;       // radians
    std::vector<float> scale;    // [x, y]
    std::vector<float> shear;    // [x, y] radians
    std::optional<UMJsonTransformDepth> depth;
};

struct UMJsonBone {
    std::string id;
    std::string name;
    std::optional<std::string> parent;
    UMJsonTransform transform; // setup (base) pose
    float length = 0.0f;
    // Editor-only gizmo tint. Omitted entirely (not emitted as an empty
    // array) when nonessential data is excluded, so a runtime never sees a
    // malformed color it might index into.
    std::optional<std::vector<float>> color; // [r, g, b, a]
    bool root = false;
};

struct UMJsonSlot {
    std::string name;
    // Attachment IDs that can occupy this slot (skin variants).
    std::vector<std::string> attachments;
};

// Sprite pose. `rotation` is RADIANS, `shear` is DEGREES -- the sprite
// convention, distinct from a bone's. See this file's header.
struct UMJsonAttachmentPose {
    std::vector<float> position;
    float rotation = 0.0f;    // radians
    std::vector<float> scale;
    std::vector<float> shear; // degrees
};

struct UMJsonBoneBinding {
    std::string bone;
    UMJsonAttachmentPose localPose;
};

// A sprite/attachment. Every UltraMesh attachment is a mesh (a quad is a
// mesh with four vertices), so `mesh` references the `meshes` array.
struct UMJsonAttachment {
    std::string id;
    std::string name;
    std::string slot;
    std::string region; // atlas region id (== assetID)
    std::optional<std::string> mesh;
    bool hidden = false;
    // Omitted when neutral, so a rig that never tints produces the same
    // file as before tinting existed.
    std::optional<std::vector<float>> color;
    // "normal" | "additive" | "multiply" | "screen". Omitted when normal.
    std::optional<std::string> blend;
    std::string animationSpace; // "world" | "boneLocal"
    std::optional<std::string> animationSpaceBone;
    // Setup pose used when the attachment is NOT bound to a bone.
    UMJsonAttachmentPose setupPose;
    std::optional<UMJsonBoneBinding> boneBinding;
};

struct UMJsonMeshWeight {
    std::string bone;
    float weight = 0.0f;
};

struct UMJsonInverseBind {
    std::string bone;
    std::vector<float> matrix; // column-major 4x4, 16 floats
};

struct UMJsonMesh {
    std::string id;
    std::string name;
    std::vector<float> vertices;    // flat [x0,y0, x1,y1, ...]
    std::vector<float> uvs;         // flat [u0,v0, ...] (v grows downward)
    std::vector<int> triangles;
    std::vector<int> hull;
    std::vector<int> edges;           // flat [a0,b0, a1,b1, ...]
    std::vector<int> manualTriangles; // flat [a0,b0,c0, ...]
    // Skinning (present only when the mesh is weighted).
    std::optional<std::vector<float>> bindVertices;
    std::optional<std::vector<std::vector<UMJsonMeshWeight>>> weights;
    std::optional<std::vector<UMJsonInverseBind>> inverseBindMatrices;
    std::optional<UMJsonAttachmentPose> bindPose;
};

struct UMJsonSkinSlot {
    std::string slot;
    // nullopt == the skin deliberately empties this slot.
    std::optional<std::string> attachment;
};

struct UMJsonSkin {
    std::string id;
    std::string name;
    // Explicit per-slot choices. A slot ABSENT from this array means the
    // skin has no opinion and defers to `includes`, then the setup pose.
    std::vector<UMJsonSkinSlot> slots;
    std::vector<std::string> includes; // included skin ids, nearest-first
};

struct UMJsonIKConstraint {
    std::string id;
    std::string name;
    bool enabled = true;
    int order = 0;
    float mix = 1.0f;
    std::vector<std::string> bones; // chain, root -> effector
    std::string target;
    bool bendPositive = true;
    bool stretch = false;
    bool compress = false;
    bool uniformScale = false;
    float softness = 0.0f;
};

struct UMJsonTransformConstraint {
    std::string id;
    std::string name;
    bool enabled = true;
    int order = 0;
    float mix = 1.0f;
    std::string target;
    std::vector<std::string> bones;
    bool copyPosition = false;
    bool copyRotation = true;
    bool copyScale = false;
    bool copyShear = false;
    float positionMix = 1.0f;
    float rotationMix = 1.0f;
    float scaleMix = 1.0f;
    float shearMix = 1.0f;
    std::vector<float> offsetPosition; // [x, y]
    float offsetRotation = 0.0f;       // radians
    std::vector<float> offsetScale;    // [x, y]
    float offsetShear = 0.0f;          // radians
};

struct UMJsonPathConstraint {
    std::string id;
    std::string name;
    bool enabled = true;
    int order = 0;
    float mix = 1.0f;
    std::vector<std::string> pathBones;
    std::vector<std::string> bones;
    float position = 0.0f;
    float spacing = 0.0f;
    std::string spacingMode; // "length" | "percent" | "proportional" | "fixed"
    float positionMix = 1.0f;
    float rotateMix = 1.0f;
    float offsetRotation = 0.0f; // radians
    bool closed = false;
    bool reversed = false;
    std::string rotateMode; // "tangent" | "chain" | "chainScale"
};

struct UMJsonConstraints {
    std::vector<UMJsonIKConstraint> ik;
    std::vector<UMJsonTransformConstraint> transform;
    std::vector<UMJsonPathConstraint> path;
};

struct UMJsonPhysicsSettings {
    float mass = 1.0f;
    float damping = 0.0f;
    float stiffness = 0.0f;
    float gravity = 0.0f;
    float drag = 0.0f;
    std::vector<float> wind;      // [x, y]
    float stretchLimit = 1.0f;
    float angleLimitMin = 0.0f;   // radians
    float angleLimitMax = 0.0f;   // radians
};

struct UMJsonPhysics {
    std::string id;
    std::string name;
    bool enabled = true;
    int order = 0;
    float mix = 1.0f;
    std::string type; // spring | jiggle | rope | pendulum | cloth
    std::vector<std::string> bones;
    UMJsonPhysicsSettings settings;
};

struct UMJsonEvent {
    std::string id;
    std::string name;
    int intValue = 0;
    float floatValue = 0.0f;
    std::string stringValue;
    std::string audioPath;
    float volume = 1.0f;
    float balance = 0.0f;
};

// One keyframe. `scalar`/`vector`/`flag` are mutually exclusive: which one
// is present depends on the track. Bezier tangents are (frameDelta,
// valueDelta) offsets; secondary tangents drive the Y channel of vector
// tracks.
struct UMJsonKeyframe {
    int frame = 0;
    std::string interp; // "linear" | "stepped" | "bezier"
    std::optional<float> scalar;
    std::optional<std::vector<float>> vector; // [x, y]
    std::optional<bool> flag;
    std::optional<std::vector<float>> inTangent;
    std::optional<std::vector<float>> outTangent;
    std::optional<std::vector<float>> secondaryInTangent;
    std::optional<std::vector<float>> secondaryOutTangent;
};

struct UMJsonBoneTimelines {
    std::string bone;
    std::optional<std::vector<UMJsonKeyframe>> translate;
    std::optional<std::vector<UMJsonKeyframe>> rotate;
    std::optional<std::vector<UMJsonKeyframe>> scale;
    std::optional<std::vector<UMJsonKeyframe>> shear;
};

// One mesh-deformation keyframe: the mesh's local vertex positions at a
// frame. Positions are ABSOLUTE in the attachment's local space -- the same
// space as `UMJsonMesh::vertices` -- not offsets from the rest shape.
// Storing them outright costs more bytes than deltas but removes any
// question about which rest pose a delta is relative to when skins swap the
// mesh underneath.
struct UMJsonDeformKey {
    int frame = 0;
    // "linear" or "stepped" only. Deformation ignores Bezier tangents,
    // matching the editor, which interpolates vertex arrays linearly.
    std::string interp;
    std::vector<float> vertices; // flat [x0,y0, ...], one pair per vertex
};

struct UMJsonAttachmentTimelines {
    std::string attachment;
    std::optional<std::vector<UMJsonKeyframe>> translate;
    std::optional<std::vector<UMJsonKeyframe>> rotate;
    std::optional<std::vector<UMJsonKeyframe>> scale;
    std::optional<std::vector<UMJsonKeyframe>> shear;
    // Absent unless the animation actually deforms this attachment's mesh.
    std::optional<std::vector<UMJsonDeformKey>> deform;
};

struct UMJsonConstraintTrack {
    std::string property;
    std::vector<UMJsonKeyframe> keys;
};

struct UMJsonConstraintTimelines {
    std::string constraint;
    std::vector<UMJsonConstraintTrack> properties;
};

struct UMJsonDrawOrderKey {
    int frame = 0;
    // Attachment IDs in draw order at this frame (stepped).
    std::vector<std::string> order;
};

struct UMJsonEventKey {
    int frame = 0;
    // Overrides; when absent, the definition's default applies.
    std::optional<int> intValue;
    std::optional<float> floatValue;
    std::optional<std::string> stringValue;
};

struct UMJsonEventTimeline {
    std::string event; // event definition id
    std::vector<UMJsonEventKey> keys;
};

struct UMJsonAnimation {
    std::string name;
    int durationFrames = 0;
    std::vector<UMJsonBoneTimelines> bones;
    std::vector<UMJsonAttachmentTimelines> attachments;
    std::vector<UMJsonConstraintTimelines> constraints;
    std::vector<UMJsonDrawOrderKey> drawOrder;
    std::vector<UMJsonEventTimeline> events;
};

struct UMJsonDocument {
    std::string format;        // always "UltraMesh"
    std::string version;       // format semver
    std::string engineVersion; // editor build that produced the file
    std::string generator;     // exporter name + version
    std::string exportDate;    // ISO-8601, UTC
    UMJsonCompatibility compatibility;
    UMJsonMetadata metadata;

    UMJsonAtlas atlas;
    std::vector<UMJsonBone> bones;
    std::vector<UMJsonSlot> slots;
    std::vector<UMJsonAttachment> attachments;
    std::vector<UMJsonMesh> meshes;
    std::vector<UMJsonSkin> skins;
    UMJsonConstraints constraints;
    std::vector<UMJsonPhysics> physics;
    std::vector<UMJsonEvent> events;
    std::vector<UMJsonAnimation> animations;
};

} // namespace umeshcore
