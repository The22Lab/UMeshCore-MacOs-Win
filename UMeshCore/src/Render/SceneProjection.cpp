#include "umeshcore/Render/SceneProjection.h"

#include <algorithm>
#include <cmath>

#include "umeshcore/Math/MatrixUtilities.h"

namespace umeshcore {

namespace {

Mat4 transposed(const Mat4& m) {
    return Mat4(
        Vec4(m.columns[0].x, m.columns[1].x, m.columns[2].x, m.columns[3].x),
        Vec4(m.columns[0].y, m.columns[1].y, m.columns[2].y, m.columns[3].y),
        Vec4(m.columns[0].z, m.columns[1].z, m.columns[2].z, m.columns[3].z),
        Vec4(m.columns[0].w, m.columns[1].w, m.columns[2].w, m.columns[3].w));
}

// The view matrix's rotation, transposed, takes camera space back to the
// world. Transposed rather than inverted because it IS a rotation, so the
// two are the same answer and only one of them can go wrong.
Vec3 cameraToWorldDirection(const Mat4& viewMatrix, const Vec3& inCamera) {
    // Rows of the view matrix's upper-left 3x3 are the basis vectors, so
    // multiplying by the transpose is a dot against each column.
    return Vec3(
        viewMatrix.columns[0].x * inCamera.x + viewMatrix.columns[0].y * inCamera.y +
            viewMatrix.columns[0].z * inCamera.z,
        viewMatrix.columns[1].x * inCamera.x + viewMatrix.columns[1].y * inCamera.y +
            viewMatrix.columns[1].z * inCamera.z,
        viewMatrix.columns[2].x * inCamera.x + viewMatrix.columns[2].y * inCamera.y +
            viewMatrix.columns[2].z * inCamera.z);
}

Mat4 perspective(float focalLength, float nearZ, float farZ, const Vec2& viewSize) {
    // `focalLength` is half the view height over tan(fov/2), so the
    // projection's f -- one over that tangent -- is twice it over the height.
    const float f = 2.0f * focalLength / std::max(viewSize.y, 0.000001f);
    const float aspect = viewSize.x / std::max(viewSize.y, 0.000001f);
    const float far = std::max(farZ, nearZ + 1.0f);
    // Column-major, and the camera looks along +Z -- so the row that writes
    // w reads z with a +1, not the -1 a right-handed look-down-minus-Z
    // convention would use.
    return Mat4(
        Vec4(f / aspect, 0, 0, 0), Vec4(0, f, 0, 0), Vec4(0, 0, far / (far - nearZ), 1),
        Vec4(0, 0, -far * nearZ / (far - nearZ), 0));
}

Vec4 toClip(const Mat4& projectionMatrix, const Mat4& viewMatrix, const Vec3& world) {
    return projectionMatrix * (viewMatrix * Vec4(world.x, world.y, world.z, 1.0f));
}

// `clip.z = far * (z - near) / (far - near)`: zero exactly on the near
// plane, positive in front of it.
float nearSide(const Vec4& clip) { return clip.z; }
// `clip.w - clip.z`: zero exactly on the far plane.
float farSide(const Vec4& clip) { return clip.w - clip.z; }

struct ClipVertex {
    Vec4 clip;
    Vec2 attribute;
};

// Sutherland-Hodgman against one clip-space half-space. `side` is >= 0
// inside. In CLIP space, before the divide -- see clipAndProject's comment.
template <typename SideFn>
std::vector<ClipVertex> clipBy(const std::vector<ClipVertex>& verts, SideFn side) {
    if (verts.size() < 2) return {};
    std::vector<ClipVertex> out;
    out.reserve(verts.size() + 2);
    for (std::size_t index = 0; index < verts.size(); ++index) {
        const ClipVertex& v0 = verts[index];
        const ClipVertex& v1 = verts[(index + 1) % verts.size()];
        const float d0 = side(v0.clip);
        const float d1 = side(v1.clip);
        const bool in0 = d0 >= 0.0f;
        const bool in1 = d1 >= 0.0f;
        if (in0) out.push_back(v0);
        if (in0 == in1) continue;
        const float denominator = d0 - d1;
        if (std::fabs(denominator) <= 1e-12f) continue;
        const float t = d0 / denominator;
        out.push_back(ClipVertex{v0.clip + (v1.clip - v0.clip) * t,
                                  v0.attribute + (v1.attribute - v0.attribute) * t});
    }
    return out;
}

Vec2 ndcToScreen(const Vec2& ndc, const Vec2& viewSize) {
    return Vec2(viewSize.x * 0.5f * (1.0f + ndc.x), viewSize.y * 0.5f * (1.0f - ndc.y));
}

Vec2 screenToNdc(const Vec2& screen, const Vec2& viewSize) {
    return Vec2(
        2.0f * screen.x / std::max(viewSize.x, 1.0f) - 1.0f,
        1.0f - 2.0f * screen.y / std::max(viewSize.y, 1.0f));
}

} // namespace

CameraBasis cameraBasis(float pitch, float yaw, float roll) {
    const float cp = std::cos(pitch);
    const float sp = std::sin(pitch);
    const float cy = std::cos(yaw);
    const float sy = std::sin(yaw);

    const Vec3 forward(sy * cp, -sp, cy * cp);
    Vec3 right(cy, 0.0f, -sy);
    Vec3 up = cross(forward, right);

    if (std::fabs(roll) > 0.000001f) {
        const float cr = std::cos(roll);
        const float sr = std::sin(roll);
        const Vec3 rolledRight = right * cr + up * sr;
        const Vec3 rolledUp = up * cr - right * sr;
        right = rolledRight;
        up = rolledUp;
    }
    return CameraBasis{right, up, forward};
}

SceneProjection::SceneProjection(
    const Vec3& eye_, float pitch, float yaw, float roll, float fieldOfView, float nearZ_, float farZ,
    const Vec2& viewSize_) {
    eye = eye_;
    viewSize = viewSize_;
    nearZ = nearZ_;

    const float clampedHalf = std::min(std::max(fieldOfView, 1.0f), 170.0f) * kPi / 180.0f * 0.5f;
    focalLength = (viewSize.y * 0.5f) / std::max(std::tan(clampedHalf), 0.000001f);

    // Yaw about world Y, then pitch, then roll about the view axis -- the
    // same order `cameraBasis` builds its vectors in, because the eye the
    // orbit computes has to be the eye this projects from.
    const Mat4 rotation =
        MatrixUtilities::rotationY(yaw) * MatrixUtilities::rotationX(pitch) * MatrixUtilities::rotationZ(roll);
    // A view matrix is the camera's transform INVERTED, and for a rotation
    // plus a translation the inverse is the transpose and the negated,
    // rotated offset -- exact, where a general inverse would not be.
    viewMatrix = transposed(rotation) * MatrixUtilities::translation(-eye);
    projectionMatrix = perspective(focalLength, nearZ, farZ, viewSize);
}

SceneProjection SceneProjection::fromFrame(
    const Vec3& eye, const CameraBasis& basis, float focalLength, float nearZ, float farZ, const Vec2& viewSize) {
    SceneProjection p;
    p.eye = eye;
    p.viewSize = viewSize;
    p.nearZ = nearZ;
    p.focalLength = focalLength;

    // A view matrix IS a basis in its rows and the negated, rotated eye in
    // its last column.
    const Vec3 t(-dot(basis.right, eye), -dot(basis.up, eye), -dot(basis.forward, eye));
    p.viewMatrix = Mat4(
        Vec4(basis.right.x, basis.up.x, basis.forward.x, 0), Vec4(basis.right.y, basis.up.y, basis.forward.y, 0),
        Vec4(basis.right.z, basis.up.z, basis.forward.z, 0), Vec4(t.x, t.y, t.z, 1));
    p.projectionMatrix = perspective(focalLength, nearZ, farZ, viewSize);
    return p;
}

std::optional<Vec2> SceneProjection::project(const Vec3& world) const {
    const Vec4 clip = toClip(projectionMatrix, viewMatrix, world);
    if (!(clip.w > nearZ)) return std::nullopt;
    return ndcToScreen(Vec2(clip.x / clip.w, clip.y / clip.w), viewSize);
}

float SceneProjection::depth(const Vec3& world) const {
    return (viewMatrix * Vec4(world.x, world.y, world.z, 1.0f)).z;
}

std::optional<float> SceneProjection::worldLengthForPixels(float pixels, float depth) const {
    if (!(depth > nearZ) || !(focalLength > 0.000001f)) return std::nullopt;
    return pixels * depth / focalLength;
}

std::vector<SceneProjection::ProjectedVertex> SceneProjection::clipAndProject(
    const std::vector<AttributedVertex>& polygon) const {
    if (polygon.size() < 2) return {};

    std::vector<ClipVertex> homogeneous;
    homogeneous.reserve(polygon.size());
    for (const AttributedVertex& vertex : polygon) {
        homogeneous.push_back(ClipVertex{toClip(projectionMatrix, viewMatrix, vertex.world), vertex.attribute});
    }

    // NEAR, then FAR. Two half-spaces, one clipper -- and the far one is
    // not decoration: without it the frustum's far plane discarded cards
    // this renderer would happily have drawn, because `farZ` went into the
    // projection matrix and then nothing ever read it back. A culler whose
    // planes the renderer does not honour is not a culler; it is a way to
    // lose objects.
    std::vector<ClipVertex> kept = clipBy(homogeneous, nearSide);
    if (!kept.empty()) kept = clipBy(kept, farSide);

    std::vector<ProjectedVertex> out;
    out.reserve(kept.size());
    for (const ClipVertex& entry : kept) {
        if (!(entry.clip.w > 0.0f) || !std::isfinite(entry.clip.w)) continue;
        const Vec2 ndc(entry.clip.x / entry.clip.w, entry.clip.y / entry.clip.w);
        if (!std::isfinite(ndc.x) || !std::isfinite(ndc.y)) continue;
        out.push_back(ProjectedVertex{ndcToScreen(ndc, viewSize), entry.attribute});
    }
    return out;
}

bool SceneProjection::isWhollyVisible(const std::vector<Vec3>& worlds) const {
    for (const Vec3& world : worlds) {
        const Vec4 clip = toClip(projectionMatrix, viewMatrix, world);
        if (!(nearSide(clip) >= 0.0f && farSide(clip) >= 0.0f)) return false;
    }
    return true;
}

std::optional<std::vector<Vec2>> SceneProjection::projectiveQuad(const std::vector<Vec3>& worlds) const {
    if (worlds.size() != 4) return std::nullopt;
    std::vector<Vec2> out;
    out.reserve(4);
    for (const Vec3& world : worlds) {
        const Vec4 clip = toClip(projectionMatrix, viewMatrix, world);
        // Note the ABSOLUTE value: a corner behind the eye has a negative
        // w and lands at the antipode, which is its correct projective
        // image, not an error to guard away.
        if (!(std::fabs(clip.w) > kWEpsilon)) return std::nullopt;
        const Vec2 ndc(clip.x / clip.w, clip.y / clip.w);
        if (!std::isfinite(ndc.x) || !std::isfinite(ndc.y)) return std::nullopt;
        out.push_back(ndcToScreen(ndc, viewSize));
    }
    return out;
}

SceneProjection::Ray SceneProjection::rayThrough(const Vec2& screen) const {
    const float f = projectionMatrix.columns[1].y;
    const float aspect = viewSize.x / std::max(viewSize.y, 0.000001f);
    const Vec2 ndc = screenToNdc(screen, viewSize);
    const Vec3 inCamera(
        ndc.x * aspect / std::max(std::fabs(f), 0.000001f), ndc.y / std::max(std::fabs(f), 0.000001f), 1.0f);

    const Vec3 direction = cameraToWorldDirection(viewMatrix, inCamera);
    const float len = length(direction);
    return Ray{eye, len > 0.000001f ? direction / len : Vec3(0, 0, 1)};
}

std::optional<Vec3> SceneProjection::hitPlane(const Vec2& screen, const Vec3& point, const Vec3& normal) const {
    const Ray r = rayThrough(screen);
    const float denominator = dot(r.direction, normal);
    if (!(std::fabs(denominator) > 0.000001f)) return std::nullopt;
    const float t = dot(point - r.origin, normal) / denominator;
    if (!(t > 0.0f) || !std::isfinite(t)) return std::nullopt;
    return r.origin + r.direction * t;
}

std::optional<float> SceneProjection::axisParameter(
    const Vec2& screen, const Vec3& point, const Vec3& direction) const {
    const Ray r = rayThrough(screen);
    const Vec3 w0 = point - r.origin;
    const float a = dot(direction, direction);
    const float b = dot(direction, r.direction);
    const float c = dot(r.direction, r.direction);
    const float d = dot(direction, w0);
    const float e = dot(r.direction, w0);
    const float denominator = a * c - b * b;
    if (!(std::fabs(denominator) > 0.000001f)) return std::nullopt;
    const float t = (b * e - c * d) / denominator;
    return std::isfinite(t) ? std::optional<float>(t) : std::nullopt;
}

std::optional<Vec2> SceneProjection::unprojectOntoPlaneZ(const Vec2& screen, float planeZ) const {
    const Vec2 ndc = screenToNdc(screen, viewSize);
    const float f = projectionMatrix.columns[1].y;
    if (!(std::fabs(f) > 0.000001f)) return std::nullopt;
    const float aspect = viewSize.x / std::max(viewSize.y, 0.000001f);

    const Vec3 inCamera(ndc.x * aspect / f, ndc.y / f, 1.0f);
    const Vec3 direction = cameraToWorldDirection(viewMatrix, inCamera);
    if (!(std::fabs(direction.z) > 0.000001f)) return std::nullopt;
    const float t = (planeZ - eye.z) / direction.z;
    if (!(t > 0.0f)) return std::nullopt;
    const Vec3 hit = eye + direction * t;
    return Vec2(hit.x, hit.y);
}

} // namespace umeshcore
