#pragma once

// Port of the portable subset of `Core/ToolUtilities.swift`.
//
// DEVIATION FROM THE SWIFT SOURCE, DELIBERATE AND DOCUMENTED: functions
// that read `scene: SceneManager` / `assets: AssetManager` in Swift take
// the specific already-resolved values they need here instead (a
// `const SceneImage&`, an asset size, a `const Skeleton&`, an explicit
// `hitScale`, ...). SceneManager (a ~7,400-line god object mixing model
// data with UI/editor state) and AssetManager (texture loading) are not
// ported -- see UMeshCore/ROADMAP.md's SceneManager risk note. This
// mirrors the same "inject what's needed" pattern the Swift source
// itself already uses for CanvasPicking's projection closure, applied
// one layer further out. The HIT-TEST LOGIC below is an unmodified 1:1
// transcription; only the parameter-passing boundary changed.
//
// NOT YET PORTED (needs the not-yet-built texture/asset pipeline --
// alpha-channel sampling against loaded PNGs): `CanvasPicking.imageHit`
// and everything built on it (`hitTestScreen`, `hitTestRect`,
// `hitTestSelectionTarget`, `boundsForScene`/`boundsForImage`, which also
// needs `TextureAsset`). Tracked as Phase 4 follow-up work.
//
// `touchHitScale` is NOT computed here (it reads `UITraitCollection`/
// `displayScale`, an AppKit/UIKit concept): callers pass `hitScale`
// explicitly (1.0 for a pixel-precise pointer, `displayScale * 1.85` for
// touch -- the platform adapter computes this exactly as
// `Core/ToolUtilities.swift` does and passes it in).

#include <array>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Editor/GizmoHandle.h"
#include "umeshcore/Editor/ToolType.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Mesh/Mesh.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore::ToolUtilities {

// --- Snapping ---

float snap(float value, float grid);
float snapAngle(float radians, float stepDegrees);
float snapScale(float value, float step);
Vec2 snapScale(const Vec2& value, float step);
Vec2 snap(const Vec2& point, float grid);
Vec2 constrainAxis(const Vec2& delta);

// --- Point/segment/quad geometry ---

float distancePointToSegment(const Vec2& point, const Vec2& a, const Vec2& b);
bool pointNearSegment(const Vec2& point, const Vec2& start, const Vec2& end, float radius);
bool pointInTriangle(const Vec2& point, const Vec2& a, const Vec2& b, const Vec2& c);
bool pointInQuad(const Vec2& point, const std::array<Vec2, 4>& quad);
float distanceToQuad(const Vec2& point, const std::array<Vec2, 4>& quad);
std::array<Vec2, 4> edgeMidpoints(const std::array<Vec2, 4>& corners);

// --- Sprite local-space framing ---

struct LocalFrame {
    Vec2 center;
    Vec2 size;
};

LocalFrame localFrame(const std::vector<Vec2>& meshVertices, const Vec2& assetSize);

std::array<Vec2, 4> transformedCorners(
    const SceneImage& image, const LocalFrame& frame, std::optional<Vec2> shearOverride = std::nullopt);

std::vector<Vec2> transformedVertices(
    const SceneImage& image, const std::vector<Vec2>& localVertices,
    std::optional<Vec2> shearOverride = std::nullopt);

Vec2 localCoordinates(const Vec2& worldPoint, const SceneImage& image);

// --- Mesh resolution (mirrors ToolUtilities.swift's mesh helpers exactly) ---

Mesh resolvedMesh(const SceneImage& image, const Vec2& assetSize);
std::optional<Mesh> overlayMesh(const SceneImage& image, const Vec2& assetSize);
std::vector<Vec2> editLocalVertices(const SceneImage& image, const Vec2& assetSize, bool showDeformed);
std::vector<Vec2> editLocalVertices(
    const SceneImage& image, const Vec2& assetSize, bool showDeformed, const Mesh& mesh);

// Mirrors SceneManager.skinnedLocalVertices: the mesh vertex positions the
// editing overlay should draw, skinned if `showDeformed` and the mesh has
// skinning data.
std::vector<Vec2> skinnedLocalVertices(
    const SceneImage& image, const Vec2& assetSize, bool showDeformed, const Skeleton& skeleton,
    const Mesh& mesh, const WorldMatrices* cachedMatrices = nullptr);

std::unordered_map<int, float> softSelectionWeights(
    const SceneImage& image, const Vec2& assetSize, const std::unordered_set<int>& selectedIndices,
    bool showDeformed, float radius, float feather, bool excludeHull);

// --- Mesh hit-testing (against a pre-built projection) ---

