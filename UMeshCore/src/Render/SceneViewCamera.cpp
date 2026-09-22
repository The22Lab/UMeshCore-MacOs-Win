#include "umeshcore/Render/SceneViewCamera.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {
constexpr float kPi = 3.14159265358979323846f;
}

Vec3 SceneViewCamera::eye() const {
    // `cameraBasis(pitch, yaw, 0).forward` is the same vector, by
    // construction -- one transcription of "forward", as the header says.
    const Vec3 forward = cameraBasis(pitch, yaw, 0.0f).forward;
    return pivot - forward * distance;
}

void SceneViewCamera::orbit(float deltaYaw, float deltaPitch) {
    yaw += deltaYaw;
    pitch = std::min(std::max(pitch + deltaPitch, -kPitchLimit), kPitchLimit);
}

void SceneViewCamera::dolly(float factor) {
    distance = std::min(std::max(distance * factor, kMinDistance), kMaxDistance);
}

void SceneViewCamera::pan(const Vec2& screenDelta, float viewHeight) {
    const float half = fieldOfView * kPi / 180.0f * 0.5f;
    const float worldPerPixel = (2.0f * distance * std::tan(half)) / std::max(viewHeight, 1.0f);
    const float cy = std::cos(yaw), sy = std::sin(yaw);
    const Vec3 right(cy, 0.0f, -sy);
    const Vec3 up(sy * std::sin(pitch), std::cos(pitch), cy * std::sin(pitch));
    pivot -= right * (screenDelta.x * worldPerPixel);
    pivot += up * (screenDelta.y * worldPerPixel);
}

SceneProjection SceneViewCamera::projection(const Vec2& viewSize) const {
    return SceneProjection(
        eye(), pitch, yaw, 0.0f, fieldOfView, kNearDistance, kFarDistance, viewSize);
}

std::vector<Vec3> shotFrame(
    const Vec3& shotEye, const Vec3& shotRotation3D, float shotFieldOfView, const Vec2& renderSize,
    float distance) {
    const CameraBasis basis =
        cameraBasis(shotRotation3D.x, shotRotation3D.y, shotRotation3D.z);
    // Unclamped, matching `SceneCamera.focalLength(viewHeight:)` -- see the
    // header for why this is not quietly made consistent with the fly
    // camera's clamped one.
    const float halfFov = shotFieldOfView * kPi / 180.0f * 0.5f;
    const float focal = (renderSize.y * 0.5f) / std::max(std::tan(halfFov), 0.000001f);
    // Height grows linearly with distance; width keeps the render aspect.
    const float halfH = renderSize.y * 0.5f * distance / std::max(focal, 0.000001f);
    const float halfW = halfH * renderSize.x / std::max(renderSize.y, 1.0f);
    const Vec3 centre = shotEye + basis.forward * distance;
    return {
        centre - basis.right * halfW + basis.up * halfH,
        centre + basis.right * halfW + basis.up * halfH,
        centre + basis.right * halfW - basis.up * halfH,
        centre - basis.right * halfW - basis.up * halfH,
    };
}

} // namespace umeshcore
