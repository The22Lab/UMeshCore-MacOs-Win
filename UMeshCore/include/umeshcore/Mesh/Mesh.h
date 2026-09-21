#pragma once

// 1:1 port of `Data/Mesh.swift` -- the core struct, sanitization, and the
// skinning/auto-weighting pipeline. NOT YET PORTED from the Swift source
// (tracked in UMeshCore/ROADMAP.md as follow-up Phase 1 work, since they
// are editor-time conveniences rather than continuously-running runtime
// behavior): `generated()`/`generatedGrid` (procedural interior-point mesh
// generation for a freshly-created sprite mesh), the manual-triangle-face
// workflow (`sanitizedManualTriangles`, `triangulatedIndicesWithInternalEdges`
// combining manual faces with the kernel result), and the Auto-Bind
// bone-fit scoring heuristic (which bones a sprite suggests binding to).
//
// `SavedMatrix4x4` (the Swift source's Codable-friendly row-major
// flattening of `simd_float4x4`) is intentionally not mirrored here --
// `boneInverseBindMatrices` stores `Mat4` directly; the row-major
// conversion is a serialization-format concern, deferred to Phase 3.

#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Mesh/MeshTypes.h"
#include "umeshcore/Mesh/MeshValidator.h"

namespace umeshcore {

class Skeleton;
struct Bone;

struct VertexBoneWeight {
    Uuid boneID;
    float weight = 0.0f;
    bool operator==(const VertexBoneWeight&) const = default;
};

// Snapshot of a sprite's world pose (rotation in radians, shear in degrees
// -- the app-wide sprite transform convention). Skinning stores one of
// these at bind time so linear blend skinning can operate in a consistent
// world space:
//
//     world = sum_i w_i * BoneNow_i * inverse(BoneBind_i) * bindPose(localVertex)
//
// The renderer applies the sprite's CURRENT pose after skinning, so
// `skinnedVertices` maps the world result back through the inverse of the
// current pose (see the long comment in skinnedVertices's .cpp
// implementation for why it goes through the BIND pose, not the current
// one, when composing back to local space).
struct MeshBindPose {
    Vec2 position;
    float rotation = 0.0f; // radians, matching SceneImage.rotation
    Vec2 scale = Vec2::one();
    Vec2 skew = Vec2::zero(); // degrees, matching SceneImage.skew

    Vec2 worldPoint(const Vec2& local) const {
        return MatrixUtilities::shearedWorldTransform(
            local, position, rotation * 180.0f / kPi, skew, scale);
    }
    Vec2 localPoint(const Vec2& world) const {
        return MatrixUtilities::shearedWorldInverse(world, position, rotation * 180.0f / kPi, skew, scale);
    }

    bool operator==(const MeshBindPose&) const = default;
};

class Mesh {
public:
    Uuid id = Uuid::generate();
    std::string name;
    std::vector<Vec2> vertices;
    std::vector<Vec2> uvs;
    std::vector<std::uint16_t> indices;
    std::vector<std::uint16_t> hullVertexIndices;
    std::vector<MeshEdge> internalEdges;
    std::vector<MeshTriangle> manualTriangles;
    std::vector<std::vector<VertexBoneWeight>> vertexBoneWeights;
    std::vector<Vec2> bindVertices;
    std::unordered_map<Uuid, Mat4, UuidHash> boneInverseBindMatrices;
    // nullopt for legacy projects -- the current pose is used as a stable
    // fallback so old files keep rendering sanely.
    std::optional<MeshBindPose> bindImagePose;

    Mesh() = default;
    explicit Mesh(std::string name_) : name(std::move(name_)) {}

    static Vec2 localPosition(const Vec2& uv, const Vec2& size) {
        return Vec2(uv.x * size.x - (size.x * 0.5f), (size.y * 0.5f) - uv.y * size.y);
    }

    static Vec2 uvFor(const Vec2& localPosition, const Vec2& size) {
        if (!(size.x > 0.0001f) || !(size.y > 0.0001f)) return Vec2::zero();
        return Vec2(
            std::max(0.0f, std::min(1.0f, (localPosition.x + size.x * 0.5f) / size.x)),
            std::max(0.0f, std::min(1.0f, ((size.y * 0.5f) - localPosition.y) / size.y)));
    }

    bool isQuadCompatible() const {
        static const std::vector<std::uint16_t> quadIndices = {0, 1, 2, 2, 1, 3};
        return vertices.size() == 4 && uvs.size() == 4 && indices == quadIndices;
    }

    Mesh duplicated(std::optional<std::string> newName = std::nullopt) const {
        Mesh next = *this;
        next.id = Uuid::generate();
        if (newName.has_value()) next.name = *newName;
        return next;
    }

