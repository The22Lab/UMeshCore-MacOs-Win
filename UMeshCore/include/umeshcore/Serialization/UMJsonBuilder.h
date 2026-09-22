#pragma once

// Port of `Export/JSON/UMJSONExportBuilder.swift` -- turns a scene snapshot
// into a `UMJsonDocument`, plus the writer that renders one to JSON text.
// Pure and deterministic: every collection derived from a map is sorted by
// a stable key, so exporting an unchanged project twice produces identical
// output (the one exception is `exportDate`, which is a timestamp by
// definition -- same situation as the binary META chunk's).
//
// Takes an `EditorScene&` plus an asset lookup and a list of animation
// sources, mirroring Swift's `build(scene:assets:animations:)`. Animations
// arrive as `UMJsonAnimationSource` values rather than being read off the
// scene, exactly as in Swift: the editor builds them from
// `AnimationLibrary::animations()`, or, as a fallback, from the live scene
// clips for the currently active animation. `NamedAnimation` converts to
// one directly (see `animationSourceFrom`).
//
// Two options carry real behavior and are ported with it:
//
//   - `nonessentialData` (default true). When FALSE, values only the editor
//     needs are stripped: bone colors, the setup draw order, atlas region
//     names, the 3D `depth` block, and the project name. A runtime never
//     reads them, so a production export is meaningfully smaller.
//
//   - `animationCleanUp` (default false). Removes keys that provably cannot
//     change what is rendered, and ONLY those. The Swift implementation's
//     two rules, kept exactly:
//       1. A track whose keys all hold the same value, never use Bezier,
//          AND whose constant equals the SETUP value is redundant. When the
//          constant DIFFERS from setup the track is kept -- dropping it
//          would silently re-pose the rig (a bone held at 45 degrees would
//          export flat at 0), which is visible corruption, not cleanup.
//       2. Inside a run of three or more consecutive equal values, the
//          MIDDLE keys are redundant; the first and last are kept so the
//          hold's timing survives exactly.
//     Keys carrying Bezier tangents are never removed, because their
//     handles shape the curve into and out of neighbours even when the
//     values match.

#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationLibrary.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Serialization/AssetRecord.h"
#include "umeshcore/Serialization/Json.h"
#include "umeshcore/Serialization/UMJsonModel.h"

namespace umeshcore {

// A single animation to export, decoupled from where it is stored.
struct UMJsonAnimationSource {
    std::string name;
    std::unordered_map<Uuid, AnimationClip, UuidHash> boneClips;
    std::unordered_map<Uuid, AnimationClip, UuidHash> imageClips;
    AnimationClip sceneClip{"Scene"};
    int duration = 0;
};

UMJsonAnimationSource animationSourceFrom(const NamedAnimation& animation);

struct UMJsonExportOptions {
    // Decimal places retained for floats. UltraMesh floats are 32-bit, so 6
    // places is lossless at typical magnitudes while keeping the file clean
    // and diff-friendly. Negative disables rounding entirely.
    int floatPrecision = 6;
    // Embed PNG bytes (base64) into the file, making it self-contained.
    bool embedTextures = false;
    bool nonessentialData = true;
    bool animationCleanUp = false;
    bool prettyPrint = true;

    // Scene-level values UMJSON's metadata block needs that `EditorScene`
    // does not model (`SceneManager.projectFramesPerSecond` lives on the
    // manifest here -- see ProjectDocument.h). Defaulted to Swift's own.
    double framesPerSecond = 30.0;
    std::string projectName = "UltraMeshProject";
};

// The value a track blends away from, used only by `animationCleanUp`'s
// constant-track rule. See the header on why it is required there.
struct UMJsonSetupValue {
    bool isVector = false;
    float x = 0.0f;
    float y = 0.0f;

    static UMJsonSetupValue scalar(float v) { return UMJsonSetupValue{false, v, 0.0f}; }
    static UMJsonSetupValue vector(float x, float y) { return UMJsonSetupValue{true, x, y}; }
    bool matches(const UMJsonKeyframe& key, float epsilon = 1e-5f) const;
};

// Exposed for testing: the two cleanup rules in isolation.
std::vector<UMJsonKeyframe> cleanedTrack(
    const std::vector<UMJsonKeyframe>& keys, const std::optional<UMJsonSetupValue>& setup);

// DFS from the declared roots, children sorted by id, then any bone not
// reachable from a root (defensive, and also sorted) -- so bone order is
// stable across exports regardless of map iteration order.
std::vector<Bone> deterministicBoneOrder(const Skeleton& skeleton);

UMJsonDocument buildUMJsonDocument(
    const EditorScene& scene, const std::unordered_map<Uuid, AssetRecord, UuidHash>& assets,
    const std::vector<UMJsonAnimationSource>& animations, const UMJsonExportOptions& options = {});

JsonValue toJson(const UMJsonDocument& document);

// Renders a document to text, honoring `prettyPrint`.
std::string writeUMJson(const UMJsonDocument& document, const UMJsonExportOptions& options = {});

} // namespace umeshcore