struct MeshProjection {
    Uuid imageID;
    Mesh mesh;
    std::vector<Vec2> screenVertices; // one per mesh vertex, in vertex order.
    float grabRadius;
};

// Mirrors ToolUtilities.meshProjection: the selected sprite's mesh, skinned
// and projected to the screen, ONCE (build this once per input event and
// reuse it across every hit test in that event).
std::optional<MeshProjection> meshProjection(
    const SceneImage& image, const Vec2& assetSize, const Skeleton& skeleton, bool showDeformed,
    bool weightPainting, CameraState* camera, const Vec2& viewSize, float hitScale,
    const WorldMatrices* cachedMatrices = nullptr);

std::optional<int> hitTestMeshVertex(const Vec2& screenPoint, const MeshProjection& projection);
std::optional<int> hitTestMeshHullEdge(
    const Vec2& screenPoint, const MeshProjection& projection, float hitScale);
std::optional<int> hitTestMeshInternalEdge(
    const Vec2& screenPoint, const MeshProjection& projection, float hitScale);

struct ScreenRect {
    Vec2 min;
    Vec2 max;
    bool contains(const Vec2& p) const { return p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y; }
};

std::unordered_set<int> hitTestMeshVertices(const ScreenRect& rect, const MeshProjection& projection);

// --- Bone hit-testing ---

// Mirrors ToolUtilities.hitTestBoneDetailed. `touchOptimized` selects
// between the two Swift `#if os(iOS)` branches at runtime (the platform
// adapter picks which one to pass; both are compiled into every build).
std::optional<std::pair<Uuid, float>> hitTestBoneDetailed(
    const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton,
    std::optional<Uuid> selectedBoneID, CameraState* camera, bool touchOptimized, float displayScale = 2.0f);

inline std::optional<Uuid> hitTestBone(
    const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton,
    std::optional<Uuid> selectedBoneID, CameraState* camera, bool touchOptimized, float displayScale = 2.0f) {
    auto result = hitTestBoneDetailed(
        screenPoint, viewSize, skeleton, selectedBoneID, camera, touchOptimized, displayScale);
    if (!result.has_value()) return std::nullopt;
    return result->first;
}

// Liang-Barsky: whether a screen-space segment touches a rectangle (either
// endpoint inside, OR the segment crosses it without either endpoint being
// inside -- catches a diagonal bone whose bounding box overlaps the box
// but whose shaft doesn't, and a long shaft that crosses the box with both
// joints outside it).
bool segmentIntersectsRect(const Vec2& a, const Vec2& b, const ScreenRect& rect);

// The bones a marquee catches, in SKELETON order (not a Set): the order is
// what the caller turns into selection order, so dragging the same box
// twice gives the same active bone.
std::vector<Uuid> bonesIntersecting(
    const ScreenRect& rect, const Vec2& viewSize, const Skeleton& skeleton, CameraState* camera);

// --- Selection-changing click policy (pure predicates) ---

bool meshModeMayChangeSelection(Uuid hitID, std::optional<Uuid> selectedID, int clickCount);
bool weightPaintMayChangeBone(
    Uuid hitID, std::optional<Uuid> armedBoneID, const std::unordered_set<Uuid, UuidHash>& boundBoneIDs,
    int clickCount);

// --- Gizmo hit-testing ---

GizmoHandle defaultHandle(ActiveTool tool);

Vec2 project3DToScreen(
    const Vec2& point, const Vec2& center, float rotationZ, const Vec3& rotation3D, const Vec2& viewSize,
    CameraState* camera);

// See the file header: `selectedImage`/`selectedImageAssetSize` and
// `selectedBoneSegment` are what the Swift source resolves internally via
// `scene.selectedImageID.flatMap{scene.image(for:)}` and
// `scene.selectedBoneID.flatMap{scene.skeleton.lineSegment(for:)}` --
// resolve them the same way at the call site and pass the results in.
// `selectedImageAssetSize`/`skeleton`/`showMeshDeformed`/`weightPainting`
// are only consulted for the `.mesh` case.
std::optional<GizmoHandle> hitTestGizmo(
    ActiveTool tool, const Vec2& screenPoint, const Vec2& viewSize, const SceneImage* selectedImage,
    const Vec2& selectedImageAssetSize, std::optional<Skeleton::LineSegment> selectedBoneSegment,
    std::optional<Uuid> selectedBoneID, const Skeleton* skeleton, bool showMeshDeformed, bool weightPainting,
    CameraState* camera, float hitScale, bool touchOptimized, float displayScale = 2.0f);

} // namespace umeshcore::ToolUtilities