    static Mesh makeQuad(const std::string& name, const Vec2& size) {
        const float halfWidth = size.x * 0.5f;
        const float halfHeight = size.y * 0.5f;
        Mesh m(name);
        m.vertices = {
            Vec2(-halfWidth, halfHeight), Vec2(halfWidth, halfHeight), Vec2(-halfWidth, -halfHeight),
            Vec2(halfWidth, -halfHeight)};
        m.uvs = {Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)};
        m.indices = {0, 1, 2, 2, 1, 3};
        m.hullVertexIndices = {0, 1, 3, 2};
        return m;
    }

    Mesh resetToQuad(const Vec2& size) const { return makeQuad(name, size); }

    Mesh sanitizedForRender(const Vec2& size) const;
    std::pair<Mesh, bool> repairedIfInvalid() const;

    bool hasSkinningData() const { return !vertexBoneWeights.empty() && !boneInverseBindMatrices.empty(); }

    Mesh sanitizedSkinningData(int maxInfluences = 4) const;

    // `cachedMatrices`: pass the skeleton's already-solved world matrices to
    // avoid resolving the whole skeleton again (this is called once per
    // sprite per frame from the renderer).
    std::vector<Vec2> skinnedVertices(
        const Skeleton& skeleton, std::optional<MeshBindPose> currentPose = std::nullopt,
        const std::unordered_map<Uuid, Mat4, UuidHash>* cachedMatrices = nullptr,
        bool presanitized = false) const;

    bool pointInsideHullForKernel(const Vec2& point) const;

    std::vector<int> interiorVertexIndices() const {
        std::unordered_set<int> hullSet(hullVertexIndices.begin(), hullVertexIndices.end());
        std::vector<int> out;
        for (std::size_t i = 0; i < vertices.size(); ++i) {
            if (!hullSet.contains(static_cast<int>(i))) out.push_back(static_cast<int>(i));
        }
        return out;
    }

    // Throws MeshKernel::TriangulationError.
    std::vector<std::uint16_t> kernelTriangulatedIndices() const;
    // Throws MeshKernel::TriangulationError.
    Mesh retriangulated() const;

    MeshValidator::Report validationReport() const;

    std::vector<std::uint16_t> triangulatedHullIndices() const {
        std::vector<int> polygon(hullVertexIndices.begin(), hullVertexIndices.end());
        return triangulatePolygonIndices(polygon);
    }

    // Redistribute weights among bones this image is ALREADY bound to (the
    // Auto-Weight button): binds nothing new, keeps the existing
    // inverse-bind matrices / bind pose / bind vertices.
    Mesh autoWeights(
        const Skeleton& skeleton, const std::unordered_set<Uuid, UuidHash>& boneIDs, int maxInfluences = 4,
        float distancePower = 4.0f, float blendZoneFactor = 0.35f, float minWeightThreshold = 0.0001f,
        std::optional<MeshBindPose> imagePose = std::nullopt) const;

    // Bind this mesh to every bone in the skeleton at the current pose
    // (captures bind vertices, bind pose, and an inverse-bind matrix per bone).
    Mesh autoBindWeights(
        const Skeleton& skeleton, int maxInfluences = 4, float distancePower = 4.0f,
        float blendZoneFactor = 0.35f, float minWeightThreshold = 0.0001f,
        std::optional<MeshBindPose> imagePose = std::nullopt) const;

    static float pointDistanceToSegment(const Vec2& p, const Vec2& a, const Vec2& b) {
        const Vec2 ab = b - a;
        const float abLen2 = lengthSquared(ab);
        if (!(abLen2 > 0.000001f)) return length(p - a);
        const float t = std::max(0.0f, std::min(1.0f, dot(p - a, ab) / abLen2));
        const Vec2 projection = a + ab * t;
        return length(p - projection);
    }

private:
    struct BoneSegment {
        Uuid id;
        Vec2 start;
        Vec2 end;
    };
    static BoneSegment makeBoneSegment(const Bone& bone, const Mat4& world);

    std::vector<Vec2> bindPointsInWorldSpace(std::optional<MeshBindPose> fallbackPose) const;

    static std::vector<std::vector<VertexBoneWeight>> distributedWeights(
        const std::vector<Vec2>& points, const std::vector<BoneSegment>& segments, int maxInfluences,
        float distancePower, float blendZoneFactor, float minWeightThreshold);

    std::vector<std::uint16_t> sanitizedTriangleIndices(const std::vector<std::uint16_t>& triangles) const;
    std::vector<int> convexHullVertexIndices() const;
    static std::vector<int> deduplicatedRing(const std::vector<int>& idx);
    std::vector<std::uint16_t> triangulatePolygonIndices(const std::vector<int>& polygon) const;
    std::vector<int> cleanedPolygonIndices(const std::vector<int>& polygon) const;
    float polygonSignedArea(const std::vector<int>& idx) const;
    static bool pointInTriangleWithEpsilon(
        const Vec2& point, const Vec2& a, const Vec2& b, const Vec2& c, float epsilon);
    static float signedArea(const Vec2& a, const Vec2& b, const Vec2& c) {
        const Vec2 ab = b - a;
        const Vec2 ac = c - a;
        return ab.x * ac.y - ab.y * ac.x;
    }
};

} // namespace umeshcore
